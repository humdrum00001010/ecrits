// Profile the LOK worker pthread's wasm execution during a paintTile/getElements.
// Playwright launches chromium (with a CDP port) + drives the page; a raw CDP
// client attaches the Profiler to the soffice.js worker targets (Playwright's
// own API can't). With the wasm built --profiling-funcs, frames are NAMED C++.
//   node wasm-worker-cdp.mjs <dir> <document>
import { chromium } from "@playwright/test";
import { setTimeout as sleep } from "node:timers/promises";

const DIR = process.argv[2], DOC = process.argv[3];
const URL = `http://localhost:4000/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`;
const PORT = 9337;

const browser = await chromium.launch({ headless: true, args: ["--no-sandbox", `--remote-debugging-port=${PORT}`] });
const page = await browser.newPage({ viewport: { width: 1400, height: 1000 }, deviceScaleFactor: 2 });
await page.goto(URL, { waitUntil: "domcontentloaded", timeout: 60000 });
await page.waitForSelector("[data-role='office-wasm-canvas']", { timeout: 60000 });
await page.waitForFunction(() => ((document.querySelector("[data-role='office-wasm-canvas']") || {}).width || 0) > 1, null, { timeout: 60000 });
await page.waitForTimeout(1500);

let wsUrl;
for (let i = 0; i < 40; i++) { try { const j = await (await fetch(`http://localhost:${PORT}/json/version`)).json(); wsUrl = j.webSocketDebuggerUrl; if (wsUrl) break; } catch (_) {} await sleep(150); }
const ws = new WebSocket(wsUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let id = 1; const pending = new Map();
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { const { resolve, reject } = pending.get(m.id); pending.delete(m.id); m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result); } };
const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => { const i = id++; pending.set(i, { resolve, reject }); ws.send(JSON.stringify(sessionId ? { id: i, method, params, sessionId } : { id: i, method, params })); });

const { targetInfos } = await send("Target.getTargets");
const wt = targetInfos.filter(t => t.type === "worker" && /soffice\.js/.test(t.url || ""));
console.log("worker targets:", wt.length, "| coi:", await page.evaluate(() => self.crossOriginIsolated));
const sessions = [];
for (const t of wt) { const { sessionId } = await send("Target.attachToTarget", { targetId: t.targetId, flatten: true }); sessions.push(sessionId); await send("Profiler.enable", {}, sessionId); await send("Profiler.setSamplingInterval", { interval: 80 }, sessionId); await send("Profiler.start", {}, sessionId); }

await page.evaluate(() => { const ed = window.__officeWasmEditor; ed.rendered.clear(); ed.renderPage(0, { force: true }); ed._elementsCache = null; ed.officeElements(); });

for (const s of sessions) {
  let profile;
  try { ({ profile } = await send("Profiler.stop", {}, s)); } catch (_) { continue; }
  const m = new Map(); let tot = 0;
  for (const n of profile.nodes) { const h = n.hitCount || 0; if (!h) continue; const f = n.callFrame || {}; const k = (f.functionName || "(anon)").slice(0, 100); m.set(k, (m.get(k) || 0) + h); tot += h; }
  if (tot > 20) { console.log(`\n[worker ${s.slice(0, 8)}] ~${(tot * 0.08).toFixed(0)}ms in samples`); console.log([...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, 18).map(([k, h]) => `  ${(h * 0.08).toFixed(1)}ms  ${k}`).join("\n")); }
}
ws.close(); await browser.close();
