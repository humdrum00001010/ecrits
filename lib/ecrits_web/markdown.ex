defmodule EcritsWeb.Markdown do
  @moduledoc """
  Shared GFM markdown -> sanitized HTML renderer (MDEx / comrak).

  This is the single MDEx entry point reused by both the chat rail
  (`ChatRail.markdown_body`) and the local markdown document editor
  (`LocalMarkdownEditor`). Raw HTML in the source is escaped by default, so
  agent/user/document content can't inject markup. On any parse error we fall
  back to the plain text rather than crash the render.
  """

  @extension [strikethrough: true, table: true, autolink: true, tasklist: true]

  @doc """
  Render markdown `body` to a `Phoenix.HTML.safe` value of sanitized HTML.

  Returns an empty string for non-binary/empty input.
  """
  @spec to_safe_html(term()) :: Phoenix.HTML.safe() | String.t()
  def to_safe_html(body) when is_binary(body) and body != "" do
    Phoenix.HTML.raw(MDEx.to_html!(body, extension: @extension))
  rescue
    _ -> body
  end

  def to_safe_html(_body), do: ""
end
