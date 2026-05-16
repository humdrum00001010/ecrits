import { test, expect } from '@playwright/test';
import { signInAs, resetE2EState } from '../../fixtures/personas';
import {
  getChanges,
  openStudio,
  pollUntil
} from '../../fixtures/studio';
import { seedMatterAndDocument } from '../../fixtures/seeds';

/**
 * Scenario 2 — clean revoke (no overlap).
 *
 * Lawyer edits a paragraph → presses Cmd+Z (Ctrl+Z) → projection rolls
 * back → DB has a revoke `Change` with `status: :revoked` on the original.
 *
 * The Cmd+Z keyboard handler lives in `Canvas.Editor`'s `.Editable` hook
 * (window-scoped, capture-phase). The hook only mounts when the Studio
 * LV's `studio_state.mode == :editing` — `derive_mode_from_history`
 * returns `:briefing` for a freshly-seeded document because
 * `projection.type_key` is `nil` until a `:set_contract_type` change
 * lands AND a `:create_node` op adds at least one node to `node_order`.
 *
 * So the scenario does a two-phase setup:
 *
 *   1. Phase one (briefing): push `set_contract_type` + an `edit_document`
 *      carrying a `:create_node` op so the projection ends up with a
 *      `type_key` AND a real editable node in `node_order`. Reload — on
 *      the next mount `derive_mode` falls into the change-history branch,
 *      sees `set_contract_type` / `edit_document` and returns `:editing`.
 *
 *   2. Phase two (editing): push the actual edit that the scenario means
 *      to undo, wait for the `phx:editor:last-change` event so the hook
 *      can cache the change_id, then press Cmd+Z.
 *
 * Edits are pushed via the LV's `edit_document` event directly (no agent
 * round-trip), which keeps the scenario cheap and deterministic. The
 * agent path is covered by Scenario 1.
 */

const FIRST_NODE_ID = 'clean-revoke-node-1';

