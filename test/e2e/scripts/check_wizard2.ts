import { chromium } from "@playwright/test";

const BASE_URL = "https://contract-studio-v7zk.sprites.app";
const MATTER_ID = "a0e14351-2d65-43fe-b3c5-d5878b0dfa0e";
const DOCUMENT_ID = "e0e29d1e-1db6-4586-9863-eea94d1f193a";

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ baseURL: BASE_URL, viewport: { width: 1440, height: 900 } });
  await context.request.post(`${BASE_URL}/test/personas/lawyer/sign_in`);
  const page = await context.newPage();
  page.on("pageerror", (e) => console.log("PAGE ERROR:", e.message));
  page.on("console", (msg) => console.log("CONSOLE:", msg.type(), msg.text()));
  await page.goto(`${BASE_URL}/matters/${MATTER_ID}/documents/${DOCUMENT_ID}`);
  await page.waitForSelector("[data-phx-main]");
  await page.waitForFunction(() => (window as any).liveSocket?.isConnected?.());
  await page.waitForTimeout(800);

  const before = await page.locator("[data-role=\"modal-host\"]").getAttribute("data-any-open");
  console.log("BEFORE data-any-open:", before);

  const result = await page.evaluate(({ targetTypeKey }) => {
    const w = window as any;
    const main = document.querySelector("[data-phx-main]");
    if (!w.liveSocket || !main) return { ok: false, reason: "no_liveSocket" };
    const view = w.liveSocket.getViewByEl(main);
    return view.pushHookEvent(main, null, "start_type_conversion", { target_type_key: targetTypeKey })
      .then((r: unknown) => ({ ok: true, reply: r }), (err: unknown) => ({ ok: false, reason: String(err) }));
  }, { targetTypeKey: "franchise_v1" });
  console.log("pushEvent result:", JSON.stringify(result));

  await page.waitForTimeout(2000);

  const after = await page.locator("[data-role=\"modal-host\"]").getAttribute("data-any-open");
  console.log("AFTER data-any-open:", after);

  const html = await page.locator("[data-role=\"modal-host\"]").innerHTML();
  console.log("modal-host HTML (first 500 chars):", html.substring(0, 500));

  await browser.close();
})();
