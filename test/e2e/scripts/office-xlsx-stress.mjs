// Reproduce the user's WHITE screen: open the EXACT 기관별 xlsx repeatedly in
// ONE page (one shared wasm engine), alternating with another doc, and watch
// whether paintTile eventually returns no pixels (heap fragmentation / the
// ~161MB single-tile alloc failing in a used-up 1GB heap).
import { chromium } from "@playwright/test";
const BASE = "http://localhost:4000";
const DIR = "/Users/phihu/Downloads";
const BIG = "기관별 연령별 인구통계(2026년 5월말 기준).xlsx"; // documentId ECE1F2F4 — the failing file
const SMALL = "인구 및 세대현황(2026년 5월말 기준).xlsx";
const t0 = Date.now(); const ts = () => String(Date.now() - t0).padStart(6) + "ms";
const line = (...a) => console.log(`[${ts()}]`, ...a);

const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
page.on("console", (m) => { const t = m.text(); if (/no pixels|Render failed|out of memory|RuntimeError|abort|Cannot enlarge|OOM/i.test(t)) line("c:", t.slice(0, 180)); });

async function liveNav(name) {
  await page.evaluate((h) => { const a = document.createElement("a"); a.href = h; a.setAttribute("data-phx-link","patch"); a.setAttribute("data-phx-link-state","push"); a.textContent="n"; document.body.appendChild(a); a.click(); a.remove(); },
    `${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(name)}`);
}
async function check(name, tag) {
  await page.waitForFunction((n) => decodeURIComponent(location.search).includes("document=" + n), name, { timeout: 15000 }).catch(() => {});
  for (let k = 0; k < 30; k++) {
    const st = await page.evaluate(() => {
      const c = document.querySelector("[data-role='office-wasm-canvas']");
      const s = document.querySelector("[data-role='office-wasm-status']");
      if (!c || c.width < 2) return { painted:false, status: s?s.textContent.trim().slice(0,80):null };
      const ctx = c.getContext("2d"); const d = ctx.getImageData(0,0,Math.min(c.width,400),Math.min(c.height,400)).data;
      let nw=0; for (let i=0;i<d.length;i+=4) if (d[i]<245||d[i+1]<245||d[i+2]<245) nw++;
      return { painted:true, w:c.width, h:c.height, sampleNonWhitePct:+(100*nw/(d.length/4)).toFixed(1) };
    });
    if (st.painted) { line(tag, JSON.stringify(st)); return st.sampleNonWhitePct > 0.5; }
    if (st.status && /failed|error|no pixels/i.test(st.status)) { line(tag, "FAILED", JSON.stringify(st)); return false; }
    await page.waitForTimeout(1000);
  }
  line(tag, "TIMEOUT-NOPAINT"); return false;
}

await page.goto(`${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(BIG)}`, { waitUntil: "domcontentloaded", timeout: 60000 });
let ok = await check(BIG, "BIG#0");
for (let i = 1; i <= 12 && ok; i++) {
  await liveNav(SMALL); await check(SMALL, `  small#${i}`);
  await liveNav(BIG);   ok = await check(BIG, `BIG#${i}`);
}
line("RESULT", ok ? "BIG kept rendering through all iterations" : "BIG WENT WHITE (reproduced)");
await browser.close();
