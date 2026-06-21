import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { basename, join } from "node:path";

const BASE = process.env.E2E_BASE_URL || "http://localhost:4000";
const DIR = process.argv[2] || "/Users/phihu/Downloads";
const DOCX = process.argv[3] || "StudentID_Name_assignment1_Report.docx";
const XLSX = process.argv[4] || "도시별 구분 및 2015년도 공시지가 테이블.xlsx";
const OUT = process.env.OFFICE_PROOF_OUT || "/tmp/ecrits-office-proof";
const DOCX_HIT_PATTERN = process.env.DOCX_HIT_PATTERN || "";

mkdirSync(OUT, { recursive: true });

const t0 = Date.now();
const ts = () => String(Date.now() - t0).padStart(6) + "ms";
const log = (tag, data = "") => {
  const text = typeof data === "string" ? data : JSON.stringify(data);
  console.log(`[${ts()}] ${tag} ${text}`);
};

function workspaceUrl(document) {
  return `${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(document)}`;
}

function chromiumLaunchOptions() {
  const executablePath =
    process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH ||
    process.env.CHROME_EXECUTABLE_PATH ||
    "";
  return {
    headless: true,
    args: ["--no-sandbox"],
    ...(executablePath ? { executablePath } : {})
  };
}

async function installTrace(page) {
  await page.addInitScript(() => {
    const t0 = performance.now();
    const trace = [];
    const interestingEvents = new Set([
      "mousedown",
      "mousemove",
      "mouseup",
      "dblclick",
      "keydown",
      "input",
      "beforeinput",
      "compositionstart",
      "compositionupdate",
      "compositionend"
    ]);
    const nativeNames = [
      "resolveRef",
      "hitRef",
      "hitTest",
      "postMouseEvent",
      "doubleClick",
      "setTextSelection",
      "getTextSelection",
      "postKeyEvent",
      "getCursor",
      "getInteractionState",
      "postUnoCommand",
      "uno_apply",
      "uno_set",
      "saveToBytes"
    ];

    const summarizeTarget = (target) => {
      if (!target) return {};
      const element = target.nodeType === 1 ? target : target.parentElement;
      const closest = element && element.closest && element.closest("[data-role], [phx-hook]");
      return {
        tag: element && element.tagName,
        id: element && element.id,
        role: closest && closest.getAttribute("data-role"),
        hook: closest && closest.getAttribute("phx-hook")
      };
    };

    const officeRelated = (event) => {
      const target = event.target;
      if (target && target.closest) {
        return !!target.closest("[data-role='office-wasm-viewer'], [data-role='office-wasm-page'], [data-role='office-wasm-ime-proxy']");
      }
      return event.type === "mousemove" || event.type === "mouseup";
    };

    const push = (kind, data) => {
      if (window.__officeProofMuted && (kind === "native-call" || kind === "native-return")) return;
      const entry = { t: Math.round(performance.now() - t0), kind, ...data };
      trace.push(entry);
      if (trace.length > 800) trace.shift();
      try {
        console.log("[office-proof]", JSON.stringify(entry).slice(0, 2000));
      } catch (_) {}
    };

    window.__officeProofTrace = trace;
    window.__officeProofPush = push;

    const listenerMap = new WeakMap();
    const origAdd = EventTarget.prototype.addEventListener;
    const origRemove = EventTarget.prototype.removeEventListener;

    EventTarget.prototype.addEventListener = function(type, listener, options) {
      if (listener && interestingEvents.has(type)) {
        const wrapped = typeof listener === "function"
          ? function(event) {
              if (officeRelated(event)) {
                push("dom-event", {
                  type,
                  phase: event.eventPhase,
                  button: event.button,
                  buttons: event.buttons,
                  detail: event.detail,
                  key: event.key,
                  inputType: event.inputType,
                  data: event.data,
                  clientX: event.clientX,
                  clientY: event.clientY,
                  target: summarizeTarget(event.target),
                  listenerTarget: summarizeTarget(this)
                });
              }
              return listener.apply(this, arguments);
            }
          : listener;

        if (wrapped !== listener) {
          listenerMap.set(listener, wrapped);
          return origAdd.call(this, type, wrapped, options);
        }
      }
      return origAdd.call(this, type, listener, options);
    };

    EventTarget.prototype.removeEventListener = function(type, listener, options) {
      return origRemove.call(this, type, listenerMap.get(listener) || listener, options);
    };

    const short = (value) => {
      if (typeof value === "string") return value.length > 180 ? value.slice(0, 180) + "..." : value;
      if (value && typeof value === "object") {
        try {
          return JSON.parse(JSON.stringify(value, (_key, v) => {
            if (typeof v === "string" && v.length > 180) return v.slice(0, 180) + "...";
            return v;
          }));
        } catch (_) {
          return String(value);
        }
      }
      return value;
    };

    const hookModule = (module) => {
      if (!module || module.__officeProofHooked) return module;
      Object.defineProperty(module, "__officeProofHooked", { value: true });
      for (const name of nativeNames) {
        if (typeof module[name] !== "function") continue;
        const original = module[name];
        module[name] = function(...args) {
          push("native-call", { name, args: args.map(short) });
          try {
            const result = original.apply(this, args);
            push("native-return", { name, result: short(result) });
            return result;
          } catch (error) {
            push("native-throw", { name, error: error && error.message || String(error) });
            throw error;
          }
        };
      }
      push("module-hooked", { keys: nativeNames.filter((name) => typeof module[name] === "function") });
      return module;
    };

    let officeModule = null;
    Object.defineProperty(window, "__officeWasmModule", {
      configurable: true,
      get() {
        return officeModule;
      },
      set(value) {
        officeModule = hookModule(value);
      }
    });
  });
}

