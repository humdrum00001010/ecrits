import { defineConfig, devices } from "@playwright/test";

// LOCAL config — drives the desktop dev server (localhost:4000), NOT the public
// sprite URL the default harness targets. Used for the office/libre WASM viewer
// + chat-rail e2e, which only exist in the local workspace. The office WASM
// editor needs cross-origin isolation (COOP/COEP) — the dev server's
// CrossOriginIsolationPlug supplies it, and headless Chromium honours
// SharedArrayBuffer there, so the LibreOffice→WASM viewer boots under Playwright.
export default defineConfig({
  testDir: "./tests",
  testMatch: /office.*\.spec\.ts/,
  // Office WASM boot + LOK model settle is slow; give each test room.
  timeout: 150_000,
  expect: { timeout: 20_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [["list"]],
  use: {
    baseURL: process.env.E2E_BASE_URL || "http://localhost:4000",
    viewport: { width: 1440, height: 900 },
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    launchOptions: { args: ["--no-sandbox"] },
  },
  projects: [{ name: "chromium-desktop", use: { ...devices["Desktop Chrome"] } }],
});
