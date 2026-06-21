import { test, expect, type Page } from "@playwright/test";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync } from "node:fs";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";

const TABLE_SOURCE =
  process.env.ECRITS_TABLE_PPTX ||
  "/Users/phihu/Downloads/CA-Lec6-RISCV-Cache-1 (1).pptx";

const TABLE_FILE = basename(TABLE_SOURCE);
const WORKSPACE = mkdtempSync(join(tmpdir(), "ecrits-e2e-office-table-"));

function stageWorkspace(): void {
  mkdirSync(WORKSPACE, { recursive: true });
  copyFileSync(TABLE_SOURCE, join(WORKSPACE, TABLE_FILE));
}

function workspaceUrl(): string {
  return `/workspace?path=${encodeURIComponent(WORKSPACE)}&document=${encodeURIComponent(TABLE_FILE)}`;
}

async function openOffice(page: Page): Promise<void> {
  stageWorkspace();
  await page.goto(workspaceUrl(), { waitUntil: "domcontentloaded" });
  expect(await page.evaluate(() => self.crossOriginIsolated)).toBe(true);

  await expect
    .poll(
      () =>
        page.evaluate(() => {
          const canvas = document.querySelector("[data-role='office-wasm-canvas']") as HTMLCanvasElement | null;
          const editor = (window as any).__officeWasmEditor;
          return !!(editor?.loaded && editor.parts?.length >= 3 && canvas && canvas.width > 1);
        }),
      { timeout: 240_000, message: "office WASM editor did not boot + paint" }
    )
    .toBe(true);

  await page.waitForTimeout(1000);
}

async function clientPoint(page: Page, loc: { pageIndex: number; x: number; y: number }) {
  await page
    .locator(`[data-role='office-wasm-page'][data-page-index='${loc.pageIndex}'] [data-role='office-wasm-canvas']`)
    .scrollIntoViewIfNeeded();

  return page.evaluate((loc) => {
    const editor = (window as any).__officeWasmEditor;
    const pageEl = document.querySelector(`[data-role='office-wasm-page'][data-page-index='${loc.pageIndex}']`);
    const canvas = pageEl?.querySelector("[data-role='office-wasm-canvas']") as HTMLCanvasElement | null;
    if (!editor || !canvas) throw new Error("office editor/canvas missing");

    const rect = canvas.getBoundingClientRect();
    const logical = editor.pageLogicalSize(loc.pageIndex, canvas);
    return {
      x: rect.left + (loc.x / logical.width) * rect.width,
      y: rect.top + (loc.y / logical.height) * rect.height,
    };
  }, loc);
}

async function interactionState(page: Page) {
  return page.evaluate(
    () =>
      new Promise<any>((resolve) => {
        requestAnimationFrame(() => {
          const editor = (window as any).__officeWasmEditor;
          resolve({
            loaded: !!editor?.loaded,
            picker: !!editor?.elementPickerEnabled,
            state: editor?.readNativeInteractionState?.() || null,
            picks: (window as any).EcritsDocumentElementPicker?.picks?.map((p: any) => p.ref) || [],
          });
        });
      })
  );
}

test.describe("office table picker regression", () => {
  test.skip(!existsSync(TABLE_SOURCE), `missing local table deck: ${TABLE_SOURCE}`);

  test("picker table clicks stay read-only; normal table clicks still select", async ({ page }) => {
    await openOffice(page);

    const tablePoints = [
      { pageIndex: 2, x: 575, y: 432 },
      { pageIndex: 2, x: 746, y: 433 },
      { pageIndex: 2, x: 610, y: 500 },
      { pageIndex: 2, x: 840, y: 510 },
    ];
    const points = [];
    for (const point of tablePoints) points.push(await clientPoint(page, point));

    await page.click("#local-document-element-picker");
    await expect.poll(() => page.evaluate(() => (window as any).__officeWasmEditor?.elementPickerEnabled)).toBe(true);

    for (let i = 0; i < 21; i++) {
      const point = points[i % points.length];
      await page.mouse.move(point.x, point.y);
      await page.waitForTimeout(i % 2 ? 15 : 95);
      await page.mouse.down();
      await page.waitForTimeout(20);
      await page.mouse.up();
      await page.waitForTimeout(180);
    }

    await page.waitForTimeout(1000);
    const pickerState = await interactionState(page);
    expect(pickerState.loaded).toBe(true);
    expect(pickerState.state?.textEditActive).toBe(false);
    expect(pickerState.state?.tableSelection?.rectangle).toBeFalsy();
    expect(pickerState.picks).toContain("page[Memory Wall]/shape[Table 9]");

    await page.click("#local-document-element-picker");
    await expect.poll(() => page.evaluate(() => (window as any).__officeWasmEditor?.elementPickerEnabled)).toBe(false);

    await page.mouse.click(points[0].x, points[0].y, { delay: 20 });
    await page.waitForTimeout(1000);

    const nativeState = await interactionState(page);
    expect(nativeState.loaded).toBe(true);
    expect(nativeState.state?.tableSelection?.rectangle).toBeTruthy();
  });

  test("table edge double-click does not hang the page", async ({ page }) => {
    const pageErrors: string[] = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));

    await openOffice(page);

    const edge = await clientPoint(page, { pageIndex: 2, x: 555.68, y: 426.08667 });
    for (let i = 0; i < 8; i++) {
      await page.mouse.dblclick(edge.x, edge.y, { delay: i % 2 ? 18 : 55 });
      await page.waitForTimeout(120);
      const state = await interactionState(page);
      expect(state.loaded).toBe(true);
    }

    expect(pageErrors).toEqual([]);
  });
});
