// Office WASM multi-tab WEDGE repro — the real difference vs a clean single-doc
// tab: ONE long-lived JS context, the SHARED single LOK engine, and overlapping
// imports caused by switching tabs mid-import (live nav remounts the hook but
// the old loadFromBytes keeps running on the one engine → racing loadFromBytes).
//
// Run from test/e2e:  node scripts/office-multitab-debug.mjs
import { chromium } from "@playwright/test";

const BASE = process.env.E2E_BASE_URL || "http://localhost:4000";
const DIR = "/Users/phihu/Downloads";
// Heaviest office docs available → maximize import overlap on the single engine.
const DOCS = ["CA-Lec6-RISCV-Cache-1.pptx", "CSD-Lec9-Interrupts.pptx", "26-1_RL_final_project.pptx"];
const url0 = `${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOCS[0])}`;

const t0 = Date.now();
const ts = () => String(Date.now() - t0).padStart(6) + "ms";
const line = (tag, ...a) => console.log(`[${ts()}] ${tag}`, ...a);

const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

const flagged = [];
const KEEP = /office-wasm\] (t\+|ABORT|load failed|API shape|parts\/geometry|Module state)|RuntimeError|memory access out of bounds|Aborted\b|previously failed|abort\(|unreachable|importScripts|table import|wedge/i;
const BAD = /ABORT|load failed|memory access out of bounds|Aborted\b|previously failed|unreachable|RuntimeError|table import|wedge/i;
page.on("console", (m) => {
  const t = m.text();
  if (KEEP.test(t)) { line("c:" + m.type(), t); if (BAD.test(t)) flagged.push(t); }
});
page.on("pageerror", (e) => { line("PAGEERROR", e.message); flagged.push("pageerror:" + e.message); });
page.on("crash", () => { line("PAGE-CRASH"); flagged.push("page-crash"); });

const probe = () =>
  page.evaluate(() => {
    const M = window.Module || window.__officeWasmModule;
    const s = document.querySelector("[data-role='office-wasm-status']");
    let lok = null;
    try { if (M && typeof M.lok_is_ready === "function") lok = M.lok_is_ready() === true; } catch (e) { lok = "throw"; }
    const ed = window.__officeWasmEditor;
    const viewer = document.querySelector("[data-role='office-wasm-viewer']");
    let canvasState = {};
    try { canvasState = JSON.parse(viewer?.dataset.canvasState || "{}"); } catch (_error) {}
    return {
      status: s ? s.textContent.trim() : null,
      canvas: !!document.querySelector("[data-role='office-wasm-canvas']"),
      parts: ed && ed.parts ? ed.parts.length : 0,
      lok,
      doc: canvasState.documentId || null,
    };
  });

// Open/switch a doc via LiveView LIVE NAVIGATION (same JS context, engine
// singleton persists) — exactly what tab_switch/workspace.document.open do (push_patch to the
// workspace document URL). Inject a data-phx-link anchor and click it so the
// LiveView client intercepts and patches without a full page reload.
async function liveNav(name) {
  const href = `${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(name)}`;
  await page.evaluate((h) => {
    const a = document.createElement("a");
    a.href = h;
    a.setAttribute("data-phx-link", "patch");
    a.setAttribute("data-phx-link-state", "push");
    a.style.position = "fixed";
    a.textContent = "nav";
    document.body.appendChild(a);
    a.click();
    a.remove();
  }, href);
  line("NAV", name, "-> search=" + (await page.evaluate(() => location.search)));
}

line("GOTO", url0);
await page.goto(url0, { waitUntil: "domcontentloaded", timeout: 60000 });
await page
  .waitForFunction(() => window.liveSocket && window.liveSocket.isConnected && window.liveSocket.isConnected(), null, { timeout: 15000 })
  .catch(() => line("LV-NOT-CONNECTED"));
line("ENV", JSON.stringify(await page.evaluate(() => ({ coi: self.crossOriginIsolated, sab: typeof SharedArrayBuffer }))));

// doc1 engine boots ~2.2s then begins a heavy 49-slide import; fire doc2/doc3
// DURING that import to overlap loadFromBytes on the one engine.
await page.waitForTimeout(2600);
line("PROBE@boot", JSON.stringify(await probe()));
await liveNav(DOCS[1]);
await page.waitForTimeout(600);
await liveNav(DOCS[2]);
await page.waitForTimeout(400);

// Rapid round-robin live-nav to force remount-mid-import races on the one engine.
for (let r = 0; r < 8; r++) { await liveNav(DOCS[r % 3]); await page.waitForTimeout(250); }
// Let the live-nav queue drain so the settle navs below are the only pending ones.
await page.waitForTimeout(2500);

// Correctness + no-wedge: visit each doc, WAIT for the nav to actually land, then
// poll up to 40s for a painted canvas with its own geometry (proves switching
// still loads the right doc — supersede-drop must not drop a doc we land on).
const outcome = {};
for (const name of DOCS) {
  await liveNav(name);
  await page
    .waitForFunction((n) => decodeURIComponent(location.search).includes("document=" + n), name, { timeout: 20000 })
    .catch(() => line("NAV-NOT-LANDED", name));
  let last = "", res = "WEDGED(no-canvas)";
  for (let k = 0; k < 40; k++) {
    const st = await probe();
    const sig = JSON.stringify(st);
    if (sig !== last) { line(`PROBE[${name}]`, sig); last = sig; }
    if (st.canvas && st.parts > 0) { res = `BOOTED(parts=${st.parts})`; break; }
    if (st.status && /failed|error|cannot load/i.test(st.status)) { res = "ERROR: " + st.status; break; }
    await page.waitForTimeout(1000);
  }
  outcome[name] = res;
}

line("OUTCOME", JSON.stringify(outcome, null, 2));
line("FLAGGED", flagged.length ? JSON.stringify([...new Set(flagged)].slice(0, 8), null, 2) : "none");
await browser.close();
