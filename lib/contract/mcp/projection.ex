defmodule Contract.MCP.Projection do
  @moduledoc """
  Adapter from `Contract.Runtime.State` projection (node-graph) to the flat
  `sections → paragraphs` shape that `Contract.Agent.Prompt.IRRenderer`
  consumes.

  ## Source of truth

  R2 is the canonical source. At snapshot time the client uploads both
  the native HWP/HWPX visual snapshot (`<rev>.hwp` or `<rev>.hwpx`) and the extracted agent IR
  (`<rev>.ir.json`); doc.get reads the `.ir.json` blob via the
  S3-compatible client (`Contract.IO.R2.get/2`). Postgres
  `rhwp_snapshots.projection` stays as a hot cache that's used when R2 is
  unreachable.

  The snapshotted IR is the base the agent reads. Text edits committed
  after that snapshot are overlaid for the compact MCP view so an agent
  can re-fetch after a revision-pinned edit and keep using current field
  offsets until the browser publishes the next native rhwp snapshot.

  Falls back to the legacy `node_order` projection path for docs created
  via `create_node` that never went through rhwp (no snapshot row).

  TODO(#120): emit `kind: "table"` with nested cell paragraphs once
  edit_table / insert_block lands.
  """

  import Ecto.Query
  require Logger

  alias Contract.Change
  alias Contract.Repo
  alias Contract.Runtime
  alias Contract.Runtime.State

  @doc """
  Build the agent-IR map for `IRRenderer.render/1`. Returns a plain map
  with stringified keys + the current revision baked in.

  When no real rhwp snapshot row exists, this returns the legacy IR
  projection without writing snapshot rows. `doc.get` always carries the
  compact IR inline, so a missing R2 snapshot is not a reason to create
  a fake visual snapshot record.
  """
  @spec to_agent_ir(State.t()) :: map()
  def to_agent_ir(%State{} = state) do
    case latest_rhwp_snapshot(state) do
      %Contract.RhwpSnapshot.Record{} = snap ->
        snapshot_ir =
          case fetch_ir_from_r2(snap) do
            {:ok, ir} when is_map(ir) and map_size(ir) > 0 ->
              from_snapshot(ir, state)

            _ ->
              from_db_projection(snap, state)
          end

        overlay_post_snapshot_text(snapshot_ir, state.document_id, snap.revision)

      nil ->
        # No rhwp snapshot has been committed yet for this document. There
        # is no legacy IR fallback — the agent simply sees an empty body
        # until the browser uploads its first snapshot.
        empty_ir(state)
    end
  end

  defp empty_ir(%State{} = state) do
    %{
      "title" => Map.get(state.projection, :title),
      "revision" => state.revision,
      "contract_type" => Map.get(state.projection, :type_key),
      "sections" => [],
      "fields" => []
    }
  end

  defp r2_driver do
    Application.get_env(:contract, :io_drivers, [])
    |> Keyword.get(:r2, Contract.IO.R2)
  end

  defp latest_rhwp_snapshot(%State{} = state) do
    Contract.RhwpSnapshot.latest_for_document(state.document_id, snapshot_format_for_state(state))
  end

  defp snapshot_format_for_state(%State{projection: projection}) do
    with type_key when is_binary(type_key) and type_key != "" <-
           map_value(projection, "type_key") || map_value(projection, "contract_type"),
         {:ok, spec} <- Contract.ContractTypes.get(type_key) do
      template_format(spec)
    else
      _ -> nil
    end
  end

  defp template_format(%{template_hwp_path: path}) when is_binary(path) and path != "", do: "hwp"

  defp template_format(%{template_hwpx_path: path}) when is_binary(path) and path != "",
    do: "hwpx"

  defp template_format(_spec), do: nil

  defp fetch_ir_from_r2(%Contract.RhwpSnapshot.Record{ir_r2_key: ir_key})
       when is_binary(ir_key) do
    with {:ok, body} <- r2_driver().get(ir_key),
         {:ok, ir} <- Jason.decode(body) do
      {:ok, ir}
    else
      err ->
        Logger.debug("doc.get: R2 IR fetch failed for #{ir_key}: #{inspect(err)}")
        err
    end
  end

  defp fetch_ir_from_r2(_), do: {:error, :no_key}

  # When R2 fetch fails, fall back to the snapshot row's cached `projection`
  # column (a hot copy of the same IR). If even that's empty we return an
  # empty IR — no legacy node-graph reconstruction.
  defp from_db_projection(
         %Contract.RhwpSnapshot.Record{projection: %{} = snap},
         %State{} = state
       )
       when map_size(snap) > 0,
       do: from_snapshot(snap, state)

  defp from_db_projection(_snap, %State{} = state), do: empty_ir(state)

  defp from_snapshot(snap, %State{} = state) do
    %{
      "title" => Map.get(snap, "title") || Map.get(state.projection, :title),
      "revision" => state.revision,
      "contract_type" => Map.get(snap, "contract_type") || Map.get(state.projection, :type_key),
      "sections" => normalize_sections(Map.get(snap, "sections", [])),
      "fields" => Map.get(snap, "fields", []) |> List.wrap()
    }
  end

  # ---------------------------------------------------------------------------
  # Outline / find / read — slim agent-facing slices of the IR.
  # ---------------------------------------------------------------------------

  # Korean clause/section headings. Documents flatten everything to plain
  # paragraphs with kind=nil, so we identify headings heuristically:
  # short lines that begin with 제 N 조 / 장 / 절 / 항.
  @heading_re ~r/^\s*제\s*[0-9０-９]+\s*[조장절항]/u

  @doc """
  Returns a compact navigational outline — heading paragraphs plus the
  document title row — so an agent can pick a target without slurping
  every paragraph.

  Each row: `[sec, para, level, text]` where `level` is 1 for `장`/`절`,
  2 for `조`, 3 for `항`, 0 for the title row.
  """
  @spec outline(map() | State.t()) :: [list()]
  def outline(%State{} = state), do: outline(to_agent_ir(state))

  def outline(%{"sections" => sections, "title" => title}) when is_list(sections) do
    head =
      case title do
        t when is_binary(t) and t != "" -> [[0, -1, 0, t]]
        _ -> []
      end

    body =
      for section <- sections,
          paragraph <- section["paragraphs"] || [],
          row = outline_row(section["idx"] || 0, paragraph),
          row != nil,
          do: row

    head ++ body
  end

  def outline(_), do: []

  defp outline_row(sec, %{"idx" => p, "text" => text}) when is_binary(text) do
    case heading_level(text) do
      nil -> nil
      level -> [sec, p, level, String.trim(text)]
    end
  end

  defp outline_row(_, _), do: nil

  defp heading_level(text) do
    cond do
      not is_binary(text) -> nil
      String.length(text) > 80 -> nil
      Regex.match?(~r/^\s*제\s*[0-9０-９]+\s*[장절]/u, text) -> 1
      Regex.match?(~r/^\s*제\s*[0-9０-９]+\s*조/u, text) -> 2
      Regex.match?(~r/^\s*제\s*[0-9０-９]+\s*항/u, text) -> 3
      Regex.match?(@heading_re, text) -> 2
      true -> nil
    end
  end

  @doc """
  Find every occurrence of `needle` across the document. Returns at most
  `limit` hits with `context` characters of leading/trailing snippet for
  disambiguation. Each hit carries the positional triple
  `(sec, para, off)` and the literal `match` substring, so the caller can
  feed them straight back into `doc.edit_text`.

  Result: `%{total: integer(), hits: [hit]}` where
  `hit = [sec, para, off, len, before, match, after, kind]`.
  """
  @spec find(map() | State.t(), String.t(), keyword()) ::
          %{total: non_neg_integer(), hits: list()}
  def find(%State{} = state, needle, opts), do: find(to_agent_ir(state), needle, opts)

  def find(%{"sections" => sections}, needle, opts)
      when is_binary(needle) and needle != "" and is_list(sections) do
    limit = Keyword.get(opts, :limit, 20)
    context = Keyword.get(opts, :context, 30)
    len = String.length(needle)

    {hits, total} =
      Enum.reduce(sections, {[], 0}, fn section, {acc, total} ->
        sec = section["idx"] || 0

        Enum.reduce(section["paragraphs"] || [], {acc, total}, fn p, {acc2, total2} ->
          text = p["text"] || ""
          kind = p["kind"] || "paragraph"
          para = p["idx"] || 0
          matches = grapheme_indices(text, needle)
          new_total = total2 + length(matches)

          new_hits =
            Enum.reduce(matches, acc2, fn off, acc3 ->
              if length(acc3) >= limit do
                acc3
              else
                hit = [
                  sec,
                  para,
                  off,
                  len,
                  context_before(text, off, context),
                  needle,
                  context_after(text, off + len, context),
                  kind
                ]

                [hit | acc3]
              end
            end)

          {new_hits, new_total}
        end)
      end)

    %{total: total, hits: Enum.reverse(hits)}
  end

  def find(_ir, _needle, _opts), do: %{total: 0, hits: []}

  defp grapheme_indices(haystack, needle) do
    graphemes = String.graphemes(haystack)
    nlen = String.length(needle)
    max_start = length(graphemes) - nlen

    if max_start < 0 do
      []
    else
      Enum.reduce(0..max_start, [], fn i, acc ->
        slice = graphemes |> Enum.slice(i, nlen) |> Enum.join()
        if slice == needle, do: [i | acc], else: acc
      end)
      |> Enum.reverse()
    end
  end

  defp context_before(text, off, ctx) do
    start = max(0, off - ctx)
    String.slice(text, start, off - start)
  end

  defp context_after(text, off_end, ctx), do: String.slice(text, off_end, ctx)

  @doc """
  Return a slice of paragraphs for `doc.read`. Either pass `:para` for a
  single paragraph, or `:from`/`:to` for a range (both inclusive). Up to
  `:limit` paragraphs are returned; the caller paginates via the
  `next_para` cursor.

  Result: `%{paragraphs: [[sec, para, kind, text]], next_para: integer() | nil}`.
  """
  @spec read(map() | State.t(), non_neg_integer(), keyword()) ::
          %{paragraphs: list(), next_para: non_neg_integer() | nil}
  def read(%State{} = state, sec, opts), do: read(to_agent_ir(state), sec, opts)

  def read(%{"sections" => sections}, sec, opts) when is_list(sections) do
    section = Enum.find(sections, %{}, fn s -> (s["idx"] || 0) == sec end)
    paragraphs = section["paragraphs"] || []
    single = Keyword.get(opts, :para)
    from = Keyword.get(opts, :from, 0)
    to = Keyword.get(opts, :to)
    limit = Keyword.get(opts, :limit, 50)

    cond do
      is_integer(single) ->
        case Enum.find(paragraphs, fn p -> (p["idx"] || 0) == single end) do
          nil -> %{paragraphs: [], next_para: nil}
          p -> %{paragraphs: [paragraph_row(sec, p)], next_para: nil}
        end

      true ->
        # Scan all paragraphs >= `from`, optionally cap by `to`, then apply
        # `limit`. `next_para` carries the idx of the first paragraph that
        # didn't fit (either because limit was hit or `to` was set tight) so
        # the caller can resume.
        candidates =
          for p <- paragraphs, idx = p["idx"] || 0, idx >= from, is_nil(to) or idx <= to, do: p

        {window, rest} = Enum.split(candidates, limit)
        rows = Enum.map(window, &paragraph_row(sec, &1))
        next = if rest == [], do: nil, else: hd(rest)["idx"] || 0
        %{paragraphs: rows, next_para: next}
    end
  end

  def read(_ir, _sec, _opts), do: %{paragraphs: [], next_para: nil}

  defp paragraph_row(sec, %{"idx" => p, "text" => text} = paragraph) do
    [sec, p, paragraph["kind"] || "paragraph", text || ""]
  end

  defp paragraph_row(sec, p), do: [sec, p["idx"] || 0, p["kind"] || "paragraph", p["text"] || ""]

  @doc """
  Total paragraph count across all sections — used by `doc.get` to
  expose `counts.para` without shipping every paragraph.
  """
  @spec paragraph_count(map() | State.t()) :: non_neg_integer()
  def paragraph_count(%State{} = state), do: paragraph_count(to_agent_ir(state))

  def paragraph_count(%{"sections" => sections}) when is_list(sections) do
    Enum.reduce(sections, 0, fn s, acc -> acc + length(s["paragraphs"] || []) end)
  end

  def paragraph_count(_), do: 0

  defp normalize_sections(sections) when is_list(sections) do
    sections
    |> Enum.with_index()
    |> Enum.map(fn {sec, default_idx} ->
      %{
        "idx" => Map.get(sec, "idx", default_idx),
        "paragraphs" =>
          sec
          |> Map.get("paragraphs", [])
          |> Enum.with_index()
          |> Enum.map(fn {p, default_pidx} ->
            %{
              "idx" => Map.get(p, "idx", default_pidx),
              "text" => Map.get(p, "text", "")
            }
            |> maybe_put_kind(p)
          end)
      }
    end)
  end

  defp normalize_sections(_), do: []

  defp maybe_put_kind(paragraph, %{"kind" => kind}) when is_binary(kind),
    do: Map.put(paragraph, "kind", kind)

  defp maybe_put_kind(paragraph, _), do: paragraph

  defp overlay_post_snapshot_text(ir, document_id, snapshot_revision) do
    document_id
    |> post_snapshot_text_ops(snapshot_revision || 0)
    |> Enum.reduce(ir, fn op, acc -> apply_text_op(acc, op) end)
    |> refresh_field_values()
  end

  defp post_snapshot_text_ops(document_id, snapshot_revision) do
    Repo.all(
      from c in Change,
        where:
          c.document_id == ^document_id and c.command_kind == "edit_text" and
            c.result_revision > ^snapshot_revision,
        order_by: [asc: c.result_revision]
    )
    |> Enum.flat_map(fn %Change{payload: payload} -> payload || [] end)
    |> Enum.flat_map(&normalize_text_op/1)
  end

  defp normalize_text_op(op) when is_map(op) do
    kind = map_value(op, "op") || map_value(op, "kind")
    args = map_value(op, "args") || op

    case kind do
      "insert_text" ->
        text = map_value(args, "text") || ""

        if is_binary(text) and text != "" do
          [
            %{
              kind: "insert_text",
              sec: int_value(args, "sec"),
              para: int_value(args, "para"),
              off: int_value(args, "off"),
              text: text,
              cell_path: map_value(args, "cell_path"),
              field_id: map_value(args, "field_id")
            }
          ]
        else
          []
        end

      "delete_text" ->
        count = int_value(args, "count") || int_value(args, "len") || 0

        if count > 0 do
          [
            %{
              kind: "delete_text",
              sec: int_value(args, "sec"),
              para: int_value(args, "para"),
              off: int_value(args, "off"),
              count: count,
              cell_path: map_value(args, "cell_path"),
              field_id: map_value(args, "field_id")
            }
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  defp normalize_text_op(_), do: []

  defp apply_text_op(ir, %{sec: sec, para: para, off: off} = op)
       when is_integer(sec) and is_integer(para) and is_integer(off) do
    ir
    |> Map.update("sections", [], &apply_text_op_to_sections(&1, op))
    |> Map.update("fields", [], &apply_text_op_to_fields(&1, op))
  end

  defp apply_text_op(ir, _op), do: ir

  defp apply_text_op_to_sections(sections, %{cell_path: [_ | _]}), do: sections

  defp apply_text_op_to_sections(sections, op) do
    Enum.map(sections || [], fn section ->
      if map_value(section, "idx") == op.sec do
        Map.update(section, "paragraphs", [], fn paragraphs ->
          Enum.map(paragraphs || [], fn paragraph ->
            if map_value(paragraph, "idx") == op.para and is_binary(map_value(paragraph, "text")) do
              Map.put(paragraph, "text", apply_text_to_string(map_value(paragraph, "text"), op))
            else
              paragraph
            end
          end)
        end)
      else
        section
      end
    end)
  end

  defp apply_text_to_string(text, %{kind: "insert_text", off: off, text: inserted}) do
    off = clamp(off, 0, String.length(text))
    String.slice(text, 0, off) <> inserted <> String.slice(text, off, String.length(text) - off)
  end

  defp apply_text_to_string(text, %{kind: "delete_text", off: off, count: count}) do
    length = String.length(text)
    off = clamp(off, 0, length)
    count = clamp(count, 0, length - off)
    String.slice(text, 0, off) <> String.slice(text, off + count, length - off - count)
  end

  defp apply_text_op_to_fields(fields, op) do
    Enum.map(fields || [], &apply_text_op_to_field(&1, op))
  end

  defp apply_text_op_to_field(field, %{cell_path: [_ | _]}), do: field

  defp apply_text_op_to_field(field, op) when is_map(field) do
    pos = map_value(field, "position") || %{}

    cond do
      not same_body_position?(pos, op) ->
        field

      map_value(field, "id") == op.field_id and op.kind == "insert_text" ->
        put_field_position(field, pos, op.off, op.off + String.length(op.text))

      map_value(field, "id") == op.field_id and op.kind == "delete_text" ->
        put_field_position(field, pos, op.off, op.off)

      op.kind == "insert_text" ->
        shift_field_position(field, pos, op.off, String.length(op.text))

      op.kind == "delete_text" ->
        delete_from_field_position(field, pos, op.off, op.count)

      true ->
        field
    end
  end

  defp apply_text_op_to_field(field, _op), do: field

  defp same_body_position?(pos, op) when is_map(pos) do
    map_value(pos, "cell_path") in [nil, []] and map_value(pos, "sec") == op.sec and
      map_value(pos, "para") == op.para
  end

  defp same_body_position?(_pos, _op), do: false

  defp shift_field_position(field, pos, insert_off, delta) do
    start_off = map_value(pos, "off_start") || 0
    end_off = map_value(pos, "off_end") || start_off

    put_field_position(
      field,
      pos,
      shift_insert_anchor(start_off, insert_off, delta),
      shift_insert_anchor(end_off, insert_off, delta)
    )
  end

  defp delete_from_field_position(field, pos, delete_off, count) do
    start_off = map_value(pos, "off_start") || 0
    end_off = map_value(pos, "off_end") || start_off

    put_field_position(
      field,
      pos,
      shift_delete_anchor(start_off, delete_off, count),
      shift_delete_anchor(end_off, delete_off, count)
    )
  end

  defp shift_insert_anchor(anchor, insert_off, delta) when anchor >= insert_off,
    do: anchor + delta

  defp shift_insert_anchor(anchor, _insert_off, _delta), do: anchor

  defp shift_delete_anchor(anchor, delete_off, count) do
    delete_end = delete_off + count

    cond do
      anchor <= delete_off -> anchor
      anchor >= delete_end -> anchor - count
      true -> delete_off
    end
  end

  defp put_field_position(field, pos, start_off, end_off) do
    pos =
      pos
      |> Map.put("off_start", max(start_off, 0))
      |> Map.put("off_end", max(end_off, 0))

    Map.put(field, "position", pos)
  end

  defp refresh_field_values(%{"fields" => fields, "sections" => sections} = ir) do
    fields =
      Enum.map(fields || [], fn field ->
        case field_text(sections, map_value(field, "position"), field) do
          nil -> field
          value -> Map.put(field, "value", value)
        end
      end)

    Map.put(ir, "fields", fields)
  end

  defp refresh_field_values(ir), do: ir

  defp field_text(sections, pos, field) when is_map(pos) do
    with true <- map_value(pos, "cell_path") in [nil, []],
         sec when is_integer(sec) <- map_value(pos, "sec"),
         para when is_integer(para) <- map_value(pos, "para"),
         start_off when is_integer(start_off) <- map_value(pos, "off_start"),
         end_off when is_integer(end_off) <- map_value(pos, "off_end"),
         text when is_binary(text) <- paragraph_text(sections, sec, para) do
      start_off = clamp(start_off, 0, String.length(text))
      end_off = clamp(end_off, start_off, String.length(text))
      ranged_value = String.slice(text, start_off, end_off - start_off)
      full_value_at_start(text, start_off, field) || ranged_value
    else
      _ -> nil
    end
  end

  defp field_text(_sections, _pos, _field), do: nil

  defp full_value_at_start(text, start_off, field) do
    value = map_value(field, "value")

    cond do
      not is_binary(value) or value == "" ->
        nil

      String.slice(text, start_off, String.length(value)) == value ->
        value

      true ->
        nil
    end
  end

  defp paragraph_text(sections, sec, para) do
    Enum.find_value(sections || [], fn section ->
      if map_value(section, "idx") == sec do
        Enum.find_value(map_value(section, "paragraphs") || [], fn paragraph ->
          if map_value(paragraph, "idx") == para, do: map_value(paragraph, "text")
        end)
      end
    end)
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, existing_atom(key))
  end

  defp map_value(_map, _key), do: nil

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp int_value(map, key) do
    case map_value(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp clamp(value, min, max), do: value |> max(min) |> min(max)

  @spec load_agent_ir(any(), binary()) :: {:ok, map()} | {:error, term()}
  def load_agent_ir(ctx, document_id) do
    with {:ok, %State{} = state} <- Runtime.load(ctx, document_id) do
      {:ok, to_agent_ir(state)}
    end
  end
end
