// Font-row toolbar E2E — proves the quick-toolbar size input / text color /
// highlighter act on a REAL drag selection on BOTH editor arms,
// in a top-level Chromium (never background-throttled; the Tidewave iframe
// can't run office wasm and a backgrounded tab freezes rAF + lazy renders).
//
// HWP oracle: engine char properties at the selection (fontSize/textColor/
// shadeColor) + the toolbar size input display. Office oracle: LOK plain-text
// selection stays live + step screenshots for visual judgment (the LOK
// STATE_CHANGED feed carries no font size).
//
// The color buttons open a native OS picker which automation cannot drive, so
// the script sets the hidden <input type=color> and fires "change" — the
// exact event the picker produces.
//
// Run from test/e2e:
//   node scripts/fontrow-toolbar.mjs [workspace-dir]
// Defaults: /tmp/fontrow-ws (stage law.hwpx + test.docx + test.pptx there
// first). The pptx phase probes several y-lines for the slide title (Impress
// needs the text-bearing shape activated before a drag becomes a selection).
import { chromium } from "@playwright/test";
import fs from "node:fs";

const WS = process.argv[2] || "/tmp/fontrow-ws";
const OUT = "/tmp/fontrow-e2e";
fs.mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
let failures = 0;
const check = (name, ok, detail = "") => {
  console.log(`${ok ? "PASS" : "FAIL"}: ${name}${detail ? " — " + detail : ""}`);
  if (!ok) failures++;
};

await page.goto("http://localhost:4000/", { waitUntil: "networkidle" });
await page.fill("#local-path-input", WS);
await page.press("#local-path-input", "Enter");
await page.waitForURL("**/workspace**", { timeout: 30000 });
await page.waitForFunction(() => window.liveSocket?.isConnected(), undefined, { timeout: 30000 });
await page.waitForTimeout(1000);

// ── Phase A: HWP ────────────────────────────────────────────────────────────
await page.click(`[data-role="repo-browser-row"][phx-value-path*="law.hwpx"]`);
await page.waitForFunction(() => {
  const ed = document.querySelector("[data-role='local-hwp-editor']")?.__wasmHwpEditor;
  return !!(ed && ed.doc && document.querySelectorAll("[data-role='local-hwp-page']").length > 5);
}, undefined, { timeout: 120000 });
await page.waitForTimeout(1500);

// Scroll a body page into view and wait for its lazy raster.
await page.evaluate(() => {
  document.querySelector("[data-role='local-hwp-page'][data-page-index='6']").scrollIntoView({ block: "center" });
});
await page.waitForFunction(() => {
  const c = document.querySelector("[data-role='local-hwp-page'][data-page-index='6'] [data-role='ehwp-canvas']");
  return !!(c && c.width > 400);
}, undefined, { timeout: 60000 });
await page.waitForTimeout(800);

// Real drag across a body line (same landmark the Tidewave run hit: para 80).
const hwpRect = await page.evaluate(() => {
  const r = document
    .querySelector("[data-role='local-hwp-page'][data-page-index='6'] [data-role='ehwp-canvas']")
    .getBoundingClientRect();
  return { left: r.left, top: r.top, width: r.width, height: r.height };
});
const hy = hwpRect.top + hwpRect.height * 0.4;
const hx1 = hwpRect.left + hwpRect.width * 0.25;
const hx2 = hwpRect.left + hwpRect.width * 0.65;
await page.mouse.move(hx1, hy);
await page.mouse.down();
for (let x = hx1 + 10; x <= hx2; x += 20) {
  await page.mouse.move(x, hy);
  await page.waitForTimeout(30);
}
await page.mouse.up();
await page.waitForTimeout(800);

const hwpSel = await page.evaluate(() => {
  const ed = document.querySelector("[data-role='local-hwp-editor']").__wasmHwpEditor;
  return ed.sel;
});
check("hwp drag selects body text", !!hwpSel, JSON.stringify(hwpSel));
if (!hwpSel) {
  await page.screenshot({ path: `${OUT}/hwp-fail-nosel.png` });
  await browser.close();
  process.exit(2);
}

const hwpProbe = { s: hwpSel.section, p: hwpSel.anchor.paragraph, o: hwpSel.anchor.offset };
const hwpCharProps = async () =>
  page.evaluate(({ s, p, o }) => {
    const ed = document.querySelector("[data-role='local-hwp-editor']").__wasmHwpEditor;
    const raw = JSON.parse(ed.doc.getCharPropertiesAt(s, p, o));
    return { fontSize: raw.fontSize, textColor: raw.textColor, shadeColor: raw.shadeColor };
  }, hwpProbe);
