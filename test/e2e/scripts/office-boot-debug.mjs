// Office WASM boot debugger — opens picture.docx in a REAL top-level
// cross-origin-isolated Chromium tab (Playwright honours COOP/COEP, unlike the
// Tidewave iframe) and captures the actual bootstrap execution path: every
// `[office-wasm] t+Nms:` milestone, engine stdout/stderr, /assets/office/*
// network, and the live `Module` gate state — to pinpoint where load parks.
//
// Run from test/e2e:  node scripts/office-boot-debug.mjs [docx|pptx]
import { chromium } from "@playwright/test";

// Usage:
//   node scripts/office-boot-debug.mjs docx|pptx           (built-in fixtures)
//   node scripts/office-boot-debug.mjs <abs-dir> <document> (real file)
const a2 = process.argv[2] || "docx";
const a3 = process.argv[3];
let DIR, DOC;
if (a3) {
  DIR = a2;
  DOC = a3;
} else {
  DIR = new URL("../fixtures/office", import.meta.url).pathname;
  DOC = a2.toLowerCase() === "pptx" ? "picture.pptx" : "picture.docx";
}
const BASE = process.env.E2E_BASE_URL || "http://localhost:4000";
const URLP = `${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(DOC)}`;

const t0 = Date.now();
const ts = () => String(Date.now() - t0).padStart(6) + "ms";
const line = (tag, ...a) => console.log(`[${ts()}] ${tag}`, ...a);

const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: Number(process.env.DPR) || 1 });

page.on("console", (m) => line("console:" + m.type(), m.text()));
page.on("pageerror", (e) => line("PAGEERROR", e.message));
page.on("requestfailed", (r) =>
  line("REQ-FAILED", r.url(), r.failure() && r.failure().errorText)
);
page.on("response", (r) => {
  const u = r.url();
  if (u.includes("/assets/office/") || u.includes("/local/document-bytes")) {
    line("net", r.status(), r.request().method(), u.replace(BASE, ""), "ct=" + (r.headers()["content-type"] || "?"));
  }
});

line("GOTO", URLP);
try {
  await page.goto(URLP, { waitUntil: "domcontentloaded", timeout: 60000 });
} catch (e) {
  line("GOTO-ERR", e.message);
}

const env = await page.evaluate(() => ({
  href: location.href,
  crossOriginIsolated: self.crossOriginIsolated,
  sab: typeof SharedArrayBuffer,
  secure: self.isSecureContext,
  inIframe: self !== self.top,
}));
line("ENV", JSON.stringify(env));

// Poll the live Module/editor gate state until boot, error, or ~90s.
const PROBE = () => {
  const M = window.Module || window.__officeWasmModule;
  const s = document.querySelector("[data-role='office-wasm-status']");
  let lokReady = null;
  try { if (M && typeof M.lok_is_ready === "function") lokReady = M.lok_is_ready() === true; } catch (e) { lokReady = "throw:" + e.message; }
  return {
    status: s ? s.textContent.trim() : null,
    editor: !!window.__officeWasmEditor,
    module: !!M,
    calledRun: M ? M.calledRun : undefined,
    runtimeInitialized: M ? M.runtimeInitialized : undefined,
    loadFromBytes: M ? typeof M.loadFromBytes : undefined,
    lok_is_ready: M ? typeof M.lok_is_ready : undefined,
    lokReady,
    canvas: !!document.querySelector("[data-role='office-wasm-canvas']"),
  };
};

let last = "";
let booted = false;
for (let i = 0; i < 90; i++) {
  const st = await page.evaluate(PROBE);
  const sig = JSON.stringify(st);
  if (sig !== last) { line("PROBE", sig); last = sig; }
  if (st.canvas || (st.status && /failed|error|abort/i.test(st.status))) { booted = st.canvas; break; }
  await page.waitForTimeout(1000);
}

line("DONE", booted ? "CANVAS PAINTED (booted)" : "did not boot within window");
await browser.close();
