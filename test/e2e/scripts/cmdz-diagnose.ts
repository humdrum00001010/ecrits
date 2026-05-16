/**
 * Cmd+Z diagnostic — Why does the Playwright clean-revoke scenario fail
 * to produce a `revoke_change` row even though the JS hook was patched?
 *
 * The scenario is exercised end-to-end against the deployed sprite:
 *
 *   1. Sign in as `lawyer` (test-only persona endpoint).
 *   2. Seed an inline matter + document.
 *   3. Navigate to the Studio LV.
 *   4. Hook console + pageerror + request listeners to capture every
 *      event the page emits — we want to see the hook's own console
 *      breadcrumbs, any JS errors, and every Phoenix push.
 *   5. Push `edit_document` via `pushHookEvent` (same as the spec).
 *   6. Wait for the edit change to land in `/test/db/changes/:id`.
 *   7. Press the OS-appropriate undo combo and (separately) the
 *      Mac-style `Meta+z` to rule out keymap mismatches. Also pull a
 *      fallback `keydown` dispatch on `window` so we can compare paths.
 *   8. Poll `/test/db/changes/:id` for a `revoke_change` row.
 *   9. Dump the hook's introspected state (last cached change id,
 *      whether `data-can-revoke` is set, listener counts) and the
 *      console/network transcript.
 *
 *   sprite x -s contract-studio -- bash -lc 'cd ~/work/contract/test/e2e && pnpm tsx scripts/cmdz-diagnose.ts'
 *
 * The script is intentionally chatty — every console.log is a clue.
 */
import { chromium, type Browser, type ConsoleMessage } from '@playwright/test';

const BASE_URL =
  process.env.E2E_BASE_URL ?? 'https://contract-studio-v7zk.sprites.app';

interface SignInResp {
  ok: boolean;
  persona: string;
  user_id: string;
  email: string;
}

interface SeedDocResp {
  ok: boolean;
  id: string;
  matter_id: string;
  type_key: string;
  title: string;
}

interface SeedMatterResp {
  ok: boolean;
  id: string;
  name: string;
}

interface ChangeRow {
  id: string;
  action_kind: string;
  status: string;
  applied_revision: number;
}

interface ChangesResp {
  ok: boolean;
  changes: ChangeRow[];
}

