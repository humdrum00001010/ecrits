// Profile the per-edit JS path: every doc.edit ends in finishAgentEdit ->
// (_elementsCache=null) + rendered.clear() + renderVisiblePages(). Measure the
// two JS-side costs an edit pays: the full re-paint of visible pages and the IR
// re-parse (getElements) the next read triggers.
import { chromium } from "@playwright/test";
const [, , DIR, DOC] = process.argv;
const BASE = "http://localhost:4000";
const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1400, height: 1000 }, deviceScaleFactor: Number(process.env.DPR) || 1 });
await page.goto(`${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`, { waitUntil: "domcontentloaded", timeout: 60000 });
await page.waitForSelector("[data-editor-zoomable] canvas, [data-role='office-wasm-canvas']", { timeout: 60000 }).catch(() => {});
await page.waitForTimeout(6000);

const out = await page.evaluate(async () => {
  const ed = window.__officeWasmEditor;
  if (!ed) return { error: "no editor" };
  const r = { docType: ed.docType, parts: ed.parts && ed.parts.length, scale: +(ed.scale || 1).toFixed(2), visible: ed.visible ? ed.visible.size : null };

  // (1) IR parse cost (finishAgentEdit invalidates -> next find/read re-parses)
  ed._elementsCache = null;
  let s = performance.now();
  try { const els = ed.officeElements(); r.irElements = els.length; } catch (e) { r.irErr = String(e && e.message || e); }
  r.irParseMs = +(performance.now() - s).toFixed(1);
  // second call should be cached (cheap)
  s = performance.now(); try { ed.officeElements(); } catch (_) {}
  r.irCachedMs = +(performance.now() - s).toFixed(1);

  // (2) full edit re-paint cost: instrument renderPage, replay finishAgentEdit's
  // rendered.clear()+renderVisiblePages(), wait for the queue to drain.
  const paints = [];
  const orig = ed.renderPage.bind(ed);
  ed.renderPage = (i, o) => { const t0 = performance.now(); const x = orig(i, o); paints.push({ i, ms: +(performance.now() - t0).toFixed(1) }); return x; };
  const start = performance.now();
  ed.rendered.clear();
  ed.renderVisiblePages();
  await new Promise((res) => {
    const tick = () => ((ed.renderQueue && ed.renderQueue.size) || ed.renderQueueTimer) ? setTimeout(tick, 10) : res();
    setTimeout(tick, 10);
  });
  ed.renderPage = orig;
  r.repaintTotalMs = +(performance.now() - start).toFixed(1);
  r.repaintCount = paints.length;
  r.paints = paints;
  return r;
});
console.log(DOC, JSON.stringify(out, null, 1));
await browser.close();
