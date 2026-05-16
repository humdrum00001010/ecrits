import { test, expect } from '@playwright/test';
import { signInAs, resetE2EState } from '../../fixtures/personas';
import {
  findOrSkipDocument,
  getChanges,
  getRevokeRequests,
  openStudio,
  pollUntil
} from '../../fixtures/studio';

/**
 * Scenario 3 — overlap revoke + reconciliation.
 *
 * Two edits to the same node → revoke the first → `RevokeRequest` row
 * appears → reconciliation modal renders with both diffs → "Keep latest"
 * → resolution `Change` emitted (revoke_request.status: :resolved).
 *
 * Per SPEC.md §17.
 */

test.describe('Scenario 3: overlap revoke + reconcile', () => {
  for (const viewport of ['desktop', 'mobile'] as const) {
    test(`[${viewport}] two edits → revoke first → reconcile modal → keep-latest`, async ({
      page,
      request
    }) => {
      await resetE2EState(request);
      await signInAs(page, 'lawyer');

      const document = await findOrSkipDocument(request);
      test.skip(
        document === null,
        'No documents present — overlap-revoke requires the Wave 3C1 documents migration.'
      );
      if (!document) return;

      await openStudio(page, document);

      const baseline = await getChanges(request, document.id);
      const baseCount = baseline.length;

      // Push two edits to the same node.
      //
      // Use `pushHookEvent(el, ctx, event, payload)` — NOT `view.pushEvent`.
      // `View.pushEvent(type, el, targetCtx, phxEvent, meta, opts, onReply)`
      // is a private LV API whose first arg is a `type` discriminator and
      // second is a DOM `el`; calling it with `(name, payload)` routes
      // `payload` into `extractMeta(el, ...)` which crashes on
      // `el.attributes.length`. `pushHookEvent(el, ctx, event, payload)` is
      // the proper outside-the-hook entrypoint and skips `extractMeta`.
      const pushEdit = async (value: string) => {
        await page.evaluate(
          ({ docId, v }) => {
            const lv = (window as unknown as {
              liveSocket?: {
                owner?: (el: Element) => {
                  pushHookEvent: (
                    el: Element,
                    ctx: unknown,
                    event: string,
                    payload: Record<string, unknown>
                  ) => unknown;
                };
              };
            }).liveSocket;
            const root = document.querySelector('[data-phx-main]');
            if (!root) throw new Error('Studio LV root not mounted');
            const view = lv?.owner?.(root);
            view?.pushHookEvent(root, null, 'edit_document', {
              document_id: docId,
              ops: [
                {
                  op: 'replace_content',
                  target_type: 'node',
                  target_id: 'node-effective-date',
                  args: { content: v }
                }
              ]
            });
          },
          { docId: document.id, v: value }
        );
      };

      await pushEdit('2026-01-01');
      await pollUntil(
        () => getChanges(request, document.id),
        (rows) => rows.length === baseCount + 1,
        { timeoutMs: 8_000, label: 'first edit lands' }
      );

      await pushEdit('2026-06-01');
      const after = await pollUntil(
        () => getChanges(request, document.id),
        (rows) => rows.length === baseCount + 2,
        { timeoutMs: 8_000, label: 'second edit lands' }
      );

      const firstEdit = after[baseCount];
      expect(firstEdit).toBeTruthy();

      // Revoke the first edit via pushHookEvent (see comment above on
      // pushEdit — `view.pushEvent` is the private API and crashes in
      // `extractMeta`).
      await page.evaluate(
        ({ changeId }) => {
          const lv = (window as unknown as {
            liveSocket?: {
              owner?: (el: Element) => {
                pushHookEvent: (
                  el: Element,
                  ctx: unknown,
                  event: string,
                  payload: Record<string, unknown>
                ) => unknown;
              };
            };
          }).liveSocket;
          const root = document.querySelector('[data-phx-main]');
          if (!root) throw new Error('Studio LV root not mounted');
          const view = lv?.owner?.(root);
          view?.pushHookEvent(root, null, 'revoke_change', { change_id: changeId });
        },
        { changeId: firstEdit.id }
      );

      // A RevokeRequest row must appear (overlap detected).
      const requests = await pollUntil(
        () => getRevokeRequests(request, document.id),
        (rows) => rows.length > 0,
        { timeoutMs: 8_000, label: 'revoke_request row appears' }
      );
      expect(requests[0].status).toBe('pending');

      // The reconcile modal renders in the LV.
      const modal = page.locator('[data-role="reconcile-modal"], #reconcile-modal').first();
      await expect(modal).toBeVisible({ timeout: 8_000 });

      // Click "Keep latest" — accept either the button text in Korean
      // or English so the test doesn't tie to a single locale.
      const keepLatest = modal
        .getByRole('button', { name: /keep latest|최신|최근 유지/i })
        .first();
      await keepLatest.click();

      // Wait for the resolution change.
      const resolved = await pollUntil(
        () => getRevokeRequests(request, document.id),
        (rows) => rows[0]?.status === 'resolved',
        { timeoutMs: 8_000, label: 'revoke_request becomes resolved' }
      );
      expect(resolved[0].resolution_change_id).toBeTruthy();
    });
  }
});
