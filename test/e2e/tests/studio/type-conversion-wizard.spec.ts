import { test, expect } from '@playwright/test';
import { signInAs, resetE2EState } from '../../fixtures/personas';
import {
  findOrSkipDocument,
  getDocuments,
  openStudio,
  pollUntil
} from '../../fixtures/studio';

/**
 * Scenario 4 — type-conversion wizard. **WAVE 4 PENDING.**
 *
 * Lawyer triggers `:start_type_conversion` (via Cmd+K → "Set contract
 * type" → `service_agreement_v1`) → 3-step wizard renders (Plan → FieldStrategies
 * → CreateVariant) → walk through → new variant Document created with
 * field-migration lineage rows.
 *
 * The conversion logic itself ships in Wave 4. Tagged `@wave-4-pending`
 * and skipped unless `WAVE_4_READY=1`.
 */

test.describe('Scenario 4: type-conversion wizard @wave-4-pending', () => {
  test.skip(
    process.env.WAVE_4_READY !== '1',
    'WAVE_4_READY != 1 — type-conversion wizard ships in Wave 4'
  );

  for (const viewport of ['desktop', 'mobile'] as const) {
    test(`[${viewport}] Cmd+K → set type → wizard → new variant document`, async ({
      page,
      request
    }) => {
      await resetE2EState(request);
      await signInAs(page, 'lawyer');

      const document = await findOrSkipDocument(request);
      test.skip(
        document === null,
        'No documents present — type-conversion wizard requires a source document.'
      );
      if (!document) return;

      await openStudio(page, document);

      // Open Cmd+K palette (desktop) or the chat command button (mobile).
      if (viewport === 'desktop') {
        await page.keyboard.press('Control+KeyK');
      } else {
        const cmdBtn = page.locator('[data-role="chat-command"]').first();
        await expect(cmdBtn).toBeVisible();
        await cmdBtn.click();
      }

      const palette = page.locator('[data-role="command-palette"], #command-palette').first();
      await expect(palette).toBeVisible();

      await palette.locator('input').first().fill('set contract type');
      await page.keyboard.press('Enter');

      // Type picker modal.
      const picker = page.locator('[data-role="type-picker"]').first();
      await expect(picker).toBeVisible();
      await picker.getByText(/service_agreement_v1/i).first().click();

      // Wizard steps: Plan → FieldStrategies → CreateVariant. Each step
      // has a "Next" button (or "다음" in Korean).
      for (const step of ['plan', 'field-strategies', 'create-variant']) {
        const stepEl = page.locator(`[data-step="${step}"]`).first();
        await expect(stepEl).toBeVisible();
        await page.getByRole('button', { name: /next|다음|완료|create/i }).first().click();
      }

      // A new document should appear in /test/db/documents with a
      // lineage tag pointing back to the original.
      const docs = await pollUntil(
        () => getDocuments(request),
        (rows) => rows.length > 1,
        { timeoutMs: 15_000, label: 'variant document appears' }
      );
      const variant = docs.find((d) => d.id !== document.id);
      expect(variant).toBeTruthy();
      expect(variant?.type_key).toBe('service_agreement_v1');
    });
  }
});