const sizeShown = async () => page.$eval("[data-role='font-size-input']", (el) => el.value);

const before = await hwpCharProps();
console.log("hwp selection char props before:", JSON.stringify(before), "input:", await sizeShown());
check("hwp size input mirrors caret size", (await sizeShown()) === String(before.fontSize / 100), `shows ${await sizeShown()}`);

// Absolute set via the input + Enter (the field is the only size control).
await page.fill("[data-role='font-size-input']", "20");
await page.press("[data-role='font-size-input']", "Enter");
await page.waitForTimeout(1200);
let now = await hwpCharProps();
check("hwp font-size-set 20pt", now.fontSize === 2000, `${now.fontSize}`);

// Text color via the hidden native-picker input.
await page.evaluate(() => {
  const input = document.querySelector("[data-role='text-color-input']");
  input.value = "#e11d48";
  input.dispatchEvent(new Event("change", { bubbles: true }));
});
await page.waitForTimeout(1200);
now = await hwpCharProps();
check("hwp text color applies", now.textColor === "#e11d48", `${now.textColor}`);

// Highlight (engine shadeColor) via its hidden input.
await page.evaluate(() => {
  const input = document.querySelector("[data-role='highlight-color-input']");
  input.value = "#fde047";
  input.dispatchEvent(new Event("change", { bubbles: true }));
});
await page.waitForTimeout(1200);
now = await hwpCharProps();
check("hwp highlight applies", now.shadeColor === "#fde047", `${now.shadeColor}`);

await page.screenshot({ path: `${OUT}/hwp-after.png`, clip: { x: hwpRect.left, y: Math.max(0, hwpRect.top), width: hwpRect.width, height: Math.min(500, hwpRect.height) } });
await page.screenshot({ path: `${OUT}/hwp-toolbar.png`, clip: { x: 0, y: 0, width: 1600, height: 120 } });

// ── Phase B: office (docx) ──────────────────────────────────────────────────
await page.click(`[data-role="repo-browser-row"][phx-value-path*="test.docx"]`);
await page.waitForFunction(() => {
  const ed = document.querySelector("[phx-hook='WasmOfficeEditor']")?.__wasmOfficeEditor;
  return !!(ed && ed.loaded && ed.parts?.length > 0 &&
    Array.from(document.querySelectorAll("canvas")).some((c) => c.width > 200));
}, undefined, { timeout: 240000 });
await page.waitForTimeout(2500);

// Drag the "1. 기본 정보" heading (coords proven in office-toolbar-format.mjs).
const LINE = { x1: 455, x2: 545, y: 390 };
await page.mouse.move(LINE.x1, LINE.y);
await page.mouse.down();
for (let x = LINE.x1 + 10; x <= LINE.x2; x += 12) {
  await page.mouse.move(x, LINE.y);
  await page.waitForTimeout(35);
}
await page.mouse.up();
await page.waitForTimeout(900);

const officeSel = await page.evaluate(() => {
  const ed = document.querySelector("[phx-hook='WasmOfficeEditor']").__wasmOfficeEditor;
  try { return String(ed.callApi("getTextSelection", "text/plain;charset=utf-8") || "").replace(/\0/g, ""); } catch { return ""; }
});
check("office drag selects heading", !!officeSel.trim(), JSON.stringify(officeSel.slice(0, 40)));
if (!officeSel.trim()) {
  await page.screenshot({ path: `${OUT}/office-fail-nosel.png` });
  await browser.close();
  process.exit(2);
}
await page.screenshot({ path: `${OUT}/office-1-selected.png` });

// Absolute 30pt, red text, yellow highlight — all judged by screenshots (no
// size in the LOK state feed).
const officeSteps = [
  ["office-2-set-30pt", async () => {
    await page.fill("[data-role='font-size-input']", "30");
    await page.press("[data-role='font-size-input']", "Enter");
  }],
  ["office-3-text-red", () => page.evaluate(() => {
    const input = document.querySelector("[data-role='text-color-input']");
    input.value = "#e11d48";
    input.dispatchEvent(new Event("change", { bubbles: true }));
  })],
  ["office-4-highlight-yellow", () => page.evaluate(() => {
    const input = document.querySelector("[data-role='highlight-color-input']");
    input.value = "#fde047";
    input.dispatchEvent(new Event("change", { bubbles: true }));
  })],
];
for (const [name, act] of officeSteps) {
  await act();
  await page.waitForTimeout(1300);
  await page.screenshot({ path: `${OUT}/${name}.png` });
  console.log("step:", name);
}

