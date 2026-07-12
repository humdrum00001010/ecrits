import { test, expect } from "@playwright/test";

// Is the workspace page actually cross-origin isolated in a real TOP-LEVEL tab?
// Distinguishes a genuine app bug from verification confounds (#317):
//   (a) browser_eval / Tidewave panel run in an IFRAME → can never isolate;
//   (b) navigating to /workspace?path=... is IGNORED (#225 — workspace state is
//       owned by the session handoff, not the URL), so a fresh session BOUNCES to
//       the mount landing (no COEP there) → crossOriginIsolated=false.
// The real flow: open the folder via the mount form, which server-REDIRECTS to
// /workspace with COOP/COEP → isolation. This drives that.
test("workspace page is cross-origin isolated via the real open flow (top-level)", async ({ page }) => {
  test.setTimeout(60_000);

  await page.goto("/", { waitUntil: "domcontentloaded" });
  await expect(page.locator("#local-path-input")).toBeVisible({ timeout: 15_000 });
  await page.fill("#local-path-input", "/Users/phihu/Downloads");
  await page.locator("#local-path-form").evaluate((f: HTMLFormElement) => f.requestSubmit());

  // The server redirect lands us on /workspace with the isolation headers.
  await page.waitForURL("**/workspace", { timeout: 20_000 });
  await page.waitForTimeout(1500);

  const ctx = await page.evaluate(() => ({
    url: location.pathname,
    isTopLevel: window === window.top,
    crossOriginIsolated: (self as any).crossOriginIsolated,
    hasSAB: typeof SharedArrayBuffer !== "undefined",
  }));
  console.log(">>> context:", JSON.stringify(ctx));

  expect(ctx.url, "landed on /workspace (not bounced to mount)").toBe("/workspace");
  expect(ctx.isTopLevel).toBe(true);
  expect(ctx.crossOriginIsolated, "workspace is cross-origin isolated").toBe(true);
  expect(ctx.hasSAB, "SharedArrayBuffer available").toBe(true);
});
