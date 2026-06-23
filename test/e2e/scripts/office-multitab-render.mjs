// Multi-tab RENDER test: in ONE page (shared office engine), live-nav between
// two xlsx and verify each PAINTS pixels after the switch — reproduces the
// user's session where they switch docs without a full page reload.
import { chromium } from "@playwright/test";
const BASE = "http://localhost:4000";
const DIR = "/Users/phihu/Downloads";
const A = "인구 및 세대현황(2026년 5월말 기준).xlsx";
const B = "기관별 연령별 인구통계(2026년 5월말 기준).xlsx";
const t0 = Date.now(); const ts = () => String(Date.now() - t0).padStart(6) + "ms";
const line = (...a) => console.log(`[${ts()}]`, ...a);

const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
page.on("console", (m) => { const t = m.text(); if (/Render failed|no pixels|ABORT/.test(t)) line("c:", t.slice(0, 160)); });

async function liveNav(name) {
  await page.evaluate((h) => {
    const a = document.createElement("a");
    a.href = h; a.setAttribute("data-phx-link", "patch"); a.setAttribute("data-phx-link-state", "push");
    a.textContent = "n"; document.body.appendChild(a); a.click(); a.remove();
  }, `${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(name)}`);
}
async function waitPaint(label) {
  await page.waitForFunction((n) => decodeURIComponent(location.search).includes("document=" + n), name(label), { timeout: 15000 }).catch(() => {});
  for (let k = 0; k < 40; k++) {
    const st = await page.evaluate(() => {
      const c = document.querySelector("[data-role='office-wasm-canvas']");
      const s = document.querySelector("[data-role='office-wasm-status']");
      if (!c || c.width < 2) return { painted: false, status: s ? s.textContent.trim() : null };
      const ctx = c.getContext("2d"); const { data } = ctx.getImageData(0, 0, c.width, c.height);
      let nonWhite = 0; for (let i = 0; i < data.length; i += 4) if (data[i] < 245 || data[i+1] < 245 || data[i+2] < 245) nonWhite++;
      return { painted: true, w: c.width, h: c.height, nonWhitePct: +(100*nonWhite/(data.length/4)).toFixed(1), status: s?s.textContent.trim():null };
    });
    if (st.painted) { line(label, "PAINTED", JSON.stringify(st)); return true; }
    if (st.status && /failed|error/i.test(st.status)) { line(label, "ERROR", st.status.slice(0,120)); return false; }
    await page.waitForTimeout(1000);
  }
  line(label, "NO PAINT (timeout)"); return false;
}
function name(l){ return l.startsWith("A") ? A : B; }

await page.goto(`${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(A)}`, { waitUntil: "domcontentloaded", timeout: 60000 });
await waitPaint("A(인구)#1");
await liveNav(B); await waitPaint("B(기관별)#1");
await liveNav(A); await waitPaint("A(인구)#2");
await liveNav(B); await waitPaint("B(기관별)#2");
await browser.close();
