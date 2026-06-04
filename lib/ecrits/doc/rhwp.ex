defmodule Ecrits.Doc.Rhwp do
  @moduledoc """
  HWP/HWPX backend for `Ecrits.Doc`, served by the headless `ehwp` server NIF.

  This is the **server arm** of the design (§2.1, §3): the authoritative model
  for documents that are *not* currently open in a browser. Rendering is the
  browser's job; this backend only opens, reads, finds, and edits the in-memory
  model through the `Ehwp` facade.

  ## Capability honesty

  The current `ehwp` NIF exposes `open`/`read`/`find`/`write({:replace_one})`
  (plus `page_count`/`render_page_svg`/`profile`). The design's richer
  edit-only NIF surface — `get/set_*_properties`, `apply_style`, structural
  verbs, and `save`/export — is a *future* `ehwp` revival (design §8 "다음" #1,
  #6). Until those NIFs land, the corresponding callbacks return
  `{:error, {:not_supported, reason}}` rather than silently faking success
  (the existing `Ecrits.Local.Agent.DocumentTools.write/2` takes the same
  honest stance).

  Mapped today:

    * `read/2`            -> `Ehwp.read/2`
    * `find/3`            -> `Ehwp.find/3`
    * `outline/3`         -> synthesised from `read` text (paragraph tree)
    * `edit replace_text` -> `Ehwp.write(handle, {:replace_one, q, r})`

  Not yet (`{:not_supported}`): `get/3`, `set/4`, `apply_style/3`,
  `edit insert_text|delete_range|split|insert_node|delete_node|move_node|insert_picture`,
  `save/2`.
  """

  @behaviour Ecrits.Doc

  alias Ecrits.Doc.Op
  alias Ecrits.Doc.Rhwp.Ref

  @typedoc "Engine handle: the `Ehwp.Handle` plus cached paragraph offsets."
  @type handle :: %{ehwp: Ehwp.Handle.t() | term(), sec: non_neg_integer()}

  @impl true
  def kind, do: :hwp

  @impl true
  def open(path, opts \\ []) do
    case Ehwp.open(path, opts) do
      {:ok, ehwp_handle, _metadata} -> {:ok, %{ehwp: ehwp_handle, sec: 0}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def close(%{ehwp: ehwp_handle}), do: Ehwp.close(ehwp_handle)
  def close(_handle), do: :ok

  @impl true
  def read(%{ehwp: ehwp_handle}, opts) do
    case Ehwp.read(ehwp_handle, Keyword.take(opts, [:case_sensitive])) do
      {:ok, result} ->
        text = normalize_text(result)
        {:ok, %{text: text, size: String.length(text), at: 0}}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def find(%{ehwp: ehwp_handle} = handle, pattern, opts) when is_binary(pattern) do
    case Ehwp.find(ehwp_handle, pattern, Keyword.take(opts, [:case_sensitive])) do
      {:ok, result} ->
        sec = handle.sec
        matches = result |> decode_matches() |> Enum.map(&match_to_ref(&1, sec, pattern))
        {:ok, matches}

      {:error, _reason} = error ->
        error
    end
  end

  def find(_handle, _pattern, _opts), do: {:error, :invalid_pattern}

  @impl true
  def outline(%{ehwp: ehwp_handle} = handle, ref, _opts) do
    with {:ok, scope} <- scope_ref(ref),
         {:ok, text} <- read_text(ehwp_handle) do
      {:ok, build_outline(text, handle.sec, scope)}
    end
  end

  @impl true
  def get(_handle, ref, _props) do
    with {:ok, _decoded} <- Ref.decode(ref) do
      not_supported(
        "doc.get property read requires the edit-only ehwp NIF (get_*_properties); not in the current NIF"
      )
    end
  end

  @impl true
  def set(_handle, ref, props, _base_rev) when is_map(props) do
    with {:ok, _decoded} <- Ref.decode(ref) do
      not_supported(
        "doc.set property edit requires the edit-only ehwp NIF (set_*_properties/apply_char_props); not in the current NIF"
      )
    end
  end

  @impl true
  def edit(handle, op, _base_rev) do
    with {:ok, op} <- Op.normalize(op) do
      do_edit(handle, op)
    end
  end

  @impl true
  def apply_style(_handle, ref, _style) do
    with {:ok, _decoded} <- Ref.decode(ref) do
      not_supported(
        "doc.apply_style requires the edit-only ehwp NIF (apply_style); not in the current NIF"
      )
    end
  end

  @impl true
  def save(_handle, _opts) do
    not_supported(
      "doc.save requires HWP/HWPX export (canonical bytes) which the current ehwp NIF does not expose (design §8 #6, §9)"
    )
  end

  # --- edit verbs ----------------------------------------------------------

  defp do_edit(%{ehwp: ehwp_handle}, %{op: "replace_text"} = op) do
    with {:ok, query} <- require_field(op, :query),
         {:ok, replacement} <- require_field(op, :replacement) do
      case Ehwp.write(ehwp_handle, {:replace_one, query, replacement}, []) do
        {:ok, result} ->
          {:ok, %{op: "replace_text", invalidated: [0], native: decode_write(result)}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp do_edit(_handle, %{op: verb})
       when verb in ~w(insert_text delete_range split insert_node delete_node move_node insert_picture) do
    not_supported(
      "doc.edit op=#{verb} requires the edit-only ehwp NIF (structural verbs); the current NIF only exposes replace_text"
    )
  end

  defp do_edit(_handle, %{op: verb}), do: {:error, {:unknown_op, verb}}

  # --- helpers -------------------------------------------------------------

  defp not_supported(reason), do: {:error, {:not_supported, reason}}

  defp require_field(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_op, "#{key} (non-empty string) is required"}}
    end
  end

  defp read_text(ehwp_handle) do
    case Ehwp.read(ehwp_handle, []) do
      {:ok, result} -> {:ok, normalize_text(result)}
      {:error, _reason} = error -> error
    end
  end

  defp scope_ref(nil), do: {:ok, %{kind: :document}}

  defp scope_ref(ref) when is_binary(ref) do
    case Ref.decode(ref) do
      {:ok, %{kind: kind} = decoded} when kind in [:document, :section, :paragraph] ->
        {:ok, decoded}

      {:ok, _other} ->
        {:error, {:invalid_ref, ref}}

      {:error, _reason} = error ->
        error
    end
  end

  defp scope_ref(_ref), do: {:error, :invalid_ref}

  defp build_outline(text, sec, scope) do
    paragraphs = split_paragraphs(text)

    children =
      paragraphs
      |> Enum.with_index()
      |> Enum.filter(fn {_para, idx} -> in_scope?(scope, sec, idx) end)
      |> Enum.map(fn {para_text, idx} ->
        %{
          ref: Ref.encode(%{kind: :paragraph, sec: sec, para: idx}),
          type: "paragraph",
          text: preview(para_text)
        }
      end)

    %{
      ref: Ref.encode(scope_to_node(scope, sec)),
      type: outline_type(scope),
      children: children
    }
  end

  defp scope_to_node(%{kind: :paragraph} = scope, _sec), do: scope
  defp scope_to_node(%{kind: :section, sec: sec}, _), do: %{kind: :section, sec: sec}
  defp scope_to_node(_scope, _sec), do: %{kind: :document}

  defp outline_type(%{kind: :paragraph}), do: "paragraph"
  defp outline_type(%{kind: :section}), do: "section"
  defp outline_type(_scope), do: "document"

  defp in_scope?(%{kind: :document}, _sec, _idx), do: true
  defp in_scope?(%{kind: :section, sec: s}, sec, _idx), do: s == sec
  defp in_scope?(%{kind: :paragraph, sec: s, para: p}, sec, idx), do: s == sec and p == idx
  defp in_scope?(_scope, _sec, _idx), do: true

  defp split_paragraphs(text) do
    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.reject(&(&1 == ""))
  end

  defp preview(text, max \\ 80) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp match_to_ref(match, sec, pattern) when is_map(match) do
    para = match["para"] || match[:para] || 0
    off = match["off"] || match["charOffset"] || match[:off] || 0
    len = match["count"] || match["length"] || match[:count] || String.length(pattern)
    text = match["text"] || match[:text] || pattern

    %{
      ref: Ref.encode(%{kind: :char, sec: sec, para: para, off: off, len: len}),
      text: text,
      off: off,
      len: len
    }
  end

  defp decode_matches(matches) when is_list(matches), do: Enum.map(matches, &stringify/1)

  defp decode_matches(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      {:ok, %{"matches" => list}} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_matches(%{"matches" => list}) when is_list(list), do: list
  defp decode_matches(%{matches: list}) when is_list(list), do: Enum.map(list, &stringify/1)
  defp decode_matches(_other), do: []

  defp decode_write(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> map
      _ -> %{"raw" => json}
    end
  end

  defp decode_write(other), do: other

  defp stringify(%{} = map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp stringify(other), do: other

  defp normalize_text(text) when is_binary(text), do: text

  defp normalize_text(%{} = result) do
    cond do
      is_binary(result["text"]) -> result["text"]
      is_binary(result[:text]) -> result[:text]
      is_binary(result["content"]) -> result["content"]
      is_binary(result[:content]) -> result[:content]
      true -> ""
    end
  end

  defp normalize_text(_other), do: ""
end