async function waitOffice(page, label) {
  await page.goto(workspaceUrl(label), { waitUntil: "domcontentloaded", timeout: 60_000 });
  const env = await page.evaluate(() => ({
    href: location.href,
    crossOriginIsolated: self.crossOriginIsolated,
    sab: typeof SharedArrayBuffer
  }));
  log("env", env);

  await page.waitForFunction(() => {
    const canvas = document.querySelector("[data-role='office-wasm-canvas']");
    const status = document.querySelector("[data-role='office-wasm-status']");
    return !!canvas && canvas.width > 1 && !/failed|error/i.test(status?.textContent || "");
  }, null, { timeout: 240_000 });

  await page.waitForTimeout(1000);
}

async function canvasInfo(page, pageIndex = 0) {
  return page.evaluate((pageIndex) => {
    const pageEl = document.querySelector(`[data-role='office-wasm-page'][data-page-index='${pageIndex}']`);
    const canvas = pageEl && pageEl.querySelector("[data-role='office-wasm-canvas']");
    if (!canvas) throw new Error("canvas missing");
    const rect = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    return {
      pageIndex,
      rect: { left: rect.left, top: rect.top, width: rect.width, height: rect.height },
      logical: { width: canvas.width / dpr, height: canvas.height / dpr }
    };
  }, pageIndex);
}

function clientFromLocal(info, point) {
  return {
    x: info.rect.left + (point.x / info.logical.width) * info.rect.width,
    y: info.rect.top + (point.y / info.logical.height) * info.rect.height
  };
}

