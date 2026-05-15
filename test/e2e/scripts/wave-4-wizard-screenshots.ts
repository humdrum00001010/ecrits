/**
 * Wave-4 migration-wizard screenshot harness.
 *
 * One-off script: signs in via the :lawyer persona route (which seeds
 * `:type_change` perm into the session), opens the seeded NDA document
 * in Studio, drives the 3-step type-conversion wizard (Plan →
 * FieldStrategies → Confirm), and captures one PNG per step at
 * 1440x900 (desktop only).
 *
 * Why persona signin instead of password form: the password form goes
 * through `UserSessionController.create/2`, which does not seed
 * `:user_perms` into the session. `Conversion.plan/4` requires
 * `:type_change` in `scope.perms`, which is only set by `MatterScope`
 * when the session has a `:user_perms` key — and that key is only put
 * by `TestAuthController.sign_in/2`. So the persona route is the only
 * way to get a properly-permed scope through the LV today.
 *
 * The matter + document are seeded against a separate user with
 * tenant_id: nil; `Matters.authorize_read/2` is permissive for null
 * tenants, so the persona user can read and convert them just fine.
 *
 * Required env (no fallbacks):
 *   E2E_BASE_URL   — sprite URL
 *   MATTER_ID      — seeded matter
 *   DOCUMENT_ID    — seeded NDA document
 */
import {
  chromium,
  type Browser,
  type BrowserContext,
  type Page
} from '@playwright/test';
import * as path from 'node:path';
import * as fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const BASE_URL =
  process.env.E2E_BASE_URL ?? 'https://contract-studio-v7zk.sprites.app';

const MATTER_ID = process.env.MATTER_ID ?? '';
const DOCUMENT_ID = process.env.DOCUMENT_ID ?? '';

if (!MATTER_ID || !DOCUMENT_ID) {
  throw new Error('Required env: MATTER_ID, DOCUMENT_ID');
}

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const OUT_DIR = path.resolve(
  __dirname,
  '..',
  '..',
  '..',
  'docs',
  'wave-4',
  '2026-05-15'
);
fs.mkdirSync(OUT_DIR, { recursive: true });

async function signInAsLawyer(context: BrowserContext): Promise<void> {
  const resp = await context.request.post(
    `${BASE_URL}/test/personas/lawyer/sign_in`,
    { failOnStatusCode: true }
  );
  if (resp.status() !== 200) {
    throw new Error(`Persona sign-in failed: ${resp.status()}`);
  }
}

async function openDocument(page: Page): Promise<void> {
  await page.goto(`${BASE_URL}/matters/${MATTER_ID}/documents/${DOCUMENT_ID}`, {
    waitUntil: 'domcontentloaded',
    timeout: 30_000
  });
  await page.waitForSelector('[data-phx-main]', { timeout: 15_000 });
  // LV connect: wait for window.liveSocket to exist and be connected.
  await page.waitForFunction(
    () => {
      const w = window as unknown as {
        liveSocket?: { isConnected?: () => boolean };
      };
      return !!w.liveSocket && w.liveSocket.isConnected?.() === true;
    },
    { timeout: 15_000 }
  );
  await page.waitForTimeout(800);
}

async function dispatchStartTypeConversion(
  page: Page,
  targetTypeKey: string
): Promise<void> {
  // Use pushHookEvent — the only public-ish entrypoint that doesn't
  // require a DOM element to harvest phx-value-* attributes from. We pass
  // the [data-phx-main] element as `el` and `null` as targetCtx so the
  // event hits the root LiveView (not a LiveComponent).
  const result = await page.evaluate(
    ({ targetTypeKey }) => {
      const w = window as unknown as {
        liveSocket?: {
          getViewByEl: (el: Element) => {
            pushHookEvent: (
              el: Element | null,
              targetCtx: unknown,
              event: string,
              payload: Record<string, unknown>
            ) => Promise<{ reply: unknown; ref: unknown }>;
          } | null;
        };
      };
      const main = document.querySelector('[data-phx-main]');
      if (!w.liveSocket || !main) {
        return { ok: false, reason: 'no_livesocket_or_main' };
      }
      const view = w.liveSocket.getViewByEl(main);
      if (!view) return { ok: false, reason: 'no_view' };
      return view
        .pushHookEvent(main, null, 'start_type_conversion', {
          target_type_key: targetTypeKey
        })
        .then(
          () => ({ ok: true }),
          (err: unknown) => ({
            ok: false,
            reason: `push_rejected: ${String(err)}`
          })
        );
    },
    { targetTypeKey }
  );
  if (!result.ok) {
    throw new Error(`pushHookEvent failed: ${result.reason}`);
  }
}

async function waitForWizard(page: Page): Promise<void> {
  // The migration wizard renders inside the ModalHost with
  // data-modal="migration".
  await page.waitForSelector('[data-modal="migration"]', { timeout: 10_000 });
  // Step 1 should be visible.
  await page.waitForSelector('[data-step="plan"]', { timeout: 5_000 });
}

async function shot(page: Page, slug: string): Promise<void> {
  const outPath = path.join(OUT_DIR, `${slug}.png`);
  await page.screenshot({ path: outPath, fullPage: false });
  // eslint-disable-next-line no-console
  console.log(`  captured ${outPath}`);
}

async function run(): Promise<void> {
  const browser: Browser = await chromium.launch({ headless: true });
  try {
    const context: BrowserContext = await browser.newContext({
      baseURL: BASE_URL,
      viewport: { width: 1440, height: 900 },
      ignoreHTTPSErrors: false
    });

    // eslint-disable-next-line no-console
    console.log('Signing in as :lawyer persona');
    await signInAsLawyer(context);

    const page = await context.newPage();

    // eslint-disable-next-line no-console
    console.log(
      `Opening /matters/${MATTER_ID}/documents/${DOCUMENT_ID}`
    );
    await openDocument(page);

    // eslint-disable-next-line no-console
    console.log('Dispatching start_type_conversion → franchise_v1');
    await dispatchStartTypeConversion(page, 'franchise_v1');
    await waitForWizard(page);
    await page.waitForTimeout(500);

    // Once the wizard is open, the step-1 form contains a <select> with
    // phx-change="set_migration_target" targeted at the ModalHost
    // LiveComponent. Selecting the option populates `@migration_target`
    // so step 3's "Create variant" button is no longer disabled.
    const targetSelect = page.locator('[data-role="migration-target-select"]');
    if (await targetSelect.count() > 0) {
      await targetSelect.selectOption('franchise_v1');
      await page.waitForTimeout(300);
    }

    // Step 1: Plan summary (the wizard already rendered the plan because
    // start_type_conversion ran the planner).
    await shot(page, 'wizard-step-1-plan');

    // Click "Next: field strategies" to advance to step 2.
    const nextFields = page.locator('[data-role="migration-next-fields"]');
    await nextFields.click();
    await page.waitForSelector('[data-step="field-strategies"]', {
      timeout: 5_000
    });
    await page.waitForTimeout(500);
    await shot(page, 'wizard-step-2-fields');

    // Click "Next: confirm" to advance to step 3.
    const nextConfirm = page.locator('[data-role="migration-next-confirm"]');
    await nextConfirm.click();
    await page.waitForSelector('[data-step="create-variant"]', {
      timeout: 5_000
    });
    await page.waitForTimeout(500);
    await shot(page, 'wizard-step-3-confirm');

    await context.close();
  } finally {
    await browser.close();
  }
}

run().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  process.exit(1);
});
