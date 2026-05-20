defmodule Contract.MCP.RhwpReplay do
  @moduledoc """
  Server-side replay of rhwp text ops from the `changes` log into a flat
  paragraph list, so the agent's `doc.get` can return real document text
  even though the snapshot projection doesn't materialize text edits
  (rhwp WASM is the client-side source of truth; the Reducer just appends
  ops). See SPEC §15 and the prior post-mortem in #92-#96.

  Scope:

    * Replays only top-level body paragraphs (no `cell_path` / `parent_para`).
      Table cell text is dropped from the IR for now; the agent works on
      body clauses and tables come back in a follow-up.
    * Supported ops: insert_text, delete_text, insert_paragraph (split),
      merge_paragraph.
    * Offsets are interpreted as UTF-16 code units (matches what rhwp
      WASM emits). For BMP-only content (Korean, Latin) this is the same
      as Elixir grapheme positions, which is what we use.
    * insert_text with no `text` field (legacy rhwp builds) inserts a
      length-`len` placeholder of "?" so subsequent offsets stay aligned.

  Returns a list of `%{sec: int, idx: int, text: String}` ordered by
  insertion. Section index defaults to 0; this server-side replay does not
  yet track section structure (HWPX section nodes are only available from
  the binary snapshot, which is a separate parser).
  """

  alias Contract.Store

  @type paragraph :: %{required(:sec) => non_neg_integer(), required(:idx) => non_neg_integer(), required(:text) => String.t()}

  @doc """
  Replays text ops for `document_id` and returns paragraphs in order.

  Bypasses Runtime auth — call sites (e.g. `Contract.MCP.call_tool/4`)
  already authorize via route_ref + document_id binding before invoking
  this helper. The first arg is kept for symmetry with `Runtime.sync_since`
  in case a future caller wants to plumb ctx through; today it's ignored.
  """
  @spec replay(any(), Ecto.UUID.t()) :: {:ok, [paragraph()]} | {:error, term()}
  def replay(_ctx, document_id) when is_binary(document_id) do
    with {:ok, changes} <- Store.changes_since(document_id, 0) do
      paragraphs =
        changes
        |> Enum.filter(&(&1.command_kind == "edit_text"))
        |> Enum.flat_map(&payload_ops/1)
        |> Enum.reject(&cell_op?/1)
        |> Enum.reduce([""], &apply_op/2)
        |> Enum.with_index()
        |> Enum.map(fn {text, idx} -> %{sec: 0, idx: idx, text: text} end)

      {:ok, paragraphs}
    end
  end

  # ---------------------------------------------------------------------------
  # Op extraction + cell filtering
  # ---------------------------------------------------------------------------

  defp payload_ops(%Contract.Change{payload: payload}) when is_list(payload), do: payload
  defp payload_ops(_), do: []

  defp cell_op?(%{"args" => %{"cell_path" => [_ | _]}}), do: true
  defp cell_op?(%{"args" => %{"parent_para" => p}}) when is_integer(p), do: true
  defp cell_op?(_), do: false

  # ---------------------------------------------------------------------------
  # Op application — paragraphs is a list (index = paragraph idx, value = text)
  # ---------------------------------------------------------------------------

  defp apply_op(%{"op" => op, "args" => args}, paragraphs) when is_map(args) do
    args = atomize(args)
    do_apply(op, args, paragraphs)
  end

  defp apply_op(_, paragraphs), do: paragraphs

  defp do_apply("insert_text", %{para: para, off: off} = args, paragraphs) do
    text = Map.get(args, :text) || placeholder(Map.get(args, :len, 0))
    update_para(paragraphs, para, fn current -> insert_at(current, off, text) end)
  end

  defp do_apply("delete_text", %{para: para, off: off, count: count}, paragraphs)
       when is_integer(count) do
    update_para(paragraphs, para, fn current -> delete_at(current, off, count) end)
  end

  defp do_apply("delete_text", %{para: para, off: off, len: len}, paragraphs)
       when is_integer(len) do
    update_para(paragraphs, para, fn current -> delete_at(current, off, len) end)
  end

  defp do_apply("insert_paragraph", %{para: para, off: off}, paragraphs)
       when is_integer(off) do
    case Enum.at(paragraphs, para) do
      nil ->
        List.insert_at(paragraphs, para + 1, "")

      current ->
        {head, tail} = split_at(current, off)
        paragraphs |> List.replace_at(para, head) |> List.insert_at(para + 1, tail)
    end
  end

  defp do_apply("insert_paragraph", %{para: para}, paragraphs) do
    List.insert_at(paragraphs, para + 1, "")
  end

  defp do_apply("merge_paragraph", %{para: para}, paragraphs) when para > 0 do
    prev = Enum.at(paragraphs, para - 1, "")
    here = Enum.at(paragraphs, para, "")

    paragraphs
    |> List.replace_at(para - 1, prev <> here)
    |> List.delete_at(para)
  end

  defp do_apply(_op, _args, paragraphs), do: paragraphs

  # ---------------------------------------------------------------------------
  # String helpers — UTF-16 code-unit semantics ≈ graphemes for BMP content.
  # ---------------------------------------------------------------------------

  defp update_para(paragraphs, idx, fun) do
    current = Enum.at(paragraphs, idx, "")
    grown = grow(paragraphs, idx)
    List.replace_at(grown, idx, fun.(current))
  end

  defp grow(paragraphs, idx) when length(paragraphs) > idx, do: paragraphs

  defp grow(paragraphs, idx) do
    paragraphs ++ List.duplicate("", idx - length(paragraphs) + 1)
  end

  defp insert_at(text, off, insert) do
    {head, tail} = split_at(text, off)
    head <> insert <> tail
  end

  defp delete_at(text, off, count) do
    {head, rest} = split_at(text, off)
    {_, tail} = split_at(rest, count)
    head <> tail
  end

  defp split_at(text, off) when off <= 0, do: {"", text}

  defp split_at(text, off) do
    graphemes = String.graphemes(text)

    if off >= length(graphemes) do
      {text, ""}
    else
      {Enum.take(graphemes, off) |> Enum.join(),
       Enum.drop(graphemes, off) |> Enum.join()}
    end
  end

  defp placeholder(n) when is_integer(n) and n > 0, do: String.duplicate("?", n)
  defp placeholder(_), do: ""

  defp atomize(map) when is_map(map) do
    Map.new(map, fn {k, v} when is_binary(k) -> {String.to_atom(k), v}; {k, v} -> {k, v} end)
  end
end
