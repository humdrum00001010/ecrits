import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";

const BASE = process.env.E2E_BASE_URL || "http://localhost:4000";
const DIR = process.argv[2] || "/Users/phihu/Downloads";
const PPTX = process.argv[3] || "CSD-Lec6-Timers.pptx";
const OUT = process.env.OFFICE_PROOF_OUT || "/tmp/ecrits-pptx-proof";
const PPTX_HIT_PATTERN = process.env.PPTX_HIT_PATTERN || "";

mkdirSync(OUT, { recursive: true });

const t0 = Date.now();
const log = (tag, data = "") => {
  const text = typeof data === "string" ? data : JSON.stringify(data);
  console.log(`[${String(Date.now() - t0).padStart(6)}ms] ${tag} ${text}`);
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
    const nativeNames = [
      "resolveRef",
      "postMouseEvent",
      "doubleClick",
      "setTextSelection",
      "getTextSelection",
      "getCursor",
      "getInteractionState"
    ];
    const interestingEvents = new Set(["mousedown", "mousemove", "mouseup", "dblclick"]);

    const push = (kind, data) => {
      const entry = { t: Math.round(performance.now() - t0), kind, ...data };
      trace.push(entry);
      if (trace.length > 1000) trace.shift();
      console.log("[pptx-proof]", JSON.stringify(entry).slice(0, 2000));
    };

    window.__pptxProofTrace = trace;

    const listenerMap = new WeakMap();
    const origAdd = EventTarget.prototype.addEventListener;
    const origRemove = EventTarget.prototype.removeEventListener;

    EventTarget.prototype.addEventListener = function(type, listener, options) {
      if (listener && interestingEvents.has(type)) {
        const wrapped = typeof listener === "function"
          ? function(event) {
              const target = event.target && event.target.closest &&
                event.target.closest("[data-role], [phx-hook]");
              push("dom-event", {
                type,
                button: event.button,
                buttons: event.buttons,
                detail: event.detail,
                clientX: event.clientX,
                clientY: event.clientY,
                targetRole: target && target.getAttribute("data-role"),
                targetHook: target && target.getAttribute("phx-hook")
              });
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

    const hookModule = (module) => {
      if (!module || module.__pptxProofHooked) return module;
      Object.defineProperty(module, "__pptxProofHooked", { value: true });

      for (const name of nativeNames) {
        if (typeof module[name] !== "function") continue;
        const original = module[name];
        module[name] = function(...args) {
          push("native-call", { name, args });
          try {
            const result = original.apply(this, args);
            push("native-return", { name, result });
            return result;
          } catch (error) {
            push("native-throw", { name, error: error && error.message || String(error) });
            throw error;
          }
        };
      }

      push("module-hooked", {
        keys: nativeNames.filter((name) => typeof module[name] === "function")
      });
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

async function waitOffice(page, document) {
  await page.goto(workspaceUrl(document), { waitUntil: "domcontentloaded", timeout: 60_000 });
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

async function findTextHit(page, pageIndex = 0, pattern = PPTX_HIT_PATTERN) {
  const info = await canvasInfo(page, pageIndex);
  const hit = await page.evaluate(({ pageIndex, logical, pattern }) => {
    const module = window.__officeWasmModule;
    if (!module || typeof module.resolveRef !== "function") return null;
    const wanted = String(pattern || "").trim().toLowerCase();
    let first = null;

    for (let y = Math.round(logical.height * 0.10); y <= Math.round(logical.height * 0.85); y += 24) {
      for (let x = Math.round(logical.width * 0.05); x <= Math.round(logical.width * 0.95); x += 32) {
        const res = module.resolveRef(pageIndex + 1, x, y, false);
        const text = String(res && res.text || "");
        if (res && res.ok && text.trim()) {
          const candidate = {
            x,
            y,
            ref: res.ref,
            type: res.type,
            text: res.text,
            rect: (res.rects && res.rects[0]) || res.bounds || null
          };
          if (!first) first = candidate;
          if (!wanted || text.toLowerCase().includes(wanted)) return candidate;
        }
      }
    }

    return first;
  }, { pageIndex, logical: info.logical, pattern });

  if (!hit) throw new Error("no pptx text hit found");
  return { info, hit };
}

const browser = await chromium.launch(chromiumLaunchOptions());
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
await installTrace(page);
page.on("console", (msg) => {
  const text = msg.text();
  if (text.includes("[pptx-proof]") || text.includes("[office-wasm]")) log("console", text);
});
page.on("pageerror", (error) => log("pageerror", error.message));

try {
  await waitOffice(page, PPTX);
  log("pptx-geometry", await page.evaluate(() => {
    const canvas = document.querySelector("[data-role='office-wasm-canvas']");
    const rect = canvas && canvas.getBoundingClientRect();
    const module = window.__officeWasmModule;
    return {
      dpr: window.devicePixelRatio || 1,
      canvas: canvas && {
        width: canvas.width,
        height: canvas.height,
        cssWidth: rect.width,
        cssHeight: rect.height
      },
      rawSizes: typeof module?.getPartSizesJson === "function" ? module.getPartSizesJson() : null,
      documentSize: typeof module?.getDocumentSize === "function" ? module.getDocumentSize() : null
    };
  }));
  await page.screenshot({ path: join(OUT, "pptx-before.png"), fullPage: true });

  const { info, hit } = await findTextHit(page, 0, PPTX_HIT_PATTERN);
  log("pptx-hit", hit);

  const rect = hit.rect || { x: hit.x, y: hit.y - 10, width: 300, height: 24 };
  const y = Number(rect.y || hit.y) + Math.max(4, Number(rect.height || 16) / 2);
  const startLocal = { x: Number(rect.x || hit.x) + 6, y };
  const endLocal = {
    x: Math.min(
      info.logical.width - 10,
      Number(rect.x || hit.x) + Math.max(140, Math.min(Number(rect.width || 300) - 6, 360))
    ),
    y
  };
  const start = clientFromLocal(info, startLocal);
  const end = clientFromLocal(info, endLocal);
  log("pptx-drag", { startLocal, endLocal, start, end });

  await page.mouse.move(start.x, start.y);
  await page.mouse.down();
  await page.mouse.move(end.x, end.y, { steps: 12 });
  await page.mouse.up();
  await page.waitForTimeout(1200);

  const result = await page.evaluate(() => {
    const module = window.__officeWasmModule;
    const selection = typeof module?.getTextSelection === "function"
      ? String(module.getTextSelection("text/plain;charset=utf-8") || "").replace(/\0/g, "")
      : "";
    const state = typeof module?.getInteractionState === "function"
      ? module.getInteractionState()
      : null;
    return { selection, state };
  });
  await page.screenshot({ path: join(OUT, "pptx-after-drag.png"), fullPage: true });
  log("pptx-result", { ...result, screenshots: OUT });
  log("trace-tail", await page.evaluate(() => window.__pptxProofTrace.slice(-80)));
} finally {
  await browser.close();
}