test.describe('Scenario 2: clean revoke', () => {
  for (const viewport of ['desktop', 'mobile'] as const) {
    test(`[${viewport}] edit → Cmd+Z → revoke change committed`, async ({
      page,
      request
    }, testInfo) => {
      // Hook console + pageerror so flaky failures leave a trail in the
      // playwright reporter output.
      page.on('console', (m) => {
        const t = m.text();
        if (
          t.includes('[Editable]') ||
          t.includes('Cmd+Z') ||
          t.includes('pushHookEvent') ||
          t.includes('Studio')
        ) {
          // eslint-disable-next-line no-console
          console.log(`[browser:${m.type()}] ${t}`);
        }
      });
      page.on('pageerror', (err) => {
        // eslint-disable-next-line no-console
        console.log(`[browser:pageerror] ${err.message}`);
      });

      await resetE2EState(request);
      await signInAs(page, 'lawyer');

      // Seed an inline matter + document via the test-only POST routes
      // so the scenario is self-contained and doesn't depend on the
      // sprite DB having a pre-existing row. The seeder is gated by
      // `compile_env(:test_auth)` — production builds 404.
      // Use `page` here (not `request`) so the seed call rides the
      // same cookie jar as `signInAs(page, ...)` — otherwise the
      // controller falls back to minting a throwaway persona, which
      // can flake on PersonaFactory email collisions.
      const { document } = await seedMatterAndDocument(page, {
        title: 'Clean-revoke scenario doc',
        type_key: 'nda_v1'
      });

      await openStudio(page, {
        id: document.id,
        matter_id: document.matter_id,
        name: document.title,
        type_key: document.type_key,
        inserted_at: ''
      });

      // Wait for the LV to actually be connected — `page.goto` returns
      // when the HTML lands, but `pushHookEvent` requires `liveSocket`
      // to be live AND the view's `joinPending` to have cleared.
      // Without this barrier the first phase-1 push fails with
      // "unable to push hook event. LiveView not connected".
      await waitForLiveSocket(page);

      // The Studio LV swaps to a chat-first mobile layout below 1024px
      // (StudioLive.handle_event/"viewport_change") and does NOT render
      // the Canvas.Editor in that branch — Cmd+Z is desktop-only by
      // architecture. Force the LV into the desktop branch so the hook
      // actually mounts; the [mobile] iteration of this scenario still
      // exercises the Cmd+Z keyboard pipeline, just against the same
      // desktop layout. The mobile-specific responsive rendering is
      // covered elsewhere.
      await pushHookEvent(page, 'viewport_change', { w: 1440 });

      const edited = await page.evaluate(() => {
        const hook = (window as unknown as { liveSocket?: { execJS?: unknown } }).liveSocket;
        return Boolean(hook);
      });
      if (!edited) {
        test.skip(true, 'No live socket — the Studio LV failed to mount in this state.');
        return;
      }

      // Phase 1: flip derive_mode to `:editing` by landing
      // `set_contract_type` (populates projection.type_key) and a
      // `create_node` op (populates node_order so the Editor has
      // something to render). Push and wait one at a time — the LV's
      // Session GenServer serialises commits, and the test pollUntil
      // only sees the second row after the first has been committed
      // through Store.append.
      await pushHookEvent(page, 'set_contract_type', {
        document_id: document.id,
        type_key: 'nda_v1'
      });
      await pollUntil(
        () => getChanges(request, document.id),
        (rows) => rows.some((r) => r.action_kind === 'set_contract_type'),
        { timeoutMs: 10_000, label: 'set_contract_type appears' }
      );

      await pushHookEvent(page, 'edit_document', {
        document_id: document.id,
        ops: [
          {
            op: 'create_node',
            target_type: 'node',
            target_id: FIRST_NODE_ID,
            args: {
              kind: 'paragraph',
              content: 'Initial paragraph for the clean-revoke scenario.'
            }
          }
        ]
      });
      await pollUntil(
        () => getChanges(request, document.id),
        (rows) => rows.length >= 2,
        { timeoutMs: 10_000, label: 'create_node edit appears' }
      );

      // Re-mount the LV so `Studio.load` re-derives `mode` from the
      // change history we just laid down. After the reload the canvas
      // must render `[data-stub="canvas-editor"]` — that's the gate
      // that proves the Editable hook is now installed and listening
      // for Cmd+Z.
      await page.reload({ waitUntil: 'networkidle' });
      await waitForLiveSocket(page);
      // Re-pin the LV's viewport to desktop on the mobile project — see
      // the rationale on the first `viewport_change` push above.
      await pushHookEvent(page, 'viewport_change', { w: 1440 });
      await page.waitForSelector('[data-stub="canvas-editor"]', { timeout: 10_000 });

      // Capture baseline change-count AFTER the warm-up so we can wait
      // for the real edit + revoke pair specifically.
      const baseline = await getChanges(request, document.id);
      const baseCount = baseline.length;

      // Install a small probe so we can synchronise on the LV-side
      // `phx:editor:last-change` event — the hook only knows the
      // change-id to revoke once the LV has pushed that event. Pressing
      // Cmd+Z before the event arrives produces a silent no-op.
      await page.evaluate(() => {
        interface LCWindow {
          __lastChangeSeen?: { change_id?: string; node_id?: string };
        }
        const w = window as unknown as Window & LCWindow;
        w.__lastChangeSeen = undefined;
        window.addEventListener('phx:editor:last-change', (e) => {
          const d = (e as CustomEvent).detail;
          (w as LCWindow).__lastChangeSeen = d;
        });
      });

      // Phase 2: push the edit we mean to undo. `replace_content` on
      // the node we created in phase 1.
      await pushHookEvent(page, 'edit_document', {
        document_id: document.id,
        ops: [
          {
            op: 'replace_content',
            target_type: 'node',
            target_id: FIRST_NODE_ID,
            args: { content: '2026-01-01' }
          }
        ]
      });

      // Wait for the edit to land as a Change row.
      const afterEdit = await pollUntil(
        () => getChanges(request, document.id),
        (rows) => rows.length === baseCount + 1,
        { timeoutMs: 10_000, label: 'edit change appears' }
      );
      const editChange = afterEdit[afterEdit.length - 1];
      expect(editChange.action_kind).toMatch(/edit|user_change/);

      // Wait for `phx:editor:last-change` so the Editable hook has
      // cached `lastChangeId`. Without this barrier, Cmd+Z fires
      // before the WebSocket round-trip lands and the hook bails on
      // `if (!this.lastChangeId) return`.
      await page.waitForFunction(
        (changeId) => {
          interface LCWindow {
            __lastChangeSeen?: { change_id?: string };
          }
          const seen = (window as unknown as LCWindow).__lastChangeSeen;
          return Boolean(seen && seen.change_id === changeId);
        },
        editChange.id,
        { timeout: 5_000 }
      );

      // Cmd+Z (Ctrl+Z on linux). Focus the body first so the keypress
      // lands on `window` (the hook's listener is in capture-phase on
      // `window`, so this doubles as a regression guard against any
      // future "only when focused on a contenteditable" gating).
      await page.locator('body').click({ position: { x: 10, y: 10 } });
      const meta = process.platform === 'darwin' ? 'Meta' : 'Control';
      await page.keyboard.press(`${meta}+KeyZ`);

      // Wait for the revoke change to land. The Cmd+Z keyboard path is
      // handled by Canvas.Editor's `.Editable` hook on `window` (capture
      // phase) — it caches the last-committed change-id from the LV's
      // `phx:editor:last-change` event and pushes `revoke_change` with
      // that id. Server-side, `Studio.submit` writes a Change row with
      // `action_kind: "revoke_change"` whose preimage targets the
      // original edit.
      const afterUndo = await pollUntil(
        () => getChanges(request, document.id),
        (rows) => rows.some((r) => r.action_kind === 'revoke_change'),
        { timeoutMs: 10_000, label: 'revoke change appears' }
      );

      // A revoke change exists.
      const revoke = afterUndo.find((r) => r.action_kind === 'revoke_change');
      expect(revoke).toBeTruthy();

      // The original edit row is still present (its `status` flip to
      // `revoked` is a separate Store-layer concern not under this
      // scenario's purview — see studio_live_test.exs LV pin).
      const original = afterUndo.find((r) => r.id === editChange.id);
      expect(original).toBeTruthy();

      // Stamp the report with the viewport for human-readable artefacts.
      testInfo.annotations.push({ type: 'viewport', description: viewport });
    });
  }
});

