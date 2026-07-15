import { test, expect, type Page } from "@playwright/test";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mkdtempSync, copyFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";

// ─────────────────────────────────────────────────────────────────────────────
// IR VALIDATION via the real chat-rail: does a NATURAL "recolor this shape"
// request actually land on a pptx through the office arm? Real-user proof for the
// #276 reflection-codec finding (verified 2026-07-08: FillColor 1614595→dark navy,
// CharColor→white persisted to the real file).
//
// The agent edits via the doc VFS (a file WRITE to .ecrits/<doc>.jsonl), NOT
// a doc.edit MCP tool — so the correct assertion is the MOUNTED FILE BYTES, not a
// doc.edit card. We DON'T boot the office WASM viewer (it needs a cross-origin-
// isolated context; see task #317) — the chat-rail agent path is independent of it.
//
// Opens the workspace via the real mount-page flow (openWorkspace) — a URL nav to
// /workspace?path=... is ignored (#225) and bounces to the mount landing.
// TRUE e2e (real codex CLI + LLM) — slow + non-deterministic. Gated by RUN_AGENT.
//   RUN_AGENT=1 npx playwright test --config playwright.local.config.ts office-chat-rail-ir-pptx
// ─────────────────────────────────────────────────────────────────────────────

const here = dirname(fileURLToPath(import.meta.url));
const FIXTURES = join(here, "..", "fixtures", "office");
// picture.pptx: shape[title] ("Logo demo") baseline FillColor = 1614595 (0x18A9C3-ish).
const TITLE_BASELINE_FILL = 1614595;

function luminance(rgb: number): number {
  const r = (rgb >> 16) & 0xff, g = (rgb >> 8) & 0xff, b = rgb & 0xff;
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

// Find shape[title]'s FillColor in the mounted JSONL projection (nested value:
// sections -> paragraphs -> payload nodes; props is the reflected UNO bag).
function titleFillFromMount(mountFile: string): number | null {
  const raw = readFileSync(mountFile, "utf8");
  const firstLine = raw.split("\n").find((l) => l.trim().startsWith("["));
  if (!firstLine) return null;
  const value = JSON.parse(firstLine);
  const nodes: any[] = [];
  for (const section of value)
    for (const para of section) for (const node of para) if (node && typeof node === "object") nodes.push(node);
  const title = nodes.find((n) => typeof n.ref === "string" && /shape\[title\]/.test(n.ref));
  const fill = title?.props?.FillColor;
  return typeof fill === "number" ? fill : null;
}

test.describe("chat-rail IR: recolor a pptx shape (per-shape property edit)", () => {
  test.skip(!process.env.RUN_AGENT, "needs a real agent provider CLI; set RUN_AGENT=1 to run");
  test.setTimeout(360_000);

  function stage(file: string): { dir: string; doc: string } {
    const dir = mkdtempSync(join(tmpdir(), "ecrits-e2e-ir-"));
    copyFileSync(join(FIXTURES, file), join(dir, file));
    return { dir, doc: file };
  }

  // Open the workspace via the REAL mount-page flow. Navigating to
  // /workspace?path=... is ignored (#225 — workspace state lives in the session
  // handoff, not the URL), so a URL nav bounces to the mount landing. Filling the
  // mount form server-redirects to /workspace WITH the COOP/COEP headers.
  async function openWorkspace(page: Page, dir: string): Promise<void> {
    await page.goto("/", { waitUntil: "domcontentloaded" });
    await expect(page.locator("#local-path-input")).toBeVisible({ timeout: 15_000 });
    await page.fill("#local-path-input", dir);
    await page.locator("#local-path-form").evaluate((f: HTMLFormElement) => f.requestSubmit());
    await page.waitForURL("**/workspace", { timeout: 20_000 });
  }

  async function dumpTranscript(page: Page, label: string): Promise<void> {
    const rows = await page.evaluate(() => {
      const out: Array<{ role: string; status: string; text: string }> = [];
      document.querySelectorAll("[data-message-role]").forEach((el) =>
        out.push({
          role: el.getAttribute("data-message-role") || "",
          status: el.getAttribute("data-message-status") || "",
          text: (el.textContent || "").replace(/\s+/g, " ").trim().slice(0, 300),
        })
      );
      return out;
    });
    console.log(`\n──── TRANSCRIPT (${label}) — ${rows.length} messages ────`);
    for (const r of rows) console.log(`[${r.role}${r.status ? "/" + r.status : ""}] ${r.text}`);
    console.log("──── END ────\n");
  }

  test("agent recolors the title shape on slide 1 (verified via mount bytes)", async ({ page }, testInfo) => {
    const { dir, doc } = stage("picture.pptx");
    const mountFile = join(dir, ".ecrits", `${doc}.jsonl`);

    await openWorkspace(page, dir);
    // Wait for the CHAT RAIL (not the viewer) — the agent path needs no WASM boot.
    const composer = page.locator("form[phx-submit='send_local_agent'] textarea").first();
    await expect(composer).toBeVisible({ timeout: 30_000 });

    // Grant edit access (fresh workspace defaults to read-only).
    await page.locator("#local-agent-access-select summary").click();
    await page.locator("#local-agent-inline-access-full-workspace").click();
    await expect(page.locator("#local-agent-access-select")).toHaveAttribute(
      "data-selected-access",
      "full-workspace"
    );

    // NATURAL request — no tool hints, no property names, no ref. The agent must
    // pick the doc, find the title box, and choose the colors itself.
    await composer.fill(
      `In this presentation (${doc}), on the first slide, give the title text box a dark navy background fill and make its text white. Save when you're done.`
    );
    await page.getByRole("button", { name: "Send" }).click();

    // Poll the actual outcome: the mounted title FillColor turns dark (navy). The
    // VFS edit is a file write, so this is the real signal — no doc.edit card.
    let finalFill: number | null = null;
    await expect
      .poll(
        () => {
          if (!existsSync(mountFile)) return null;
          try {
            finalFill = titleFillFromMount(mountFile);
          } catch {
            return null;
          }
          return finalFill;
        },
        { timeout: 300_000, intervals: [4000] }
      )
      .toEqual(expect.any(Number));

    await dumpTranscript(page, "after turn");
    console.log(`>>> title FillColor: baseline=${TITLE_BASELINE_FILL} final=${finalFill} lum=${finalFill != null ? luminance(finalFill).toFixed(1) : "?"}`);

    expect(finalFill, "title fill changed from baseline").not.toBe(TITLE_BASELINE_FILL);
    expect(luminance(finalFill!), "title fill is dark (navy)").toBeLessThan(90);
  });
});