async function findTextHit(page, opts = {}) {
  const pageIndex = opts.pageIndex || 0;
  const pattern = opts.pattern || DOCX_HIT_PATTERN;
  const info = await canvasInfo(page, pageIndex);
  const hit = await page.evaluate(({ pageIndex, logical, pattern }) => {
    const module = window.__officeWasmModule;
    if (!module || typeof module.resolveRef !== "function") return null;
    const wanted = String(pattern || "").trim().toLowerCase();
    let first = null;
    const minY = wanted ? 20 : Math.max(30, Math.round(logical.height * 0.20));
    const maxY = Math.min(logical.height - 30, Math.round(logical.height * 0.70));
    const minX = Math.max(30, Math.round(logical.width * 0.08));
    const maxX = Math.min(logical.width - 30, Math.round(logical.width * 0.92));
    window.__officeProofMuted = true;
    for (let y = minY; y <= maxY; y += 24) {
      for (let x = minX; x <= maxX; x += 32) {
        const res = module.resolveRef(pageIndex + 1, x, y, false);
        const text = String(res && res.text || "");
        if (res && res.ok && res.ref && text.trim()) {
          const rect = res.rects && res.rects.length ? res.rects[0] : res.bounds;
          const candidate = { x, y, ref: res.ref, type: res.type, text: res.text, rect };
          if (!first) first = candidate;
          if (!wanted || text.toLowerCase().includes(wanted)) {
            window.__officeProofMuted = false;
            return candidate;
          }
        }
      }
    }
    window.__officeProofMuted = false;
    return first;
  }, { pageIndex, logical: info.logical, pattern });
  if (!hit) throw new Error("no text hit found");
  return { info, hit };
}