async function run(): Promise<void> {
  const browser: Browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    baseURL: BASE_URL,
    viewport: { width: 1280, height: 800 }
  });
  const page = await context.newPage();

  const consoleLog: { type: string; text: string }[] = [];
  const errors: string[] = [];
  const pushedEvents: string[] = [];

  page.on('console', (m: ConsoleMessage) => {
    const txt = m.text();
    consoleLog.push({ type: m.type(), text: txt });
    if (
      txt.includes('cmdz-diag') ||
      txt.includes('Editable') ||
      txt.includes('revoke')
    ) {
      console.log(`[console:${m.type()}] ${txt}`);
    }
  });
  page.on('pageerror', (err) => {
    errors.push(err.message);
    console.log(`[pageerror] ${err.message}`);
  });
  page.on('request', (req) => {
    const url = req.url();
    if (url.includes('/live/longpoll') || url.includes('/live/websocket')) {
      const body = req.postData() || '';
      if (
        body.includes('revoke_change') ||
        body.includes('edit_document') ||
        body.includes('editor:')
      ) {
        pushedEvents.push(`${req.method()} ${url} :: ${body.slice(0, 200)}`);
        console.log(`[req] ${req.method()} (${body.length}B) ${body.slice(0, 200)}`);
      }
    }
  });

  // 1. Sign in as lawyer.
  const signResp = await page.request.post(`${BASE_URL}/test/personas/lawyer/sign_in`);
  if (signResp.status() !== 200) {
    console.log(`[FATAL] signIn status=${signResp.status()} body=${await signResp.text()}`);
    await browser.close();
    process.exit(1);
  }
  const sign = (await signResp.json()) as SignInResp;
  console.log(`[1] signed in as ${sign.persona} email=${sign.email}`);

  // 2. Seed matter + doc.
  const matterResp = await page.request.post(`${BASE_URL}/test/db/matters`, {
    data: { name: 'cmdz-diag matter' }
  });
  const matter = (await matterResp.json()) as SeedMatterResp;
  console.log(`[2a] seeded matter id=${matter.id}`);

  const docResp = await page.request.post(`${BASE_URL}/test/db/documents`, {
    data: {
      matter_id: matter.id,
      type_key: 'nda_v1',
      title: 'cmdz-diag doc'
    }
  });
  const doc = (await docResp.json()) as SeedDocResp;
  console.log(`[2b] seeded document id=${doc.id} matter_id=${doc.matter_id}`);

  // 3. Navigate to Studio.
  await page.goto(`${BASE_URL}/matters/${doc.matter_id}/documents/${doc.id}`, {
    waitUntil: 'networkidle',
    timeout: 30_000
  });

  // Confirm LV mounted.
  const hasMain = await page.locator('[data-phx-main]').count();
  console.log(`[3] data-phx-main count=${hasMain}`);

  // Pre-edit: snapshot DOM state of the hook root + which canvas
  // component the LV chose. This is the key diagnostic — `derive_mode`
  // returns `:briefing` for a doc with no changes, so the Editor never
  // mounts and the Cmd+Z hook is never installed. Knowing the mode up
  // front tells us whether the failure is a JS bug (hook present, Cmd+Z
  // bails) or a mounting bug (hook never installed).
  const canvasMeta = await page.evaluate(() => {
    const editor = document.querySelector('[data-stub="canvas-editor"]') as HTMLElement | null;
    const briefing = document.querySelector('[data-component="canvas-briefing"]') as HTMLElement | null;
    const empty = document.querySelector('[data-stub="canvas-empty"]') as HTMLElement | null;
    return {
      editorPresent: !!editor,
      editorMode: editor?.dataset.mode,
      briefingPresent: !!briefing,
      briefingMode: briefing?.dataset.mode,
      emptyPresent: !!empty
    };
  });
  console.log(`[3b] canvas meta = ${JSON.stringify(canvasMeta)}`);

  const hookRoot = await page.evaluate(() => {
    const el = document.querySelector('.contract-body') as HTMLElement | null;
    if (!el) return null;
    return {
      id: el.id,
      hasHook: el.getAttribute('phx-hook'),
      canWrite: el.dataset.canWrite,
      canRevoke: el.dataset.canRevoke,
      nodeCount: el.querySelectorAll('[data-node-id]').length
    };
  });
  console.log(`[4] hookRoot=${JSON.stringify(hookRoot)}`);

  // If the editor isn't mounted (briefing/empty mode), warm-edit the
  // doc to land changes that flip derive_mode to `:editing`, then
  // reload so the LV re-mounts with the new mode. `derive_mode`
  // gates first on `projection.type_key` (nil → briefing regardless of
  // history), so we MUST push `set_contract_type` here — a plain
  // `edit_document` alone leaves type_key nil and mode stays briefing.
  // Then we also push a `:create_node` op so the projection's
  // `node_order` ends up non-empty.
  const FIRST_NODE_ID = 'cmdz-diag-node-1';
  if (!canvasMeta.editorPresent) {
    console.log('[3c] editor NOT mounted — running warm-edit + reload sequence');
    await pushHookEvent(page, 'set_contract_type', {
      document_id: doc.id,
      type_key: 'nda_v1'
    });
    await pushHookEvent(page, 'edit_document', {
      document_id: doc.id,
      ops: [
        {
          op: 'create_node',
          target_type: 'node',
          target_id: FIRST_NODE_ID,
          args: { kind: 'paragraph', content: 'warm-up paragraph' }
        }
      ]
    });

    const warm = await pollChanges(
      page,
      doc.id,
      (rows) => rows.length >= 2,
      { timeoutMs: 8_000 }
    );
    console.log(`[3d] warm changes landed: ${warm.found}, rows=${warm.rows.length}`);
    console.log(
      `[3d-rows] ${JSON.stringify(warm.rows.map((r) => ({ kind: r.action_kind })))}`
    );

    await page.reload({ waitUntil: 'networkidle' });
    const remountedMeta = await page.evaluate(() => {
      const editor = document.querySelector('[data-stub="canvas-editor"]') as HTMLElement | null;
      const briefing = document.querySelector('[data-component="canvas-briefing"]') as HTMLElement | null;
      return {
        editorPresent: !!editor,
        editorMode: editor?.dataset.mode,
        briefingPresent: !!briefing,
        briefingMode: briefing?.dataset.mode
      };
    });
    console.log(`[3e] post-reload canvas meta = ${JSON.stringify(remountedMeta)}`);

    // Re-install probes after the reload (the previous window listeners
    // belonged to the unloaded page).
    await page.evaluate(() => {
      interface DiagWindow {
        __cmdzDiag: {
          keys: { key: string; meta: boolean; ctrl: boolean; shift: boolean; target: string }[];
          windowEvents: string[];
        };
      }
      const w = window as unknown as Window & DiagWindow;
      w.__cmdzDiag = { keys: [], windowEvents: [] };
      window.addEventListener(
        'keydown',
        (e) => {
          w.__cmdzDiag.keys.push({
            key: e.key,
            meta: e.metaKey,
            ctrl: e.ctrlKey,
            shift: e.shiftKey,
            target: (e.target as Element)?.tagName ?? 'unknown'
          });
          // eslint-disable-next-line no-console
          console.log(
            `[cmdz-diag] keydown key=${e.key} meta=${e.metaKey} ctrl=${e.ctrlKey} shift=${e.shiftKey} target=${(e.target as Element)?.tagName}`
          );
        },
        true
      );
      ['phx:editor:last-change', 'phx:editor:change-revoked', 'phx:editor-revert'].forEach(
        (name) => {
          window.addEventListener(name, (e) => {
            const detail = (e as CustomEvent).detail;
            w.__cmdzDiag.windowEvents.push(`${name}::${JSON.stringify(detail)}`);
            // eslint-disable-next-line no-console
            console.log(
              `[cmdz-diag] window-event ${name} detail=${JSON.stringify(detail)}`
            );
          });
        }
      );
    });
  }

  // Install an instrumented capture-phase keydown probe BEFORE
  // exercising Cmd+Z so we can observe whether the event actually
  // reaches `window` at all. This is a passive probe — it never calls
  // preventDefault.
  await page.evaluate(() => {
    interface DiagWindow {
      __cmdzDiag: {
        keys: { key: string; meta: boolean; ctrl: boolean; shift: boolean; target: string }[];
        windowEvents: string[];
        lvOwner?: unknown;
      };
    }
    const w = window as unknown as Window & DiagWindow;
    w.__cmdzDiag = { keys: [], windowEvents: [] };
    window.addEventListener(
      'keydown',
      (e) => {
        w.__cmdzDiag.keys.push({
          key: e.key,
          meta: e.metaKey,
          ctrl: e.ctrlKey,
          shift: e.shiftKey,
          target: (e.target as Element)?.tagName ?? 'unknown'
        });
        // eslint-disable-next-line no-console
        console.log(
          `[cmdz-diag] keydown key=${e.key} meta=${e.metaKey} ctrl=${e.ctrlKey} shift=${e.shiftKey} target=${(e.target as Element)?.tagName}`
        );
      },
      true
    );
    [
      'phx:editor:last-change',
      'phx:editor:change-revoked',
      'phx:editor-revert'
    ].forEach((name) => {
      window.addEventListener(name, (e) => {
        const detail = (e as CustomEvent).detail;
        w.__cmdzDiag.windowEvents.push(`${name}::${JSON.stringify(detail)}`);
        // eslint-disable-next-line no-console
        console.log(`[cmdz-diag] window-event ${name} detail=${JSON.stringify(detail)}`);
      });
    });
  });

  // 5. Push edit_document via pushHookEvent — same as the failing spec.
  const firstNodeId = await page.evaluate(() => {
    const el = document.querySelector('[data-node-id]') as HTMLElement | null;
    return el?.dataset.nodeId ?? null;
  });
  console.log(`[5a] firstNodeId(DOM)=${firstNodeId}`);

  // Use the warm-up node id (we know it exists in the projection after
  // phase 1). Fall back to the DOM-discovered id if for any reason the
  // warm-up didn't run.
  const editTargetId = firstNodeId ?? FIRST_NODE_ID;
  console.log(`[5b] editTargetId=${editTargetId}`);

  await pushHookEvent(page, 'edit_document', {
    document_id: doc.id,
    ops: [
      {
        op: 'replace_content',
        target_type: 'node',
        target_id: editTargetId,
        args: { content: 'diagnostic edit ' + Date.now() }
      }
    ]
  });
  await page.evaluate(() => {
    // eslint-disable-next-line no-console
    console.log('[cmdz-diag] pushed edit_document via pushHookEvent');
  });

  // 6. Wait for the edit change to land.
  const editLanded = await pollChanges(page, doc.id, (rows) =>
    rows.some((r) => r.action_kind === 'edit_document' || r.action_kind === 'user_change')
  );
  console.log(`[6] edit-landed = ${editLanded.found}, total changes=${editLanded.rows.length}`);
  if (editLanded.found) {
    const edits = editLanded.rows.filter(
      (r) => r.action_kind === 'edit_document' || r.action_kind === 'user_change'
    );
    console.log(`[6b] edit row: ${JSON.stringify(edits[edits.length - 1])}`);
  }

  // 7. Snapshot the hook's cached lastChangeId BEFORE pressing Cmd+Z.
  const hookStateBefore = await page.evaluate(() => {
    interface LVOwner {
      hookView?: unknown;
      el?: HTMLElement;
    }
    interface LVWindow {
      liveSocket?: {
        owner?: (el: Element) => LVOwner;
        getHookCallbacks?: (name: string) => unknown;
      };
    }
    const root = document.querySelector('[data-phx-main]') as HTMLElement | null;
    if (!root) return null;
    // The hook instance for a colocated hook is stored on the element
    // under a __view-prefixed key. We don't try to grab it here (LV
    // private API); instead, we inspect a hook-side breadcrumb that
    // the patched editor.ex SHOULD populate. The next iteration of the
    // hook will be modified to write `this.el.dataset.__lastChangeId`
    // so we can probe from the outside. For now we just check the DOM.
    const body = document.querySelector('.contract-body') as HTMLElement | null;
    return {
      canWrite: body?.dataset.canWrite,
      canRevoke: body?.dataset.canRevoke,
      datasetKeys: body ? Object.keys(body.dataset) : []
    };
  });
  console.log(`[7] hookState (before Cmd+Z) = ${JSON.stringify(hookStateBefore)}`);

  // Take a screenshot for visual confirmation that the LV is alive.
  await page
    .screenshot({ path: '/tmp/cmdz-diagnose-pre.png', fullPage: false })
    .catch(() => undefined);

  // 8a. Click on the body away from any contenteditable so the focus
  // mimics the failing spec.
  await page.locator('body').click({ position: { x: 5, y: 5 } });

  // 8b. Try Control+z (Linux/sprite path).
  console.log('[8] sending Control+KeyZ');
  await page.keyboard.press('Control+KeyZ');
  await page.waitForTimeout(800);

  // 8c. Try Meta+z (Mac path) as a fallback.
  console.log('[8] sending Meta+KeyZ');
  await page.keyboard.press('Meta+KeyZ');
  await page.waitForTimeout(800);

  // 8d. Lower-level: dispatch a synthetic keydown so we can confirm whether
  // the issue is keymap (Playwright presses correctly land in DOM, but the
  // hook never sees them) vs. handler logic (event lands, handler bails).
  await page.evaluate(() => {
    const ev = new KeyboardEvent('keydown', {
      key: 'z',
      code: 'KeyZ',
      ctrlKey: true,
      bubbles: true,
      cancelable: true
    });
    window.dispatchEvent(ev);
    // eslint-disable-next-line no-console
    console.log('[cmdz-diag] dispatched synthetic Ctrl+z window keydown');
  });
  await page.waitForTimeout(800);

  // 9. Poll for revoke change.
  const revokeLanded = await pollChanges(
    page,
    doc.id,
    (rows) => rows.some((r) => r.action_kind === 'revoke_change'),
    { timeoutMs: 4_000 }
  );
  console.log(`[9] revoke-landed = ${revokeLanded.found}`);
  console.log(
    `[9b] all changes after undo attempts: ${JSON.stringify(
      revokeLanded.rows.map((r) => ({ id: r.id, kind: r.action_kind, status: r.status }))
    )}`
  );

  // 10. Replay the captured key + window-event log.
  const diag = await page.evaluate(() => {
    interface DiagWindow {
      __cmdzDiag?: {
        keys: { key: string; meta: boolean; ctrl: boolean; shift: boolean; target: string }[];
        windowEvents: string[];
      };
    }
    return (window as unknown as DiagWindow).__cmdzDiag ?? null;
  });
  console.log(`[10] captured keys (${diag?.keys.length ?? 0}):`);
  diag?.keys.forEach((k, i) => {
    console.log(`     #${i}: ${JSON.stringify(k)}`);
  });
  console.log(`[10b] captured window events (${diag?.windowEvents.length ?? 0}):`);
  diag?.windowEvents.forEach((e, i) => {
    console.log(`     #${i}: ${e}`);
  });

  // 11. Replay every captured push to the server.
  console.log(`[11] phx pushes containing revoke/edit/editor: ${pushedEvents.length}`);
  pushedEvents.forEach((e, i) => {
    console.log(`     #${i}: ${e}`);
  });

  console.log(`[12] console messages total: ${consoleLog.length}`);
  console.log(`[12b] page errors: ${errors.length}`);
  errors.forEach((e, i) => console.log(`     err#${i}: ${e}`));

  await browser.close();

  // Exit non-zero if revoke didn't land — the script is also CI-usable.
  if (!revokeLanded.found) {
    console.log('[RESULT] FAIL — revoke_change did not appear');
    process.exit(2);
  }
  console.log('[RESULT] PASS — revoke_change landed');
}

