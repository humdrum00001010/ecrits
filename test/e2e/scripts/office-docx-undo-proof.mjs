import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";

const BASE = process.env.E2E_BASE_URL || "http://localhost:4000";
const DIR = process.env.OFFICE_PROOF_DIR || "/Users/phihu/Downloads";
const DOC = process.env.OFFICE_PROOF_DOC || "StudentID_Name_assignment1_Report.docx";
const OUT = process.env.OFFICE_PROOF_OUT || "/tmp/ecrits-office-undo-proof";
const MODE = process.env.OFFICE_PROOF_MODE || "insert";
const TEXT = process.env.OFFICE_PROOF_TEXT || "김";

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
    const trace = [];
    const push = (kind, data) => {
      const entry = { t: Math.round(performance.now()), kind, ...data };
      trace.push(entry);
      if (trace.length > 500) trace.shift();
      try {
        console.log("[office-undo-proof]", JSON.stringify(entry).slice(0, 1400));
      } catch (_) {}
    };

    window.__officeUndoProofTrace = trace;

    for (const type of ["mousedown", "mouseup", "click", "keydown", "keyup", "beforeinput", "input"]) {
      document.addEventListener(type, (event) => {
        const target = event.target && event.target.closest && event.target.closest("[data-role], [phx-hook]");
        push("dom-event", {
          type,
          key: event.key,
          code: event.code,
          ctrlKey: event.ctrlKey,
          metaKey: event.metaKey,
          shiftKey: event.shiftKey,
          inputType: event.inputType,
          data: event.data,
          defaultPrevented: event.defaultPrevented,
          targetRole: target && target.getAttribute("data-role"),
          targetHook: target && target.getAttribute("phx-hook")
        });
      }, true);
    }

    const nativeNames = ["postKeyEvent", "postUnoCommand", "getCursor", "getTextSelection"];
    const wrapModule = (module) => {
      if (!module || module.__undoProofWrapped) return module;
      Object.defineProperty(module, "__undoProofWrapped", { value: true });
      for (const name of nativeNames) {
        if (typeof module[name] !== "function") continue;
        const original = module[name];
        module[name] = function(...args) {
          push("native-call", { name, args });
          const result = original.apply(this, args);
          push("native-return", {
            name,
            result: typeof result === "string" && result.length > 240 ? result.slice(0, 240) + "..." : result
          });
          return result;
        };
      }
      push("module-hooked", { names: nativeNames.filter((name) => typeof module[name] === "function") });
      return module;
    };

    let officeModule = null;
    Object.defineProperty(window, "__officeWasmModule", {
      configurable: true,
      get() { return officeModule; },
      set(value) { officeModule = wrapModule(value); }
    });
  });
}

async function waitOffice(page) {
  await page.goto(workspaceUrl(DOC), { waitUntil: "domcontentloaded", timeout: 60_000 });
  await page.waitForFunction(() => {
    const canvas = document.querySelector("[data-role='office-wasm-canvas']");
    const status = document.querySelector("[data-role='office-wasm-status']");
    return !!canvas && canvas.width > 1 && !/failed|error/i.test(status?.textContent || "");
  }, null, { timeout: 240_000 });
  await page.waitForTimeout(1000);
}

async function locateTarget(page) {
  return page.evaluate(() => {
    const module = window.__officeWasmModule;
    const pageEl = document.querySelector("[data-role='office-wasm-page'][data-page-index='0']");
    const canvas = pageEl && pageEl.querySelector("[data-role='office-wasm-canvas']");
    if (!module || !canvas) return null;

    const rect = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const logical = { width: canvas.width / dpr, height: canvas.height / dpr };

    for (let y = 40; y < logical.height * 0.55; y += 14) {
      for (let x = logical.width * 0.20; x < logical.width * 0.80; x += 18) {
        const res = module.resolveRef(1, Math.round(x), Math.round(y), false);
        const text = String(res && res.text || "");
        if (res && res.ok && text.includes("COSE461")) {
          const bounds = (res.rects && res.rects[0]) || res.bounds || { x, y, width: 220, height: 24 };
          return {
            text,
            ref: res.ref,
            bounds,
            canvasRect: { left: rect.left, top: rect.top, width: rect.width, height: rect.height },
            logical
          };
        }
      }
    }

    return null;
  });
}

