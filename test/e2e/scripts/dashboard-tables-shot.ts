import { chromium } from '@playwright/test';

const BASE_URL = 'https://contract-studio-v7zk.sprites.app';

async function main() {
  const browser = await chromium.launch();
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 }
  });
  const page = await context.newPage();

  // PersonaFactory has a known intermittent unique-violation bug on the
  // sprite. Retry up to 8 times until we get a 200/302.
  let signedIn = false;
  for (let i = 0; i < 8; i++) {
    const resp = await context.request.post(`${BASE_URL}/test/personas/lawyer/sign_in`);
    if (resp.status() === 200 || resp.status() === 302) {
      signedIn = true;
      break;
    }
    console.log(`sign-in attempt ${i + 1} got ${resp.status()}, retrying`);
  }
  if (!signedIn) {
    throw new Error('Persona sign-in failed after 8 attempts');
  }

  await page.goto(`${BASE_URL}/dashboard`);
  await page.waitForLoadState('networkidle');

  await page.screenshot({
    path: '/tmp/dashboard-tables-desktop.png',
    fullPage: true
  });
  console.log('OK: /tmp/dashboard-tables-desktop.png');
  await browser.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