async function pushHookEvent(
  page: import('@playwright/test').Page,
  event: string,
  payload: Record<string, unknown>
): Promise<void> {
  await page.evaluate(
    ({ event, payload }) => {
      interface LVOwner {
        pushHookEvent: (
          el: Element,
          ctx: unknown,
          event: string,
          payload: Record<string, unknown>
        ) => unknown;
      }
      interface LVWindow {
        liveSocket?: { owner?: (el: Element) => LVOwner };
      }
      const lv = (window as unknown as LVWindow).liveSocket;
      const root = document.querySelector('[data-phx-main]');
      if (!root) throw new Error('no LV root');
      const view = lv?.owner?.(root);
      if (!view) throw new Error('no LV owner');
      view.pushHookEvent(root, null, event, payload);
    },
    { event, payload }
  );
}

async function pollChanges(
  page: import('@playwright/test').Page,
  documentId: string,
  predicate: (rows: ChangeRow[]) => boolean,
  opts: { timeoutMs?: number; intervalMs?: number } = {}
): Promise<{ found: boolean; rows: ChangeRow[] }> {
  const timeoutMs = opts.timeoutMs ?? 8_000;
  const intervalMs = opts.intervalMs ?? 250;
  const start = Date.now();
  let last: ChangeRow[] = [];

  while (Date.now() - start < timeoutMs) {
    const resp = await page.request.get(`/test/db/changes/${documentId}`);
    if (resp.status() === 200) {
      const body = (await resp.json()) as ChangesResp;
      last = body.changes;
      if (predicate(last)) return { found: true, rows: last };
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return { found: false, rows: last };
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