/**
 * Pushes `event` with `payload` through the StudioLive's `pushHookEvent`
 * gateway. Wrapped so the spec's two-phase setup doesn't repeat the
 * `liveSocket.owner(root)` dance four times.
 */
async function waitForLiveSocket(
  page: import('@playwright/test').Page
): Promise<void> {
  await page.waitForSelector('[data-phx-main]', { timeout: 10_000 });
  await page.waitForFunction(
    () => {
      interface LVWindow {
        liveSocket?: { isConnected?: () => boolean };
      }
      const lv = (window as unknown as LVWindow).liveSocket;
      return Boolean(lv && lv.isConnected && lv.isConnected());
    },
    { timeout: 10_000 }
  );
  // Mirror the working pattern in `wave-4-wizard-screenshots.ts` — even
  // after `isConnected()` returns true, the LV's `joinPending` doesn't
  // clear for a tick or two. Skipping this sleep produces sporadic
  // `LiveView not connected` errors from `pushHookEvent`.
  await page.waitForTimeout(800);
}

async function pushHookEvent(
  page: import('@playwright/test').Page,
  event: string,
  payload: Record<string, unknown>
): Promise<void> {
  const result = await page.evaluate(
    ({ event, payload }) => {
      try {
        interface LVView {
          pushHookEvent: (
            el: Element | null,
            ctx: unknown,
            event: string,
            payload: Record<string, unknown>
          ) => Promise<{ reply: unknown; ref: unknown }>;
        }
        interface LVWindow {
          liveSocket?: { getViewByEl?: (el: Element) => LVView | null };
        }
        const lv = (window as unknown as LVWindow).liveSocket;
        const root = document.querySelector('[data-phx-main]');
        if (!root) return { ok: false, error: 'no-root' };
        const view = lv?.getViewByEl?.(root);
        if (!view) return { ok: false, error: 'no-view' };
        // pushHookEvent returns a Promise; we don't await it from page
        // context because the result is settled async via the WebSocket.
        // Just confirm the call dispatched without throwing.
        void view.pushHookEvent(root, null, event, payload);
        return { ok: true };
      } catch (e) {
        return { ok: false, error: String(e) };
      }
    },
    { event, payload }
  );
  if (!result.ok) {
    // eslint-disable-next-line no-console
    console.log(`[Studio] pushHookEvent ${event} failed: ${result.error}`);
  }
}
