import { chromium } from "@playwright/test";

const BASE_URL = "https://contract-studio-v7zk.sprites.app";
const MATTER_ID = "a0e14351-2d65-43fe-b3c5-d5878b0dfa0e";
const DOCUMENT_ID = "e0e29d1e-1db6-4586-9863-eea94d1f193a";

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ baseURL: BASE_URL, viewport: { width: 1440, height: 900 } });
  await context.request.post(`${BASE_URL}/test/personas/lawyer/sign_in`);
  const page = await context.newPage();
  await page.goto(`${BASE_URL}/matters/${MATTER_ID}/documents/${DOCUMENT_ID}`);
  await page.waitForSelector("[data-phx-main]");
  await page.waitForFunction(() => (window as any).liveSocket?.isConnected?.());
  await page.waitForTimeout(800);

  // Dispatch start_type_conversion
  const result = await page.evaluate(({ targetTypeKey }) => {
    const w = window as any;
    const main = document.querySelector("[data-phx-main]");
    if (!w.liveSocket || !main) return { ok: false, reason: "no_liveSocket" };
    const view = w.liveSocket.getViewByEl(main);
    return view.pushHookEvent(main, null, "start_type_conversion", { target_type_key: targetTypeKey })
      .then(() => ({ ok: true }), (err: unknown) => ({ ok: false, reason: String(err) }));
  }, { targetTypeKey: "franchise_v1" });
  console.log("pushEvent result:", JSON.stringify(result));

  await page.waitForTimeout(2000);

  // Look for the modal-host attributes
  const modalHostHtml = await page.locator("[data-role=\"modal-host\"]").innerHTML().catch(() => "<not found>");
  console.log("modal-host inner length:", modalHostHtml.length);
  console.log("modal-host has any-open=true:", modalHostHtml.indexOf("data-any-open") >= 0 ? await page.locator("[data-role=\"modal-host\"]").getAttribute("data-any-open") : "n/a");

  // Look for modal=migration
  const migrationCount = await page.locator("[data-modal=\"migration\"]").count();
  console.log("[data-modal=\"migration\"] count:", migrationCount);

  // Look for flash
  const flashText = await page.locator("[role=\"alert\"], .alert").allTextContents();
  console.log("flashes:", JSON.stringify(flashText));

  await browser.close();
})();