function clientFromLocal(target, point) {
  return {
    x: target.canvasRect.left + (point.x / target.logical.width) * target.canvasRect.width,
    y: target.canvasRect.top + (point.y / target.logical.height) * target.canvasRect.height
  };
}

async function readAt(page, point) {
  return page.evaluate((local) => {
    const res = window.__officeWasmModule.resolveRef(1, Math.round(local.x), Math.round(local.y), false);
    return String(res && res.text || "");
  }, point);
}

const browser = await chromium.launch(chromiumLaunchOptions());
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
await installTrace(page);
page.on("console", (msg) => {
  const text = msg.text();
  if (text.includes("[office-undo-proof]") || text.includes("[office-wasm]")) log("console", text);
});
page.on("pageerror", (error) => log("pageerror", error.message));

try {
  await waitOffice(page);
  const target = await locateTarget(page);
  if (!target) throw new Error("could not locate COSE461 text");
  log("target", target);

  const bounds = target.bounds;
  const clickLocal = {
    x: Number(bounds.x) + Math.max(8, Math.min(Number(bounds.width || 240) - 4, Number(bounds.width || 240) * 0.92)),
    y: Number(bounds.y) + Math.max(8, Number(bounds.height || 20) / 2)
  };
  const click = clientFromLocal(target, clickLocal);

  await page.screenshot({ path: join(OUT, "before.png"), fullPage: true });
  await page.mouse.click(click.x, click.y, { delay: 50 });
  await page.waitForTimeout(250);
  let afterDelete = null;
  let afterEdit;
  if (MODE === "delete") {
    await page.keyboard.press("Backspace");
    await page.waitForTimeout(700);
    afterEdit = await readAt(page, clickLocal);
    await page.screenshot({ path: join(OUT, "after-delete.png"), fullPage: true });
  } else if (MODE === "hangul") {
    await page.keyboard.press("Backspace");
    await page.waitForTimeout(700);
    afterDelete = await readAt(page, clickLocal);
    await page.screenshot({ path: join(OUT, "after-delete.png"), fullPage: true });
    await page.keyboard.insertText(TEXT);
    await page.waitForTimeout(1000);
    afterEdit = await readAt(page, clickLocal);
    await page.screenshot({ path: join(OUT, "after-hangul.png"), fullPage: true });
  } else {
    await page.keyboard.type("q", { delay: 30 });
    await page.waitForTimeout(700);
    afterEdit = await readAt(page, clickLocal);
    await page.screenshot({ path: join(OUT, "after-type.png"), fullPage: true });
  }

  await page.keyboard.press("Control+Z");
  await page.waitForTimeout(1200);
  const afterUndo = await readAt(page, clickLocal);
  await page.screenshot({ path: join(OUT, "after-undo.png"), fullPage: true });

  const traceTail = await page.evaluate(() => (window.__officeUndoProofTrace || []).slice(-80));
  const relevantTrace = traceTail.filter((entry) =>
    entry.kind === "dom-event" ||
      (entry.kind === "native-call" && ["postKeyEvent", "postUnoCommand"].includes(entry.name))
  );
  log("trace-tail", relevantTrace);
  log("result", { mode: MODE, before: target.text, afterDelete, afterEdit, afterUndo, screenshots: OUT });

  if (MODE === "delete") {
    if (afterEdit === target.text) {
      throw new Error("deletion did not change target text");
    }
    if (afterUndo !== target.text) {
      throw new Error("single undo did not restore deleted text");
    }
  } else {
    if (MODE === "hangul") {
      if (!afterEdit.includes(TEXT) || /[\u3130-\u318F]/u.test(afterEdit)) {
        throw new Error("Hangul insertion did not commit the final syllable");
      }
      if (afterDelete && afterUndo !== afterDelete) {
        throw new Error("undo after Hangul insertion did not return to the deleted-text state");
      }
    } else if (afterEdit === target.text || !afterEdit.includes("q")) {
      throw new Error("typing did not change target text");
    } else if (afterUndo.includes("q")) {
      throw new Error("undo did not remove typed text");
    }
  }
} finally {
  await browser.close();
}
