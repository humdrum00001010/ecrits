defmodule EcritsWeb.Markdown do
  @moduledoc """
  Shared markdown -> HTML renderers.

  Two entry points with different trust envelopes:

    * `to_safe_html/1` — plain GFM via MDEx, raw HTML escaped. Used by the
      chat rail (`ChatRail.markdown_body`) for agent/user message bodies.

    * `to_preview_html/1` — Observex composite render (GFM + `$...$` /
      `$$...$$` math + fenced `tikz` blocks) for the markdown document
      preview (`MarkdownEditor`). Source raw HTML is still escaped by
      Observex; only its generated `<tex-island>` markup is live, and the
      `ObservexPreview` hook renders those islands client-side (MathJax /
      TikZJax from /observex/ assets).

  On any parse error both fall back to the plain text rather than crash the
  render.
  """

  @extension [strikethrough: true, table: true, autolink: true, tasklist: true]
  @html_tag_token ~r/(<[^>]+>)/
  @chat_prose_boundary ~r/([가-힣][.!?。！？])(?=[가-힣A-Za-z0-9])/u

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

  @doc """
  Render markdown `body` for the document preview, with math/TikZ islands.

  Returns an empty string for non-binary/empty input.
  """
  @spec to_preview_html(term()) :: Phoenix.HTML.safe() | String.t()
  def to_preview_html(body) when is_binary(body) and body != "" do
    Phoenix.HTML.raw(Observex.render_body(body))
  rescue
    _ -> body
  end

  def to_preview_html(_body), do: ""

  @doc """
  Repair prose-only sentence boundaries in chat Markdown HTML.

  Agent adapters sometimes stream adjacent deltas as `한다.` + `다음` and the
  accumulated Markdown body keeps that as `한다.다음`. This helper fixes that
  display artifact in normal text nodes while leaving inline and fenced code
  untouched.
  """
  @spec repair_chat_prose_boundaries(String.t()) :: String.t()
  def repair_chat_prose_boundaries(html) when is_binary(html) and html != "" do
    {parts, _depth} =
      Regex.split(@html_tag_token, html, include_captures: true, trim: false)
      |> Enum.map_reduce(0, fn token, depth ->
        cond do
          html_tag?(token) ->
            {token, update_chat_code_depth(depth, token)}

          depth > 0 ->
            {token, depth}

          true ->
            {repair_chat_prose_text(token), depth}
        end
      end)

    IO.iodata_to_binary(parts)
  end

  def repair_chat_prose_boundaries(html), do: html

  defp repair_chat_prose_text(text) do
    Regex.replace(@chat_prose_boundary, text, "\\1 ")
  end

  defp html_tag?(token), do: String.starts_with?(token, "<") and String.ends_with?(token, ">")

  defp update_chat_code_depth(depth, tag) do
    cond do
      Regex.match?(~r/^<\/(?:code|pre)\s*>$/i, tag) ->
        max(depth - 1, 0)

      Regex.match?(~r/^<(?:code|pre)(?:\s|>)/i, tag) and
          not Regex.match?(~r/\/\s*>$/i, tag) ->
        depth + 1

      true ->
        depth
    end
  end
end
