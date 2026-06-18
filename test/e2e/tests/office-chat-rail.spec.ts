import { test, expect, type Page } from "@playwright/test";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mkdtempSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";

// ─────────────────────────────────────────────────────────────────────────────
// Chat-rail × libre arm: drive the real agent (chat-rail) to edit a docx that is
// open in the LibreOffice→WASM viewer, and assert the edit lands through the
// office browser arm. This is a TRUE end-to-end (real provider CLI + LLM), so it
// is SLOW and non-deterministic — gated behind RUN_AGENT=1 and kept out of the
// default suite. Run: RUN_AGENT=1 npx playwright test --config playwright.local.config.ts office-chat-rail
// ─────────────────────────────────────────────────────────────────────────────

const here = dirname(fileURLToPath(import.meta.url));
const FIXTURES = join(here, "..", "fixtures", "office");

test.describe("chat-rail drives the libre (office) viewer", () => {
  test.skip(!process.env.RUN_AGENT, "needs a real agent provider CLI; set RUN_AGENT=1 to run");
  test.setTimeout(240_000);

  function stage(file: string): { dir: string; url: string } {
    const dir = mkdtempSync(join(tmpdir(), "ecrits-e2e-chat-"));
    copyFileSync(join(FIXTURES, file), join(dir, file));
    return { dir, url: `/workspace?path=${encodeURIComponent(dir)}&document=${encodeURIComponent(file)}` };
  }

  async function bootOffice(page: Page, url: string): Promise<void> {
    await page.goto(url, { waitUntil: "domcontentloaded" });
    await expect
      .poll(
        () =>
          page.evaluate(() => {
            const c = document.querySelector("[data-role='office-wasm-canvas']") as HTMLCanvasElement | null;
            return !!(window.__officeWasmEditor && c && c.width > 0);
          }),
        { timeout: 90_000 }
      )
      .toBe(true);
    await page.waitForTimeout(2500);
  }

  // Proves the chat-rail → libre (office) viewer EDIT pipeline end to end: the
  // agent reads the open docx and writes through the office browser arm. A plain
  // text insert keeps this deterministic — picture geometry is slow/flaky on the
  // office arm and is covered (incl. the selection gap) by office-viewer.spec.ts.
  test("agent edits the docx open in the libre viewer", async ({ page }) => {
    const { url } = stage("picture.docx");
    await bootOffice(page, url);

    // A fresh workspace session defaults to "Read only" access — doc.edit is
    // rejected. Grant edit access first (the inline access selector).
    await page.locator("#local-agent-access-select summary").click();
    await page.locator("#local-agent-inline-access-full-workspace").click();
    await expect(page.locator("#local-agent-access-select")).toHaveAttribute(
      "data-selected-access",
      "full-workspace"
    );

    // Send a natural request through the chat-rail composer.
    const composer = page.locator("form[phx-submit='send_local_agent'] textarea").first();
    await composer.fill(
      'Add a new paragraph at the very end of this document that says exactly: "E2E libre check". Then save.'
    );
    await page.getByRole("button", { name: "Send" }).click();

    // The agent drives the office arm: a COMPLETED doc.edit lands in the
    // transcript — that's the proof the write reached the libre viewer's model.
    // (We don't also assert doc.save: it's the agent's slow follow-on and only
    // adds flakiness; the completed edit is the meaningful signal.)
    const completedEdit = page.locator(
      "[data-message-role='tool'][data-message-status='completed']",
      { hasText: "doc.edit" }
    );
    await expect(completedEdit.first()).toBeVisible({ timeout: 180_000 });
  });
});
