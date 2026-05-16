import { chromium } from "@playwright/test";

const PORT = 8080;
const EMAIL = "lawyer-screenshot@example.com";
const PASSWORD = "hello world!";

const sizes = {
  desktop: { width: 1440, height: 900 },
  mobile:  { width: 375,  height: 667 },
};

const variant = process.argv[2] || "before";

async function shot(name, size) {
  const browser = await chromium.launch({ args: ["--no-sandbox"] });
  const ctx = await browser.newContext({ viewport: size });
  const page = await ctx.newPage();
  await page.goto(`http://localhost:${PORT}/users/log-in`);
  await page.fill("#login_form_password_email", EMAIL);
  await page.fill("#login_form_password_password", PASSWORD);
  // submit password form
  await Promise.all([
    page.waitForURL(/dashboard|users\/log-in/, { timeout: 5000 }).catch(() => {}),
    page.click("#login_form_password button[type=submit]"),
  ]);
  await page.waitForLoadState("networkidle");
  // Navigate to dashboard explicitly
  await page.goto(`http://localhost:${PORT}/dashboard`);
  await page.waitForLoadState("networkidle");
  await page.screenshot({ path: `/tmp/navbar-screens/${name}-${variant}.png` });
  await browser.close();
}

for (const [name, size] of Object.entries(sizes)) {
  console.log("shooting", name, variant);
  await shot(name, size);
}
console.log("done");
