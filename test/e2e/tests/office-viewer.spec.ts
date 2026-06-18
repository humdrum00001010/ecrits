import { test, expect, type Page } from "@playwright/test";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mkdtempSync, copyFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";

// ─────────────────────────────────────────────────────────────────────────────
// LibreOffice→WASM (the "libre" arm) viewer e2e: docx + pptx open in the office
// viewer and an inserted picture is reachable by the element PICKER — the office
// twin of the HWP picture-selection coverage. The fixtures (a docx with an
// inline picture, a pptx with a GraphicObjectShape) are authored headlessly by
// the office NIF and committed under fixtures/office/.
//
// Run: npx playwright test --config playwright.local.config.ts
// Needs the local dev server up (localhost:4000) so office WASM is
// cross-origin-isolated (CrossOriginIsolationPlug).
// ─────────────────────────────────────────────────────────────────────────────

const here = dirname(fileURLToPath(import.meta.url));
const FIXTURES = join(here, "..", "fixtures", "office");

// Stage the committed fixtures into a throwaway workspace dir the viewer opens
// by path — keeps the run self-contained and off the user's real folders.
function stageWorkspace(): string {
  const dir = mkdtempSync(join(tmpdir(), "ecrits-e2e-office-"));
  mkdirSync(dir, { recursive: true });
  for (const f of ["picture.docx", "picture.pptx"]) {
    copyFileSync(join(FIXTURES, f), join(dir, f));
  }
  return dir;
}

const WORKSPACE = stageWorkspace();

function workspaceUrl(file: string): string {
  return `/workspace?path=${encodeURIComponent(WORKSPACE)}&document=${encodeURIComponent(file)}`;
}

// Open `file` in the office viewer and wait for the LibreOffice→WASM editor to
// boot (instance present + a page canvas painted), then let the LOK model settle.
async function openOffice(page: Page, file: string): Promise<void> {
  await page.goto(workspaceUrl(file), { waitUntil: "domcontentloaded" });

  expect(
    await page.evaluate(() => self.crossOriginIsolated),
    "office WASM needs cross-origin isolation (COOP/COEP)"
  ).toBe(true);

  await expect
    .poll(
      () =>
        page.evaluate(() => {
          const c = document.querySelector("[data-role='office-wasm-canvas']") as HTMLCanvasElement | null;
          return !!(window.__officeWasmEditor && c && c.width > 0);
        }),
      { timeout: 240_000, message: "office WASM editor did not boot + paint a page" }
    )
    .toBe(true);

  await page.waitForTimeout(2500); // LOK model settle
}

// Scan the page in logical coordinates with the editor's own pick path
// (officePickAtPoint) and return the distinct {type, ref} elements it resolves.
async function scanPicks(page: Page): Promise<Array<{ type: string; ref: string; rects: number }>> {
  return page.evaluate(() => {
    const ed = window.__officeWasmEditor as any;
    const part = ed.parts[0] || {};
    const W = Number(part.width), H = Number(part.height);
    const seen = new Map<string, { type: string; ref: string; rects: number }>();
    const STEP = 20;
    for (let iy = 1; iy < STEP; iy++) {
      for (let ix = 1; ix < STEP; ix++) {
        let pick: any = null;
        try {
          pick = ed.officePickAtPoint({ pageIndex: 0, x: (W * ix) / STEP, y: (H * iy) / STEP });
        } catch (_) {}
        if (!pick) continue;
        const key = `${pick.type}|${pick.ref}`;
        if (!seen.has(key)) seen.set(key, { type: pick.type, ref: pick.ref, rects: (pick.rects || []).length });
      }
    }
    return [...seen.values()];
  });
}

const isPicture = (p: { type: string; ref: string }) =>
  /graphic|image|picture|frame/i.test(p.type || "") || /Graphic|Image|Picture|shape\[logo\]/i.test(p.ref || "");

test.describe("office (libre) viewer — docx", () => {
  test("renders a docx with a picture and resolves its elements", async ({ page }) => {
    await openOffice(page, "picture.docx");
    const picks = await scanPicks(page);
    // Model loaded + reachable: the body paragraph is resolvable.
    expect(picks.length, `picker found: ${JSON.stringify(picks)}`).toBeGreaterThan(0);
    expect(picks.some((p) => /paragraph/i.test(p.type))).toBe(true);
  });

  // FIXED (#50): the office picker's resolveRef now runs a deterministic bbox
  // hit-test (LokEditBindings shape_at_point) — the office twin of the HWP
  // hwpControlAtHit→getPageControlLayout fix — so the inline picture resolves as
  // its own selectable element instead of falling through to the paragraph.
  test("inline picture is selectable via the element picker", async ({ page }) => {
    await openOffice(page, "picture.docx");
    const picks = await scanPicks(page);
    expect(picks.some(isPicture), `picker found: ${JSON.stringify(picks)}`).toBe(true);
  });
});

test.describe("office (libre) viewer — pptx", () => {
  test("renders a pptx with an added picture + title", async ({ page }) => {
    await openOffice(page, "picture.pptx");
    const picks = await scanPicks(page);
    expect(picks.length, `picker found: ${JSON.stringify(picks)}`).toBeGreaterThan(0);
    expect(picks.some((p) => /shape|placeholder/i.test(p.type) || /shape\[/.test(p.ref))).toBe(true);
  });

  // FIXED (#50): resolveRef's bbox hit-test (shape_at_point) iterates the slide's
  // XShapes and resolves the inserted GraphicObjectShape ("logo")/TextShape — not
  // just the native placeholders — so the added picture is now pickable.
  test("added picture shape is selectable via the element picker", async ({ page }) => {
    await openOffice(page, "picture.pptx");
    const picks = await scanPicks(page);
    expect(picks.some(isPicture), `picker found: ${JSON.stringify(picks)}`).toBe(true);
  });
});
