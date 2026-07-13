defmodule Ecrits.AcpAgent.Prompt do
  @moduledoc """
  The multi-modal input seam for a chat turn (Phase 5).

  A turn's `input` is generalized from a bare string to a list of **content
  blocks** — `%{type: :text | :image | :audio | :file | :doc_ref, …}` — with a
  plain string accepted as SUGAR (`"x"` ⇄ `[%{type: :text, text: "x"}]`). This
  module is the single place that:

    * `normalize/1` — coerces any accepted input into a canonical shape. A bare
      **string stays a bare string** (the byte-for-byte-unchanged legacy path);
      a list of blocks is validated + canonicalized. This is the ONLY function
      whose output the rest of the turn pipeline branches on, so the legacy
      string path is provably untouched.
    * `display_text/1` — the human-visible text of an input (for the chat
      transcript bubble + the auto-title derivation), regardless of modality.
    * `to_acp_content/2` — maps a normalized input + the doc preamble onto the
      ACP `prompt` content shape (`String.t() | [content_block_map]`). A string
      input maps to `preamble <> string` (UNCHANGED). A block list maps to a
      leading preamble **text block** followed by one ACP block per input block
      (`text` / `image` / `audio` / `resource_link`), so a future image / doc-ref
      send works end-to-end without the UI needing to know the ACP wire shape.

  ## Content block shapes (the public input contract)

      %{type: :text,  text: "..."}
      %{type: :image, mime_type: "image/png", data: <base64>}     # or :uri
      %{type: :audio, mime_type: "audio/wav", data: <base64>}
      %{type: :file,  uri: "file:///...", name: "...", mime_type: "..."}
      %{type: :doc_ref, document_id: "d_...", ref: "sec/para/0"}   # ref optional

  A `:doc_ref` becomes an `ecrits://doc/<id>#<ref>` **resource_link** the agent
  resolves through its OWN `doc.*` MCP tools (never a global pool), keeping doc
  editing on the structured MCP path (not ACP-native fs).
  """

  alias ExMCP.ACP.Types

  @type block ::
          %{type: :text, text: String.t()}
          | %{type: :image, mime_type: String.t(), data: String.t()}
          | %{type: :audio, mime_type: String.t(), data: String.t()}
          | %{type: :file, uri: String.t()}
          | %{type: :doc_ref, document_id: String.t()}

  @type input :: String.t() | [block()]

  @doc """
  Canonicalize a turn input. A bare string is returned UNCHANGED (the legacy
  path); a list of blocks is validated and each block normalized to atom-keyed
  maps with a known `:type`. Returns `{:ok, input}` or `{:error, reason}`.

  An empty list, or a list with an unrecognized block, is rejected so a malformed
  multi-modal send fails fast at the boundary rather than silently dropping
  content mid-turn.
  """
  @spec normalize(term()) :: {:ok, input()} | {:error, term()}
  def normalize(input) when is_binary(input), do: {:ok, input}

  def normalize([]), do: {:error, :empty_input}

  def normalize(blocks) when is_list(blocks) do
    Enum.reduce_while(blocks, {:ok, []}, fn block, {:ok, acc} ->
      case normalize_block(block) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = err -> err
    end
  end

  def normalize(_other), do: {:error, :invalid_input}

  # A single block may also be passed (sugar for a one-element list).
  defp normalize_block(%{type: type} = block) when is_atom(type) do
    do_normalize_block(type, block)
  end

  defp normalize_block(%{"type" => type} = block) when is_binary(type) do
    case safe_type(type) do
      nil -> {:error, {:unknown_block_type, type}}
      atom -> do_normalize_block(atom, atomize_keys(block))
    end
  end

  defp normalize_block(other), do: {:error, {:invalid_block, other}}

  defp do_normalize_block(:text, block) do
    case Map.get(block, :text) do
      text when is_binary(text) -> {:ok, %{type: :text, text: text}}
      _ -> {:error, {:invalid_block, :text}}
    end
  end

  defp do_normalize_block(:image, block), do: normalize_media(:image, block)
  defp do_normalize_block(:audio, block), do: normalize_media(:audio, block)

  defp do_normalize_block(:file, block) do
    case Map.get(block, :uri) do
      uri when is_binary(uri) and uri != "" ->
        {:ok,
         %{type: :file, uri: uri}
         |> put_opt(:name, Map.get(block, :name))
         |> put_opt(:mime_type, Map.get(block, :mime_type))}

      _ ->
        {:error, {:invalid_block, :file}}
    end
  end

  defp do_normalize_block(:doc_ref, block) do
    case Map.get(block, :document_id) do
      id when is_binary(id) and id != "" ->
        {:ok,
         %{type: :doc_ref, document_id: id}
         |> put_opt(:ref, Map.get(block, :ref))}

      _ ->
        {:error, {:invalid_block, :doc_ref}}
    end
  end

  defp do_normalize_block(type, _block), do: {:error, {:unknown_block_type, type}}

  # image/audio accept inline base64 `:data` (with `:mime_type`) OR a `:uri`.
  defp normalize_media(type, block) do
    mime = Map.get(block, :mime_type)
    data = Map.get(block, :data)
    uri = Map.get(block, :uri)

    cond do
      is_binary(mime) and is_binary(data) and data != "" ->
        {:ok, %{type: type, mime_type: mime, data: data} |> put_opt(:uri, uri)}

      is_binary(uri) and uri != "" ->
        {:ok, %{type: type, uri: uri} |> put_opt(:mime_type, mime)}

      true ->
        {:error, {:invalid_block, type}}
    end
  end

  @doc """
  Human-visible text of an input for the transcript bubble + title derivation.
  A string is itself; a block list joins its `:text` blocks (the modality blocks
  contribute nothing visible here — the transcript shows the typed text).
  """
  @spec display_text(input()) :: String.t()
  def display_text(input) when is_binary(input), do: input

  def display_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) and Map.get(&1, :type) == :text))
    |> Enum.map_join("\n", &(Map.get(&1, :text) || ""))
  end

  def display_text(_input), do: ""

  @doc """
  Map a normalized input + the doc preamble onto the ACP `prompt` content.

    * **string input** → `preamble <> string` (a plain string — the LEGACY shape,
      byte-for-byte identical to before this seam existed). `ExMCP.ACP.Client`
      auto-wraps a string as a single text block, exactly as today.
    * **block-list input** → a list whose FIRST element is the preamble as an ACP
      text block, followed by one ACP block per input block.

  `preamble` is the system/doc guidance string already prepended to every turn.
  """
  @spec to_acp_content(input(), String.t()) :: String.t() | [map()]
  def to_acp_content(input, preamble) when is_binary(input) and is_binary(preamble) do
    preamble <> input
  end

  def to_acp_content(blocks, preamble) when is_list(blocks) and is_binary(preamble) do
    [Types.text_block(preamble) | Enum.map(blocks, &block_to_acp/1)]
  end

  defp block_to_acp(%{type: :text, text: text}), do: Types.text_block(text)

  defp block_to_acp(%{type: :image} = b) do
    media_to_acp(&Types.image_block/3, b)
  end

  defp block_to_acp(%{type: :audio} = b) do
    media_to_acp(&Types.audio_block/3, b)
  end

  defp block_to_acp(%{type: :file} = b) do
    opts =
      []
      |> kw_opt(:name, Map.get(b, :name))
      |> kw_opt(:mimeType, Map.get(b, :mime_type))

    Types.resource_link_block(Map.fetch!(b, :uri), opts)
  end

  # A doc_ref is the agent's hint to resolve a workspace document through its OWN
  # doc.* tools: `ecrits://doc/<document_id>#<ref>`. The agent dereferences this
  # (via doc.context/doc.read/etc), so editing stays on the structured MCP path.
  defp block_to_acp(%{type: :doc_ref, document_id: id} = b) do
    uri =
      case Map.get(b, :ref) do
        ref when is_binary(ref) and ref != "" -> "ecrits://doc/#{id}##{ref}"
        _ -> "ecrits://doc/#{id}"
      end

    Types.resource_link_block(uri, name: id, mimeType: "application/x-ecrits-doc")
  end

  # An inline-data media block maps to image_block/audio_block(mime, data); a
  # uri-only media block degrades to a resource_link (the agent fetches it).
  defp media_to_acp(builder, %{mime_type: mime, data: data} = b)
       when is_binary(mime) and is_binary(data) do
    opts = kw_opt([], :uri, Map.get(b, :uri))
    builder.(mime, data, opts)
  end

  defp media_to_acp(_builder, %{uri: uri} = b) do
    Types.resource_link_block(uri, kw_opt([], :mimeType, Map.get(b, :mime_type)))
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, _key, ""), do: map
  defp put_opt(map, key, value), do: Map.put(map, key, value)

  defp kw_opt(opts, _key, nil), do: opts
  defp kw_opt(opts, _key, ""), do: opts
  defp kw_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp safe_type(type) when is_binary(type) do
    case type do
      "text" -> :text
      "image" -> :image
      "audio" -> :audio
      "file" -> :file
      "doc_ref" -> :doc_ref
      _ -> nil
    end
  end

  defp atomize_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {safe_key(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp safe_key("type"), do: :type
  defp safe_key("text"), do: :text
  defp safe_key("data"), do: :data
  defp safe_key("uri"), do: :uri
  defp safe_key("name"), do: :name
  defp safe_key("ref"), do: :ref
  defp safe_key("mime_type"), do: :mime_type
  defp safe_key("mimeType"), do: :mime_type
  defp safe_key("document_id"), do: :document_id
  defp safe_key("documentId"), do: :document_id
  defp safe_key(other), do: other
end