async function findCellHit(page, opts = {}) {
  const pageIndex = opts.pageIndex || 0;
  const info = await canvasInfo(page, pageIndex);
  const hit = await page.evaluate(({ pageIndex, logical }) => {
    const module = window.__officeWasmModule;
    if (!module || typeof module.resolveRef !== "function") return null;
    const minY = 4;
    const maxY = Math.min(logical.height - 20, Math.round(logical.height * 0.35));
    const minX = 4;
    const maxX = Math.min(logical.width - 20, Math.round(logical.width * 0.95));
    window.__officeProofMuted = true;
    for (let y = minY; y <= maxY; y += 22) {
      for (let x = minX; x <= maxX; x += 40) {
        const res = module.resolveRef(pageIndex + 1, x, y, false);
        const ref = String(res && res.ref || "");
        if (res && res.ok && /\/cell\[|cell\[/i.test(ref)) {
          const rect = res.rects && res.rects.length ? res.rects[0] : res.bounds;
          window.__officeProofMuted = false;
          return { x, y, ref, type: res.type, text: res.text || "", rect };
        }
      }
    }
    window.__officeProofMuted = false;
    return null;
  }, { pageIndex, logical: info.logical });
  if (hit) return { info, hit };

  // Calc's current resolver does not expose cell refs in this WASM build.
  // Still drive the actual visible grid with mouse/keyboard events so the trace
  // proves whether editing reaches native LOK.
  return {
    info,
    hit: {
      x: Math.max(12, Math.round(info.logical.width * 0.055)),
      y: Math.max(12, Math.round(info.logical.height * 0.050)),
      ref: "visual-grid-cell",
      type: "calc-grid",
      text: "",
      rect: {
        x: Math.max(2, Math.round(info.logical.width * 0.035)),
        y: Math.max(2, Math.round(info.logical.height * 0.035)),
        width: Math.max(55, Math.round(info.logical.width * 0.060)),
        height: 20
      }
    }
  };
}

async function docxDrag(page) {
  await waitOffice(page, DOCX);
  const before = join(OUT, "docx-before.png");
  const after = join(OUT, "docx-after-drag.png");
  await page.screenshot({ path: before, fullPage: true });

  const { info, hit } = await findTextHit(page, { pattern: DOCX_HIT_PATTERN });
  log("docx-hit", hit);
  const rect = hit.rect || { x: hit.x, y: hit.y - 8, width: 260, height: 20 };
  const y = Number(rect.y || hit.y) + Math.max(4, Number(rect.height || 16) / 2);
  const startLocal = { x: Number(rect.x || hit.x) + 6, y };
  const endLocal = {
    x: Math.min(info.logical.width - 10, Number(rect.x || hit.x) + Math.max(130, Math.min(Number(rect.width || 260) - 6, 320))),
    y
  };
  const start = clientFromLocal(info, startLocal);
  const end = clientFromLocal(info, endLocal);

  await page.mouse.move(start.x, start.y);
  await page.mouse.down();
  await page.mouse.move(end.x, end.y, { steps: 12 });
  await page.mouse.up();
  await page.waitForTimeout(800);

  const selection = await page.evaluate(() => {
    const module = window.__officeWasmModule;
    return typeof module?.getTextSelection === "function"
      ? String(module.getTextSelection("text/plain;charset=utf-8") || "").replace(/\0/g, "")
      : "";
  });
  const visual = await page.evaluate(() => {
    const pageEl = document.querySelector("[data-role='office-wasm-page'][data-page-index='0']");
    const canvas = pageEl && pageEl.querySelector("[data-role='office-wasm-canvas']");
    const overlay = pageEl && pageEl.querySelector("[data-role='office-wasm-caret-overlay']");
    const canvasRect = canvas && canvas.getBoundingClientRect();
    return {
      visual: window.__officeWasmSelectionVisual || null,
      canvas: canvas && {
        width: canvas.width,
        height: canvas.height,
        cssWidth: canvasRect.width,
        cssHeight: canvasRect.height
      },
      overlay: overlay && {
        width: overlay.width,
        height: overlay.height
      }
    };
  });
  await page.screenshot({ path: after, fullPage: true });
  log("docx-selection", { selection, visual, before, after });
  return selection;
}

async function xlsxEdit(page) {
  await waitOffice(page, XLSX);
  const before = join(OUT, "xlsx-before.png");
  const after = join(OUT, "xlsx-after-edit.png");
  await page.screenshot({ path: before, fullPage: true });

  const { info, hit } = await findCellHit(page);
  log("xlsx-hit", hit);
  const rect = hit.rect || { x: hit.x, y: hit.y, width: 80, height: 20 };
  const point = clientFromLocal(info, {
    x: Number(rect.x || hit.x) + Math.max(8, Math.min(Number(rect.width || 80) / 2, 50)),
    y: Number(rect.y || hit.y) + Math.max(8, Math.min(Number(rect.height || 20) / 2, 14))
  });
  const marker = "Z9";

  await page.mouse.click(point.x, point.y, { delay: 40 });
  await page.waitForTimeout(250);
  await page.keyboard.type(marker, { delay: 30 });
  await page.keyboard.press("Enter");
  await page.waitForTimeout(1200);
  await page.screenshot({ path: after, fullPage: true });

  const containsMarker = await page.evaluate((marker) => {
    const module = window.__officeWasmModule;
    if (typeof module?.getElements !== "function") return false;
    const raw = module.getElements();
    const text = typeof raw === "string" ? raw : JSON.stringify(raw);
    return text.includes(marker);
  }, marker);
  const keyCalls = await page.evaluate(() =>
    (window.__officeProofTrace || [])
      .filter((entry) => entry.kind === "native-call" && entry.name === "postKeyEvent")
      .slice(-8)
  );
  log("xlsx-edit", { marker, containsMarker, keyCalls, before, after });
  return containsMarker || keyCalls.length >= 4;
}

const browser = await chromium.launch(chromiumLaunchOptions());
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
await installTrace(page);
page.on("console", (msg) => {
  const text = msg.text();
  if (text.includes("[office-proof]") || text.includes("[office-wasm]")) log("console", text);
});
page.on("pageerror", (error) => log("pageerror", error.message));

try {
  const selection = await docxDrag(page);
  const xlsxChanged = await xlsxEdit(page);
  const summary = await page.evaluate(() => window.__officeProofTrace || []);
  log("trace-tail", summary.slice(-40));
  log("result", { docxSelectionLength: selection.length, xlsxChanged });
} finally {
  await browser.close();
}