// The selection must survive every command (LOK acts on it in place).
const officeSelAfter = await page.evaluate(() => {
  const ed = document.querySelector("[phx-hook='WasmOfficeEditor']").__wasmOfficeEditor;
  try { return String(ed.callApi("getTextSelection", "text/plain;charset=utf-8") || "").replace(/\0/g, ""); } catch { return ""; }
});
check("office selection survives the font row", officeSelAfter.trim() === officeSel.trim(), JSON.stringify(officeSelAfter.slice(0, 40)));

// ── Phase C: office (pptx / Impress) ────────────────────────────────────────
// Impress routes text drags through shape activation (pending drag → enter
// the shape's text editor → direct selection) — a genuinely different LOK
// path from Writer, so the font row must be proven here too.
await page.click(`[data-role="repo-browser-row"][phx-value-path*="test.pptx"]`);
await page.waitForFunction(() => {
  const ed = [...document.querySelectorAll("[phx-hook='WasmOfficeEditor']")]
    .map((el) => el.__wasmOfficeEditor)
    .find((e) => e && e.format === "pptx");
  return !!(ed && ed.loaded && ed.parts?.length > 0);
}, undefined, { timeout: 240000 });
await page.waitForTimeout(2500);

const pptxEditorSel = () =>
  [...document.querySelectorAll("[phx-hook='WasmOfficeEditor']")]
    .map((el) => el.__wasmOfficeEditor)
    .find((e) => e && e.format === "pptx");
const pptxSelText = () =>
  page.evaluate(`(() => {
    const ed = (${pptxEditorSel.toString()})();
    try { return String(ed.callApi("getTextSelection", "text/plain;charset=utf-8") || "").replace(/\\0/g, ""); } catch { return ""; }
  })()`);

const slideRect = await page.evaluate(() => {
  const canvas = [...document.querySelectorAll("[data-role='office-wasm-canvas']")]
    .find((c) => c.offsetParent !== null && c.getBoundingClientRect().width > 200);
  const r = canvas.getBoundingClientRect();
  return { left: r.left, top: r.top, width: r.width, height: r.height };
});

// Probe downward for a text line the drag can select (title position varies).
let pptxSel = "";
for (const fy of [0.15, 0.22, 0.3, 0.4, 0.5, 0.6]) {
  const y = slideRect.top + slideRect.height * fy;
  const x1 = slideRect.left + slideRect.width * 0.25;
  const x2 = slideRect.left + slideRect.width * 0.7;
  await page.mouse.move(x1, y);
  await page.mouse.down();
  for (let x = x1 + 10; x <= x2; x += 15) {
    await page.mouse.move(x, y);
    await page.waitForTimeout(30);
  }
  await page.mouse.up();
  await page.waitForTimeout(900);
  pptxSel = await pptxSelText();
  if (pptxSel.trim()) break;
  await page.keyboard.press("Escape");
  await page.waitForTimeout(300);
}
check("pptx drag selects slide text", !!pptxSel.trim(), JSON.stringify(pptxSel.slice(0, 40)));
if (!pptxSel.trim()) {
  await page.screenshot({ path: `${OUT}/pptx-fail-nosel.png` });
  await browser.close();
  process.exit(2);
}
await page.screenshot({ path: `${OUT}/pptx-1-selected.png` });

const pptxSteps = [
  ["pptx-2-set-40pt", async () => {
    await page.fill("[data-role='font-size-input']", "40");
    await page.press("[data-role='font-size-input']", "Enter");
  }],
  ["pptx-3-text-red", () => page.evaluate(() => {
    const input = document.querySelector("[data-role='text-color-input']");
    input.value = "#e11d48";
    input.dispatchEvent(new Event("change", { bubbles: true }));
  })],
  ["pptx-4-highlight-yellow", () => page.evaluate(() => {
    const input = document.querySelector("[data-role='highlight-color-input']");
    input.value = "#fde047";
    input.dispatchEvent(new Event("change", { bubbles: true }));
  })],
];
for (const [name, act] of pptxSteps) {
  await act();
  await page.waitForTimeout(1300);
  await page.screenshot({ path: `${OUT}/${name}.png` });
  console.log("step:", name);
}

const pptxSelAfter = await pptxSelText();
check("pptx selection survives the font row", pptxSelAfter.trim() === pptxSel.trim(), JSON.stringify(pptxSelAfter.slice(0, 40)));

console.log(failures === 0 ? "ALL CHECKS PASSED" : `${failures} CHECK(S) FAILED`);
console.log(`screenshots: ${OUT}/*.png — judge office-2..4 + pptx-2..4 crops (size set, red glyphs, yellow band)`);
await browser.close();
process.exit(failures === 0 ? 0 : 1);
