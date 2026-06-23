// Open an xlsx in a real isolated Chromium tab, wait for the office WASM editor
// to paint, screenshot the rendered page, and measure non-blank pixels — so we
// can SEE whether Calc actually renders content (vs an empty/white canvas).
import { chromium } from "@playwright/test";

const DIR = process.argv[2] || "/Users/phihu/Downloads";
const DOC = process.argv[3];
const OUT = process.argv[4] || "/tmp/xlsx-shot.png";
if (!DOC) { console.error("usage: office-xlsx-shot.mjs <dir> <document> <outpng>"); process.exit(2); }
const BASE = process.env.E2E_BASE_URL || "http://localhost:4000";
const URLP = `${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`;
const t0 = Date.now(); const ts = () => String(Date.now() - t0).padStart(6) + "ms";
const line = (...a) => console.log(`[${ts()}]`, ...a);

const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1400, height: 1000 }, deviceScaleFactor: Number(process.env.DPR) || 1 });
page.on("console", (m) => { const t = m.text(); if (/Render failed|no pixels|ABORT|load failed|parts\/geometry/.test(t)) line("c:", t.slice(0, 200)); });

line("GOTO", DOC);
await page.goto(URLP, { waitUntil: "domcontentloaded", timeout: 60000 });

let painted = false;
for (let i = 0; i < 60; i++) {
  const st = await page.evaluate(() => {
    const c = document.querySelector("[data-role='office-wasm-canvas']");
    const s = document.querySelector("[data-role='office-wasm-status']");
    return { w: c ? c.width : 0, h: c ? c.height : 0, status: s ? s.textContent.trim() : null };
  });
  if (st.w > 1 && st.h > 1) { painted = true; line("CANVAS", st.w + "x" + st.h); break; }
  if (st.status && /failed|error/i.test(st.status)) { line("STATUS-ERR", st.status.slice(0, 160)); break; }
  await page.waitForTimeout(1000);
}

if (painted) {
  await page.waitForTimeout(1500); // settle
  // measure non-near-white pixels in the first page canvas
  const stat = await page.evaluate(() => {
    const c = document.querySelector("[data-role='office-wasm-canvas']");
    const ctx = c.getContext("2d");
    const { data } = ctx.getImageData(0, 0, c.width, c.height);
    let nonWhite = 0, dark = 0;
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i + 1], b = data[i + 2];
      if (r < 245 || g < 245 || b < 245) nonWhite++;
      if (r < 128 && g < 128 && b < 128) dark++;
    }
    const total = data.length / 4;
    return { total, nonWhitePct: +(100 * nonWhite / total).toFixed(2), darkPct: +(100 * dark / total).toFixed(3) };
  });
  line("PIXELS", JSON.stringify(stat));
  const el = await page.$("[data-role='office-wasm-pages']");
  await (el || page).screenshot({ path: OUT });
  line("SHOT", OUT);
} else {
  line("DID NOT PAINT");
  await page.screenshot({ path: OUT });
}
await browser.close();
