import { test, expect, type Page } from "@playwright/test";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync } from "node:fs";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";

// Repro harness for "pptx selection isn't working". Drives the office WASM
// element picker on a real top-level (cross-origin-isolated) tab and probes the
// `resolveRef` WASM export DIRECTLY — the boundary where the C++ hit-test hands
// a {ok,ref,type,...} back to JS. This localizes the bug: a good shape ref ⇒
// JS-side; {ok:false}/caret/text ⇒ C++ shape_at_point.
const SOURCE =
  process.env.ECRITS_PICK_PPTX || "/Users/phihu/Downloads/CSD-Lec9-Interrupts.pptx";

const FILE = basename(SOURCE);
const WORKSPACE = mkdtempSync(join(tmpdir(), "ecrits-e2e-pptx-pick-"));

function workspaceUrl(): string {
  mkdirSync(WORKSPACE, { recursive: true });
  copyFileSync(SOURCE, join(WORKSPACE, FILE));
  return `/workspace?path=${encodeURIComponent(WORKSPACE)}&document=${encodeURIComponent(FILE)}`;
}

async function openOffice(page: Page): Promise<void> {
  await page.goto(workspaceUrl(), { waitUntil: "domcontentloaded" });
  expect(await page.evaluate(() => self.crossOriginIsolated)).toBe(true);

  await expect
    .poll(
      () =>
        page.evaluate(() => {
          const editor = (window as any).__officeWasmEditor;
          const canvas = document.querySelector("[data-role='office-wasm-canvas']") as HTMLCanvasElement | null;
          return !!(editor?.loaded && editor.parts?.length >= 1 && canvas && canvas.width > 1);
        }),
      { timeout: 240_000, message: "office WASM editor did not boot + paint" }
    )
    .toBe(true);

  await page.waitForTimeout(1500);
}

test.describe("pptx pick debug", () => {
  test.skip(!existsSync(SOURCE), `missing deck: ${SOURCE}`);

  test("probe resolveRef coverage over slide 1", async ({ page }) => {
    const logs: string[] = [];
    page.on("console", (m) => logs.push(`[${m.type()}] ${m.text()}`));
    page.on("pageerror", (e) => logs.push(`[pageerror] ${e.message}`));

    await openOffice(page);

    // 1) Sanity: does the build even expose resolveRef / hitRef?
    const apiShape = await page.evaluate(() => {
      const e = (window as any).__officeWasmEditor;
      return {
        hasResolveRef: typeof e?.api?.resolveRef === "function",
        hasHitRef: typeof e?.api?.hitRef === "function",
        hasGetElements: typeof e?.api?.getElements === "function",
        parts: e?.parts?.length || 0,
        logical: e?.pageLogicalSize ? e.pageLogicalSize(0) : null,
      };
    });
    console.log("API SHAPE:", JSON.stringify(apiShape));

    // 2) IR the model knows about (for cross-check against hit-test coverage).
    const elements = await page.evaluate(() => {
      const e = (window as any).__officeWasmEditor;
      try {
        const raw = e.api.getElements(); // embind `elements` takes 0 args
        return typeof raw === "string" ? raw.slice(0, 4000) : JSON.stringify(raw).slice(0, 4000);
      } catch (err: any) {
        return "getElements ERROR: " + (err?.message || String(err));
      }
    });
    console.log("ELEMENTS(part1):", elements);

    // 3) Probe the ACTUAL pick export this build has (resolveRef preferred, else
    //    legacy hitRef) over a grid of slide-1 logical px, and report distinct
    //    refs found. hitRef is 3-arg (no commit); resolveRef is 4-arg.
    const probe = await page.evaluate(() => {
      const e = (window as any).__officeWasmEditor;
      const { width, height } = e.pageLogicalSize(0);
      const hasResolve = typeof e.api.resolveRef === "function";
      const fn = hasResolve ? e.api.resolveRef : e.api.hitRef;
      const cols = 16;
      const rows = 12;
      const call = (x: number, y: number) => {
        try {
          const r = hasResolve ? fn(1, x, y, false) : fn(1, x, y);
          if (!r) return { nullish: true };
          return { ok: r.ok, ref: r.ref, type: r.type, hasBounds: !!(r.bounds && r.bounds.width), caret: !!r.caret, text: (r.text || "").slice(0, 30) };
        } catch (err: any) {
          return { error: err?.message || String(err) };
        }
      };
      const hits: Record<string, any> = {};
      const samples: any[] = [];
      let okCount = 0;
      let nonOk = 0;
      for (let r = 0; r < rows; r++) {
        for (let c = 0; c < cols; c++) {
          const x = Math.round(((c + 0.5) / cols) * width);
          const y = Math.round(((r + 0.5) / rows) * height);
          const res = call(x, y);
          if (res.ref) hits[res.ref] = res;
          if (res.ok && res.ref) okCount++;
          else nonOk++;
          if (res.ok || res.ref || res.error) samples.push({ x, y, ...res });
        }
      }
      return {
        usedExport: hasResolve ? "resolveRef" : "hitRef",
        logical: { width, height },
        distinctRefs: Object.values(hits),
        distinctRefCount: Object.keys(hits).length,
        okCount,
        nonOk,
        firstSamples: samples.slice(0, 24),
      };
    });
    console.log("PROBE:", JSON.stringify(probe, null, 2));

    // 4) End-to-end: enable the picker, click slide-1 title center, read picks.
    await page.click("#local-document-element-picker");
    await expect
      .poll(() => page.evaluate(() => (window as any).__officeWasmEditor?.elementPickerEnabled))
      .toBe(true);

    const titlePt = await page.evaluate(() => {
      const e = (window as any).__officeWasmEditor;
      const pageEl = document.querySelector("[data-role='office-wasm-page'][data-page-index='0']");
      const canvas = pageEl?.querySelector("[data-role='office-wasm-canvas']") as HTMLCanvasElement | null;
      const rect = canvas!.getBoundingClientRect();
      const logical = e.pageLogicalSize(0);
      // title banner is roughly 55% down on the CSD title slide
      return {
        x: rect.left + 0.5 * rect.width,
        y: rect.top + 0.55 * rect.height,
      };
    });
    await page.mouse.move(titlePt.x, titlePt.y);
    await page.waitForTimeout(120);
    await page.mouse.down();
    await page.waitForTimeout(30);
    await page.mouse.up();
    await page.waitForTimeout(400);

    const picks = await page.evaluate(
      () => (window as any).EcritsDocumentElementPicker?.picks?.map((p: any) => ({ ref: p.ref, type: p.type, text: (p.text || "").slice(0, 30) })) || []
    );
    console.log("PICKS AFTER TITLE CLICK:", JSON.stringify(picks));

    console.log("=== CONSOLE/PAGE LOGS ===\n" + logs.join("\n"));
  });
});
