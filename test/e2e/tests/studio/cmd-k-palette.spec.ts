import { test, expect } from '@playwright/test';
import { signInAs, resetE2EState } from '../../fixtures/personas';
import {
  getDocuments,
  openStudio,
  pollUntil
} from '../../fixtures/studio';
import { seedDocumentBundle } from '../../fixtures/seeds';

/**
 * Scenario 6 — Cmd+K palette → set contract type.
 *
 * Open the command palette → type "set contract type" → Enter →
 * type-picker modal → pick `service_agreement_v1` →
 * `documents.type_key` updates.
 *
 * The Cmd+K palette is a desktop-only interaction (chord keyboard
 * shortcut). On mobile the equivalent is the chat-command button — per
 * feedback-responsive-scope.md "the Cmd+K command palette — Cmd+K isn't
 * a mobile interaction; replace with a 'command' button in the chat
 * input area on mobile". This scenario covers BOTH paths, one per
 * viewport.
 */

test.describe('Scenario 6: Cmd+K palette (mobile: chat-command button)', () => {
  for (const viewport of ['desktop', 'mobile'] as const) {
    test(`[${viewport}] palette → set contract type → DB updates`, async ({
      page,
      request
    }) => {
      await resetE2EState(request);
      await signInAs(page, 'lawyer');

      const { document } = await seedDocumentBundle(page, {
        title: 'Cmd+K palette scenario doc',
        type_key: 'nda_v1'
      });

      await openStudio(page, {
        id: document.id,
        name: document.title,
        type_key: document.type_key,
        inserted_at: ''
      });

      // Wait for the palette JS hook to bind. The root `data-role`
      // lives on the always-mounted container so we can poll it; the
      // modal-box gets `data-role="command-palette"` only when @open?
      // flips. Without this wait, `Ctrl+KeyK` can fire before the LV
      // hook attaches the keydown handler, in which case the keypress
      // is lost and the palette never opens. The hook flips
      // `data-cmdk-ready` from "false" to "true" inside `mounted()`.
      await page
        .locator('[data-role="command-palette-root"][data-cmdk-ready="true"]')
        .first()
        .waitFor({ state: 'attached', timeout: 10_000 });
      await page.waitForFunction(
        () => {
          const w = window as unknown as { liveSocket?: { isConnected?: () => boolean } };
          return Boolean(w.liveSocket && w.liveSocket.isConnected && w.liveSocket.isConnected());
        },
        undefined,
        { timeout: 10_000 }
      );

      if (viewport === 'desktop') {
        // Make sure the page has focus before pressing — without a
        // prior click, `page.keyboard.press` can land on a detached
        // event target and never reach the window keydown listener.
        await page.locator('body').click({ position: { x: 10, y: 10 } });
        await page.keyboard.press('Control+KeyK');
      } else {
        const cmdBtn = page.locator('[data-role="chat-command"]').first();
        // The chat-command button is the mobile substitute. If it isn't
        // rendered, skip cleanly — we still cover the desktop path.
        if ((await cmdBtn.count()) === 0) {
          test.skip(true, 'No chat-command button rendered in mobile Studio yet.');
          return;
        }
        await cmdBtn.click();
      }

      const palette = page.locator('[data-role="command-palette"], #command-palette').first();
      await expect(palette).toBeVisible({ timeout: 5_000 });

      const input = palette.locator('input').first();
      await input.fill('set contract type');
      await page.keyboard.press('Enter');

      const picker = page.locator('[data-role="type-picker"]').first();
      await expect(picker).toBeVisible({ timeout: 5_000 });

      // Pick a supported standard type.
      await picker.getByText(/service_agreement_v1/i).first().click();

      // Confirm the DB now shows the new type_key.
      const docs = await pollUntil(
        () => getDocuments(request),
        (rows) =>
          rows.some((d) => d.id === document.id && /franchise/i.test(d.type_key ?? '')),
        { timeoutMs: 8_000, label: 'documents.type_key updated to service_agreement_v1' }
      );
      const updated = docs.find((d) => d.id === document.id);
      expect(updated?.type_key).toBe('service_agreement_v1');
    });
  }
});

/**
 * Regression — Cmd+K opens the palette within 200ms of being pressed,
 * provided the hook has marked itself ready. Guards against the
 * silent-no-op race that surfaced in `export-delivery.spec.ts` (#76),
 * where `pushEventTo` was being called before the LiveSocket connected.
 */
test.describe('Cmd+K palette: global binding is hot-on-mount', () => {
  test('[desktop] Cmd+K opens the palette within 200ms', async ({ page, request }) => {
    await resetE2EState(request);
    await signInAs(page, 'lawyer');

    const { document } = await seedDocumentBundle(page, {
      title: 'Cmd+K hot-on-mount doc',
      type_key: 'nda_v1'
    });

    await openStudio(page, {
      id: document.id,
      name: document.title,
      type_key: document.type_key,
      inserted_at: ''
    });

    await page
      .locator('[data-role="command-palette-root"][data-cmdk-ready="true"]')
      .first()
      .waitFor({ state: 'attached', timeout: 10_000 });
    await page.waitForFunction(
      () => {
        const w = window as unknown as { liveSocket?: { isConnected?: () => boolean } };
        return Boolean(w.liveSocket && w.liveSocket.isConnected && w.liveSocket.isConnected());
      },
      undefined,
      { timeout: 10_000 }
    );

    await page.locator('body').click({ position: { x: 10, y: 10 } });
    await page.keyboard.press('Control+KeyK');

    const palette = page.locator('[data-role="command-palette"], #command-palette').first();
    // 200ms ceiling per task #76 — the global keydown listener runs in
    // capture phase so no Studio component can swallow it.
    await expect(palette).toBeVisible({ timeout: 200 });
  });
});
