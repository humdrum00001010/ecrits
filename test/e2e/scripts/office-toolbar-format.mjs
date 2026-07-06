// Office toolbar formatting E2E — proves the quick-toolbar format/align
// commands act on the LIVE LOK drag selection in a REAL top-level
// cross-origin-isolated Chromium tab (the Tidewave iframe can't run office
// wasm — see office-boot-debug.mjs).
//
// Flow: open workspace → open the docx → drag-select the "1. 기본 정보"
// heading → Bold (LOK toggle: the already-bold heading UN-bolds) → Bold again
// (re-bolds) → align-center via the dropdown → align-left restore.
// Oracle: LOK plain-text selection (only text/plain;charset=utf-8 is a
// supported flavor) + step screenshots for visual judgment. Compressed-PNG
// byte-diffs are NOT a reliable oracle — crop and look.
//
// Run from test/e2e:
//   node scripts/office-toolbar-format.mjs [workspace-dir] [file-substring]
// Defaults: /tmp/office-toolbar-ws test.docx (stage a docx there first).
import { chromium } from "@playwright/test";

const WS = process.argv[2] || "/tmp/office-toolbar-ws";
const FILE = process.argv[3] || "test.docx";
const OUT = "/tmp/office-toolbar-e2e";
const LINE = { x1: 455, x2: 545, y: 390 }; // heading line at 1600x1000, dpr1

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
await import("node:fs").then((fs) => fs.mkdirSync(OUT, { recursive: true }));

await page.goto("http://localhost:4000/", { waitUntil: "networkidle" });
await page.fill("#local-path-input", WS);
await page.press("#local-path-input", "Enter");
await page.waitForURL("**/workspace**", { timeout: 30000 });
await page.waitForFunction(() => window.liveSocket?.isConnected(), undefined, { timeout: 30000 });
await page.waitForTimeout(1000);

await page.click(`[data-role="repo-browser-row"][phx-value-path*="${FILE}"]`);
await page.waitForFunction(() => {
  const ed = document.querySelector("[phx-hook='WasmOfficeEditor']")?.__wasmOfficeEditor;
  return !!(ed && ed.loaded && ed.parts?.length > 0 &&
    Array.from(document.querySelectorAll("canvas")).some((c) => c.width > 200));
}, undefined, { timeout: 240000 });
await page.waitForTimeout(2500);

await page.mouse.move(LINE.x1, LINE.y);
await page.mouse.down();
for (let x = LINE.x1 + 10; x <= LINE.x2; x += 12) {
  await page.mouse.move(x, LINE.y);
  await page.waitForTimeout(35);
}
await page.mouse.up();
await page.waitForTimeout(900);

const selText = await page.evaluate(() => {
  const ed = document.querySelector("[phx-hook='WasmOfficeEditor']").__wasmOfficeEditor;
  try { return String(ed.callApi("getTextSelection", "text/plain;charset=utf-8") || "").replace(/\0/g, ""); } catch { return ""; }
});
console.log("selected:", JSON.stringify(selText.slice(0, 60)));
if (!selText.trim()) {
  await page.screenshot({ path: `${OUT}/fail-nosel.png` });
  console.log("FAIL: nothing selected");
  await browser.close();
  process.exit(2);
}

const steps = [
  ["1-selected", null],
  ["2-bold-toggle", () => page.click("#local-document-quick-toolbar [data-command='bold']")],
  ["3-bold-toggle-back", () => page.click("#local-document-quick-toolbar [data-command='bold']")],
  ["4-align-center", async () => {
    await page.click("[data-role='align-menu-button']");
    await page.waitForTimeout(300);
    await page.click("[data-role='align-menu'] [data-command='align-center']");
  }],
  ["5-align-left-restore", async () => {
    await page.click("[data-role='align-menu-button']");
    await page.waitForTimeout(300);
    await page.click("[data-role='align-menu'] [data-command='align-left']");
  }],
];
for (const [name, act] of steps) {
  if (act) { await act(); await page.waitForTimeout(1000); }
  await page.screenshot({ path: `${OUT}/${name}.png` });
  console.log("step:", name);
}
console.log(`DONE — judge ${OUT}/*.png (crop the heading region; bold toggles stroke weight, align moves the line)`);
await browser.close();
