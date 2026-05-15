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

  const result = await page.evaluate(({ targetTypeKey }) => {
    const w = window as any;
    const main = document.querySelector("[data-phx-main]");
    const view = w.liveSocket.getViewByEl(main);
    return view.pushHookEvent(main, null, "start_type_conversion", { target_type_key: targetTypeKey })
      .then((r: unknown) => ({ ok: true, reply: r }), (err: unknown) => ({ ok: false, reason: String(err) }));
  }, { targetTypeKey: "franchise_v1" });
  console.log("pushEvent:", JSON.stringify(result));

  await page.waitForTimeout(1500);

  // Inspect all flash containers
  const flashes = await page.evaluate(() => {
    return Array.from(document.querySelectorAll("#flash-group [data-flash], #flash-group div"))
      .map((e: Element) => (e as HTMLElement).innerText.trim())
      .filter((t: string) => t.length > 0);
  });
  console.log("flash:", JSON.stringify(flashes));

  await browser.close();
})();
