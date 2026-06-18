import { test, expect, type Page } from "@playwright/test";

// One-off verification (ecrits #57) in a REAL cross-origin Chromium (fresh, no
// browser cache → fetches the freshly-deployed soffice.data). Captures all the
// symptom surfaces: autofit body overflow (A/C, view), the click/select re-render
// (A), and the cache-contents table ghosting (D).
//   Run: npx playwright test office-tahoma-verify --config playwright.local.config.ts

const WORKSPACE = "/tmp";
const FILE = "calec6.pptx";

function workspaceUrl(file: string): string {
  return `/workspace?path=${encodeURIComponent(WORKSPACE)}&document=${encodeURIComponent(file)}`;
}

async function boot(page: Page): Promise<void> {
  await page.goto(workspaceUrl(FILE), { waitUntil: "domcontentloaded" });
  expect(await page.evaluate(() => (self as any).crossOriginIsolated)).toBe(true);
  await expect
    .poll(
      () =>
        page.evaluate(() => {
          const c = document.querySelector("[data-role='office-wasm-canvas']") as HTMLCanvasElement | null;
          return !!((window as any).__officeWasmEditor && c && c.width > 1);
        }),
      { timeout: 240_000, message: "office WASM editor did not boot + paint" }
    )
    .toBe(true);
  await page.waitForTimeout(3000);
}

async function gotoSlide(page: Page, index0: number): Promise<void> {
  await page.evaluate((idx) => {
    document
      .querySelector(`[data-role='office-wasm-page'][data-page-index='${idx}']`)
      ?.scrollIntoView({ block: "center" });
  }, index0);
  await expect
    .poll(
      () =>
        page.evaluate((idx) => {
          const s = document.querySelector(`[data-role='office-wasm-page'][data-page-index='${idx}']`);
          const c = s?.querySelector("[data-role='office-wasm-canvas']") as HTMLCanvasElement | null;
          return !!(c && c.width > 10);
        }, index0),
      { timeout: 60_000, message: `slide ${index0 + 1} canvas did not render` }
    )
    .toBe(true);
  await page.waitForTimeout(2500);
}

function shot(page: Page, index0: number, name: string) {
  return page.locator(`[data-role='office-wasm-page'][data-page-index='${index0}']`).screenshot({ path: `/tmp/${name}.png` });
}

test("autofit body slides 5 + 33 render fitted (A/C view)", async ({ page }) => {
  await boot(page);
  console.log("DIAG", JSON.stringify(await page.evaluate(() => {
    const ed = (window as any).__officeWasmEditor;
    return { parts: ed?.parts?.length, assetVersion: ed?.officeAssetVersion };
  })));
  await gotoSlide(page, 4);
  await shot(page, 4, "e2e_slide5");
  await gotoSlide(page, 32);
  await shot(page, 32, "e2e_slide33");
});

test("cache-contents table slides render without ghosting (D)", async ({ page }) => {
  await boot(page);
  await gotoSlide(page, 11);
  await shot(page, 11, "e2e_slide12_cache");
  await gotoSlide(page, 13);
  await shot(page, 13, "e2e_slide14_cache");
});

test("slide 33 click-to-select does not jump/overflow (A on-select)", async ({ page }) => {
  await boot(page);
  await gotoSlide(page, 32);
  const box = await page.locator(`[data-role='office-wasm-page'][data-page-index='32'] [data-role='office-wasm-canvas']`).boundingBox();
  if (box) {
    // click into the body text region (left ~30%, upper-middle)
    await page.mouse.click(box.x + box.width * 0.28, box.y + box.height * 0.32);
    await page.waitForTimeout(2500);
  }
  await shot(page, 32, "e2e_slide33_selected");
});

test("DIAG #50: pptx element picker resolution on CA-Lec6", async ({ page }) => {
  await boot(page);
  await gotoSlide(page, 3); // slide 4 ("Impacts of Misses on Performance (2)")
  const result = await page.evaluate(() => {
    const ed = (window as any).__officeWasmEditor;
    const api = ed.api || {};
    const M = (window as any).Module || {};
    const modKeys = Object.keys(M).filter(k => /resolve|hit/i.test(k));
    const out: any = {
      hasResolveRef: typeof api.resolveRef === "function",
      hasHitRef: typeof api.hitRef === "function",
      hasOfficePickAtPoint: typeof ed.officePickAtPoint === "function",
      module_resolveRef: typeof M.resolveRef,
      module__resolveRef: typeof M._resolveRef,
      module_hitRef: typeof M.hitRef,
      modKeys,
      apiShape: ed.api && ed.api.shape,
      elementPickerEnabled: ed.elementPickerEnabled,
      picks: [] as any[],
    };
    const part = ed.parts[3] || ed.parts[0] || {};
    const W = Number(part.width), H = Number(part.height);
    const seen = new Map<string, any>();
    for (let iy = 1; iy < 12; iy++) {
      for (let ix = 1; ix < 12; ix++) {
        let p: any = null;
        try { p = ed.officePickAtPoint({ pageIndex: 3, x: (W * ix) / 12, y: (H * iy) / 12 }); } catch (_) {}
        if (p) { const k = p.type + "|" + p.ref; if (!seen.has(k)) seen.set(k, { type: p.type, ref: p.ref }); }
      }
    }
    // raw hitRef probe (diagnose shape_at_point)
    try {
      const center = ed.api.hitRef ? ed.api.hitRef(4, W * 0.5, H * 0.45) : "no-hitRef";
      out.rawCenter = center;
      out.partWH = [W, H];
    } catch (e) { out.rawErr = String(e && e.message || e); }
    out.picks = [...seen.values()].slice(0, 14);
    out.pickCount = seen.size;
    return out;
  });
  console.log("DIAG50", JSON.stringify(result));
});
