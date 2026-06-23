import { chromium } from "@playwright/test";

const BASE = process.env.E2E_BASE_URL || "http://localhost:4000";
const DIR = process.argv[2] || "/Users/phihu/Downloads";
const DOCS = process.argv.slice(3);
if (DOCS.length === 0) DOCS.push("기관별 연령별 인구통계(2026년 5월말 기준).xlsx");

const t0 = Date.now();
const ts = () => String(Date.now() - t0).padStart(6) + "ms";
const log = (tag, data = "") => {
  const text = typeof data === "string" ? data : JSON.stringify(data);
  console.log(`[${ts()}] ${tag} ${text}`);
};

function workspaceUrl(document) {
  return `${BASE}/workspace?path=${encodeURIComponent(DIR)}&document=${encodeURIComponent(document)}`;
}

function officeLike(document) {
  return /\.(doc|docx|xls|xlsx|ppt|pptx|rtf)$/i.test(document);
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

const browser = await chromium.launch(chromiumLaunchOptions());
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

page.on("console", (msg) => {
  const text = msg.text();
  if (text.includes("[office-wasm]")) log("console", text.slice(0, 1600));
});
page.on("pageerror", (error) => log("pageerror", error.message));
page.on("requestfailed", (request) => log("requestfailed", {
  url: request.url(),
  error: request.failure() && request.failure().errorText
}));

async function waitForRender() {
  await page.waitForFunction(() => {
    const status = document.querySelector("[data-role='office-wasm-status']")?.textContent || "";
    const canvas = document.querySelector("[data-role='office-wasm-canvas']");
    if (/Render failed|Office WASM failed|failed to load|error|abort/i.test(status)) return true;
    return !!window.__officeWasmEditor && !!window.__officeWasmModule && !!canvas && canvas.width > 1 && canvas.height > 1;
  }, null, { timeout: 240_000 });
  await page.waitForTimeout(2500);
}

async function waitForNonOfficeDocument() {
  await page.waitForFunction(() => !document.querySelector("[data-role='office-wasm-viewer']"), null, {
    timeout: 60_000
  });
  await page.waitForTimeout(1000);
}

async function renderState() {
  return page.evaluate(() => {
    const status = document.querySelector("[data-role='office-wasm-status']")?.textContent.trim() || "";
    const editor = window.__officeWasmEditor;
    const canvas = document.querySelector("[data-role='office-wasm-canvas']");
    const summary = {
      status,
      hasEditor: !!editor,
      hasModule: !!window.__officeWasmModule,
      docType: editor && editor.docType,
      parts: editor && editor.parts,
      rendered: editor && Array.from(editor.rendered || []),
      paintEmptyRetries: editor && Array.from(editor.paintEmptyRetries || []),
      canvas: canvas && { width: canvas.width, height: canvas.height },
      pixels: null,
      probes: []
    };

    if (canvas) {
      const ctx = canvas.getContext("2d");
      const w = Math.min(canvas.width, 240);
      const h = Math.min(canvas.height, 160);
      const data = ctx.getImageData(0, 0, w, h).data;
      let nonWhite = 0;
      let nonTransparent = 0;
      for (let i = 0; i < data.length; i += 4) {
        const r = data[i];
        const g = data[i + 1];
        const b = data[i + 2];
        const a = data[i + 3];
        if (a) nonTransparent++;
        if (a && (r < 245 || g < 245 || b < 245)) nonWhite++;
      }
      summary.pixels = { sampleWidth: w, sampleHeight: h, nonWhite, nonTransparent };
    }

    if (editor && editor.parts && editor.parts.length && typeof editor.callPaintTile === "function") {
      const part = editor.parts[0] || { width: 794, height: 1123 };
      const pxW = Math.max(1, Math.round(Number(part.width || 794) * (editor.scale || 1)));
      const pxH = Math.max(1, Math.round(Number(part.height || 1123) * (editor.scale || 1)));
      const tileW = Math.round(Number(part.width || 794) * 1440 / 96);
      const tileH = Math.round(Number(part.height || 1123) * 1440 / 96);
      for (const setPartFirst of [false, true]) {
        for (const partArg of [0, 1]) {
          try {
            if (setPartFirst && typeof editor.api?.setPart === "function") editor.api.setPart(0);
            const rgba = editor.callPaintTile(partArg, 0, 0, tileW, tileH, pxW, pxH);
            summary.probes.push({
              setPartFirst,
              partArg,
              length: rgba && rgba.length || 0,
              expected: pxW * pxH * 4
            });
          } catch (error) {
            summary.probes.push({ setPartFirst, partArg, error: String(error && error.message || error) });
          }
        }
      }
    }

    return summary;
  });
}

function assertRendered(result, label) {
  if (/Render failed|Office WASM failed|failed to load|error|abort/i.test(result.status)) {
    throw new Error(`${label}: Office render status failed: ${result.status}`);
  }
  if (!result.canvas || !result.pixels || result.pixels.nonTransparent === 0) {
    throw new Error(`${label}: Office render produced no visible canvas pixels`);
  }
}

await page.goto(workspaceUrl(DOCS[0]), { waitUntil: "domcontentloaded", timeout: 60_000 });

const env = await page.evaluate(() => ({
  href: location.href,
  crossOriginIsolated: self.crossOriginIsolated,
  sab: typeof SharedArrayBuffer,
  secure: self.isSecureContext,
}));
log("env", env);

for (let i = 0; i < DOCS.length; i++) {
  const doc = DOCS[i];
  if (i > 0) {
    const row = page.getByRole("treeitem", { name: doc });
    await row.click();
  }
  if (officeLike(doc)) {
    await waitForRender();
    const result = await renderState();
    log("result", { document: doc, ...result });
    assertRendered(result, doc);
  } else {
    await waitForNonOfficeDocument();
    const state = await page.evaluate(() => ({
      href: location.href,
      hasOffice: !!document.querySelector("[data-role='office-wasm-viewer']"),
      officeStatus: document.querySelector("[data-role='office-wasm-status']")?.textContent.trim() || "",
      bodyText: document.body.textContent.slice(0, 400)
    }));
    log("non-office-result", { document: doc, ...state });
    if (/Render failed|Office WASM failed|failed to load|error|abort/i.test(state.officeStatus)) {
      throw new Error(`${doc}: stale Office status survived after non-Office switch: ${state.officeStatus}`);
    }
  }
}

await browser.close();
