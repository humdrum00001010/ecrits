// Verify pinch-to-zoom (ctrl+wheel) zooms the editor content for any doc type.
import { chromium } from "@playwright/test";
const [, , DIR, DOC] = process.argv;
const BASE = "http://localhost:4000";
const URLP = `${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`;
const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1400, height: 1000 }, deviceScaleFactor: Number(process.env.DPR) || 1 });
await page.goto(URLP, { waitUntil: "domcontentloaded", timeout: 60000 });
await page.waitForSelector("[data-editor-zoomable]", { timeout: 60000 }).catch(() => {});
await page.waitForTimeout(6000); // let office/hwp paint

const read = () => page.$eval("[data-editor-zoomable]", (el) => ({
  zoom: el.style.zoom || "1",
  rendered: !!el.querySelector("canvas") || (el.textContent || "").trim().length > 0,
}));
const pinch = (deltaY, n = 1) => page.$eval("[data-editor-zoomable]", (el, d) => {
  const t = el.querySelector("canvas") || el;
  for (let i = 0; i < d.n; i++) t.dispatchEvent(new WheelEvent("wheel", { ctrlKey: true, deltaY: d.deltaY, bubbles: true, cancelable: true }));
}, { deltaY, n });

console.log(DOC);
console.log("  initial   ", JSON.stringify(await read()));
await pinch(-300, 3); await page.waitForTimeout(150);
console.log("  zoom-in   ", JSON.stringify(await read()));
await pinch(300, 6); await page.waitForTimeout(150);
console.log("  zoom-out  ", JSON.stringify(await read()));
await browser.close();
