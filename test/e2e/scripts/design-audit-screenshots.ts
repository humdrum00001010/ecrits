/**
 * Design-audit screenshot harness — Wave 3C0-D.
 *
 * Drives a headless Chromium against the public sprite URL and captures
 * the seven public surfaces at TWO viewports each (375×667 mobile,
 * 1440×900 desktop). The output PNGs are committed alongside this script
 * as the before-state artifact for the visual-maturity audit.
 *
 * Re-run after tightening (with `SHOT_SUFFIX=after`) to produce the
 * after-state. Both passes write into `docs/design-audit/2026-05-15/`.
 *
 *   pnpm exec tsx scripts/design-audit-screenshots.ts          # before
 *   SHOT_SUFFIX=after pnpm exec tsx scripts/design-audit-screenshots.ts
 *
 * Auth: the `:lawyer` persona signs in via the test-auth endpoint
 * (`POST /test/personas/lawyer/sign_in`). Public pages (landing, login,
 * register) are captured without auth.
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
const SUFFIX = process.env.SHOT_SUFFIX ?? 'before';

// Resolve relative to this file so invocation from any cwd works. This
// script is loaded as an ES module (package.json declares "type":"module"),
// so __dirname/__filename are not available — derive them from import.meta.
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const OUT_SUBDIR = process.env.SHOT_DIR ?? '2026-05-15';

const OUT_DIR = path.resolve(
  __dirname,
  '..',
  '..',
  '..',
  'docs',
  'design-audit',
  OUT_SUBDIR
);

fs.mkdirSync(OUT_DIR, { recursive: true });

interface Viewport {
  name: 'mobile' | 'desktop';
  width: number;
  height: number;
}

const VIEWPORTS: Viewport[] = [
  { name: 'mobile', width: 375, height: 667 },
  { name: 'desktop', width: 1440, height: 900 }
];

interface Surface {
  slug: string;
  path: string;
  auth: boolean;
  // Optional extra action — e.g. "click #generate-token-button" to open a modal
  // and then capture a second screenshot with `slugSuffix` appended.
  extra?: {
    slugSuffix: string;
    action: (page: Page) => Promise<void>;
  };
}

const SURFACES: Surface[] = [
  { slug: 'landing', path: '/', auth: false },
  { slug: 'login', path: '/users/log-in', auth: false },
  { slug: 'register', path: '/users/register', auth: false },
  { slug: 'dashboard', path: '/dashboard', auth: true },
  { slug: 'users-settings', path: '/users/settings', auth: true },
  { slug: 'settings-hub', path: '/settings', auth: true },
  {
    slug: 'api-tokens',
    path: '/settings/api-tokens',
    auth: true,
    extra: {
      slugSuffix: 'modal',
      action: async (page: Page) => {
        await page.click('#generate-token-button');
        await page.waitForSelector('#generate-token-modal', { state: 'visible' });
      }
    }
  }
];

/**
 * Sign in as the `lawyer` persona on the supplied context. This relies on
 * the `:test_auth` plug being enabled on the sprite (it is — see
 * `feedback-browser-persona-tests.md`).
 *
 * `/users/settings` requires *sudo mode* (a fresh re-auth within the past
 * 10 minutes). The test-auth controller sets sudo mode by default, so a
 * single sign-in is enough for all four authenticated screenshots.
 */
async function signInAsLawyer(context: BrowserContext): Promise<void> {
  const resp = await context.request.post(`${BASE_URL}/test/personas/lawyer/sign_in`, {
    failOnStatusCode: true
  });
  if (resp.status() !== 200) {
    throw new Error(`Persona sign-in failed: ${resp.status()} ${await resp.text()}`);
  }
}

async function capture(
  context: BrowserContext,
  surface: Surface,
  viewport: Viewport
): Promise<void> {
  const page = await context.newPage();
  await page.setViewportSize({ width: viewport.width, height: viewport.height });

  const url = `${BASE_URL}${surface.path}`;
  await page.goto(url, { waitUntil: 'networkidle', timeout: 30_000 });

  // A small settle delay — some components (theme toggle, sticky nav)
  // run a JS frame after networkidle.
  await page.waitForTimeout(500);

  const filename = `${surface.slug}-${viewport.name}-${SUFFIX}.png`;
  const outPath = path.join(OUT_DIR, filename);
  await page.screenshot({ path: outPath, fullPage: true });
  // eslint-disable-next-line no-console
  console.log(`  captured ${outPath}`);

  if (surface.extra) {
    await surface.extra.action(page);
    // Wait for the modal animation to settle.
    await page.waitForTimeout(300);
    const modalFilename = `${surface.slug}-${surface.extra.slugSuffix}-${viewport.name}-${SUFFIX}.png`;
    const modalOut = path.join(OUT_DIR, modalFilename);
    await page.screenshot({ path: modalOut, fullPage: true });
    // eslint-disable-next-line no-console
    console.log(`  captured ${modalOut}`);
  }

  await page.close();
}

async function run(): Promise<void> {
  const browser: Browser = await chromium.launch({ headless: true });

  try {
    for (const viewport of VIEWPORTS) {
      // Two contexts per viewport — one anonymous for the public/auth
      // surfaces (landing, login, register) and one signed-in as :lawyer
      // for the protected surfaces (dashboard, settings, api-tokens).
      // Mixing them in a single context breaks the register page: it
      // redirects authenticated users back to /dashboard, so we'd capture
      // the dashboard instead of the registration form.
      const anonContext = await browser.newContext({
        baseURL: BASE_URL,
        viewport: { width: viewport.width, height: viewport.height },
        ignoreHTTPSErrors: false
      });
      const authContext = await browser.newContext({
        baseURL: BASE_URL,
        viewport: { width: viewport.width, height: viewport.height },
        ignoreHTTPSErrors: false
      });
      await signInAsLawyer(authContext);

      for (const surface of SURFACES) {
        // eslint-disable-next-line no-console
        console.log(`[${viewport.name}] ${surface.path}`);
        try {
          await capture(surface.auth ? authContext : anonContext, surface, viewport);
        } catch (err) {
          // eslint-disable-next-line no-console
          console.error(`  FAILED ${surface.slug}: ${(err as Error).message}`);
        }
      }

      await anonContext.close();
      await authContext.close();
    }
  } finally {
    await browser.close();
  }
}

run().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  process.exit(1);
});
