defmodule ContractWeb.LegacyRedirectController do
  @moduledoc """
  Backwards-compat redirects for routes that pre-date the 2026-05-15
  Document-pivot (SPEC.md §4).

  Historically, the Studio mounted at
  `/matters/:matter_id/documents/:document_id`. After the pivot, the
  product is **document-first** — the canonical URL is
  `/documents/:document_id`. Older links (bookmarks, emails, Slack
  unfurls, agent transcripts) must continue to resolve.

  Permanent (301) so caches, link previews, and Slack/Notion unfurls
  can pin the new URL.
  """

  use ContractWeb, :controller

  @doc """
  GET /matters/:matter_id/documents/:document_id
    → 301 /documents/:document_id

  The matter_id is dropped — `MatterScope` re-derives it from the
  document on mount of the new URL.
  """
  def matter_document(conn, %{"document_id" => document_id}) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: ~p"/documents/#{document_id}")
  end
end
