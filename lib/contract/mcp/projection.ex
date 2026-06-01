defmodule Contract.MCP.Projection do
  @moduledoc """
  Adapter from `Contract.Runtime.State` projection (node-graph) to the flat
  `sections → paragraphs` shape used by the document MCP projection helpers.

  ## Source of truth

  `rhwp_snapshots.projection` is the legacy hosted snapshot source. Active
  local-first HWP/HWPX snapshots are stored under `.contract` by
  `Contract.Local.Document`.

  The snapshotted IR is the base the agent reads. Text edits committed
  after that snapshot are overlaid for the compact MCP view so an agent
  can re-fetch after a revision-pinned edit and keep using current field
  offsets until the browser publishes the next native rhwp snapshot.

  Before the first rhwp snapshot for typed templates, falls back to the
  template editable spec so agents can still discover writable text slots.

  Table paragraphs keep nested cell paragraphs for compact read windows.
  """

  import Ecto.Query
  alias Contract.Change
  alias Contract.Repo
  alias Contract.Runtime.State

  @text_command_kinds ~w(edit_text doc_write)

  @doc """
  Build the agent-IR map used by doc.get/doc.read/doc.write. Returns a plain
  map with stringified keys + the current revision baked in.

  When no real rhwp snapshot row exists, this returns an empty IR. The legacy
  template-editables fallback is intentionally not used for agent reads because
  it is semantic/preprocessed data, not canonical HWP positional metadata.
  """
  @spec to_agent_ir(State.t()) :: map()
  def to_agent_ir(%State{} = state) do
    case latest_rhwp_snapshot(state) do
      %Contract.RhwpSnapshot.Record{} = snap ->
        snapshot_ir = from_db_projection(snap, state)

        overlay_post_snapshot_text(snapshot_ir, state.document_id, snap.revision)

      nil ->
        empty_ir(state)
    end
  end

  @doc false
  @spec current_snapshot_revision(State.t()) :: non_neg_integer() | nil
  def current_snapshot_revision(%State{} = state) do
    case latest_rhwp_snapshot(state) do
      %Contract.RhwpSnapshot.Record{revision: revision} when is_integer(revision) -> revision
      _ -> nil
    end
  end

  @doc """
  Fail-closed guard for MCP text edits that rely on the rhwp projection as
  their coordinate basis.

  A latest snapshot marked incomplete/stale is not safe to edit against. A
  same-revision snapshot also has to prove it includes already committed text
  ops for that revision; otherwise the MCP view can be shorter than the native
  document and generate destructive ranges.
  """
  @spec validate_text_edit_basis(State.t()) :: :ok | {:error, {:invalid_params, binary()}}
  def validate_text_edit_basis(%State{} = state) do
    case latest_rhwp_snapshot(state) do
      %Contract.RhwpSnapshot.Record{} = snap ->
        with {:ok, raw_ir} <- snapshot_raw_ir(snap),
             :ok <- validate_projection_basis(raw_ir, "latest"),
             :ok <- validate_same_revision_text_basis(snap, state, raw_ir) do
          :ok
        end

      nil ->
        :ok
    end
  end

  @doc """
  Target-scoped sibling for document text writes.

  A stale same-revision snapshot elsewhere in the document should not block a
  localized write whose target was not touched by the unmaterialized text
  ops.
  """
  @spec validate_text_edit_basis(State.t(), [map()]) ::
          :ok | {:error, {:invalid_params, binary()}}
  def validate_text_edit_basis(%State{} = state, pending_ops) when is_list(pending_ops) do
    case validate_text_edit_basis(state) do
      :ok ->
        :ok

      {:error, {:invalid_params, "same-revision projection basis" <> _} = reason} ->
        if pending_ops_disjoint_from_unmaterialized_text?(state, pending_ops) do
          :ok
        else
          {:error, reason}
        end

      other ->
        other
    end
  end

  def validate_text_edit_basis(%State{} = state, _pending_ops),
    do: validate_text_edit_basis(state)

  defp snapshot_raw_ir(%Contract.RhwpSnapshot.Record{} = snap) do
    case snap.projection do
      %{} = projection when map_size(projection) > 0 -> {:ok, projection}
      _ -> {:ok, %{}}
    end
  end

  defp validate_projection_basis(%{} = raw_ir, label) do
    case map_value(raw_ir, "basis") do
      %{} = basis ->
        status = map_value(basis, "status")
        complete? = map_value(basis, "complete")

        cond do
          status in ["incomplete", "stale"] ->
            {:error,
             {:invalid_params,
              "#{label} projection basis is #{status}; refusing doc.write until the snapshot is complete"}}

          complete? == false ->
            {:error,
             {:invalid_params,
              "#{label} projection basis is incomplete; refusing doc.write until the snapshot is complete"}}

          true ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp validate_same_revision_text_basis(
         %Contract.RhwpSnapshot.Record{document_id: document_id, revision: revision} = snap,
         %State{} = state,
         raw_ir
       )
       when is_binary(document_id) and is_integer(revision) do
    case text_ops_between(document_id, 0, revision) do
      [] ->
        :ok

      _ops ->
        case materialized_from_prior_snapshot?(snap, state, raw_ir) do
          true ->
            :ok

          false ->
            {:error,
             {:invalid_params,
              "same-revision projection basis is stale or missing committed text ops; refusing doc.write"}}
        end
    end
  end

  defp validate_same_revision_text_basis(_snap, _state, _raw_ir), do: :ok

  defp materialized_from_prior_snapshot?(
         %Contract.RhwpSnapshot.Record{document_id: document_id, revision: revision} = snap,
         %State{} = state,
         raw_ir
       )
       when is_binary(document_id) and is_integer(revision) do
    current = from_snapshot(raw_ir, state) |> document_text_index()

    snap
    |> prior_rhwp_snapshots()
    |> Enum.any?(fn previous ->
      with {:ok, previous_raw_ir} <- snapshot_raw_ir(previous),
           :ok <- validate_projection_basis(previous_raw_ir, "previous") do
        ops = text_ops_between(document_id, previous.revision, revision)

        expected =
          previous_raw_ir
          |> from_snapshot(state)
          |> overlay_text_ops(ops)
          |> document_text_index()

        keys = materialized_text_keys(ops, expected)
        keys != MapSet.new() and Enum.all?(keys, &(Map.get(expected, &1) == Map.get(current, &1)))
      else
        _ -> false
      end
    end)
  end

  defp materialized_from_prior_snapshot?(_snap, _state, _raw_ir), do: false

  defp prior_rhwp_snapshots(%Contract.RhwpSnapshot.Record{
         document_id: document_id,
         revision: revision,
         format: format
       })
       when is_binary(document_id) and is_integer(revision) do
    Repo.all(
      from s in Contract.RhwpSnapshot.Record,
        where: s.document_id == ^document_id and s.format == ^format and s.revision < ^revision,
        order_by: [desc: s.revision]
    )
  end

  defp prior_rhwp_snapshots(_snap), do: []

  defp materialized_text_keys(ops, expected_index) when is_list(ops) and is_map(expected_index) do
    ops
    |> Enum.reduce(MapSet.new(), fn
      %{kind: "insert_text", sec: sec, para: para}, keys
      when is_integer(sec) and is_integer(para) ->
        MapSet.put(keys, {sec, para})

      %{kind: "delete_text", sec: sec, para: para}, keys
      when is_integer(sec) and is_integer(para) ->
        MapSet.put(keys, {sec, para})

      %{kind: "insert_paragraph", sec: sec, para: para}, keys
      when is_integer(sec) and is_integer(para) ->
        [para, para + 1, para + 2]
        |> Enum.filter(&Map.has_key?(expected_index, {sec, &1}))
        |> Enum.reduce(keys, &MapSet.put(&2, {sec, &1}))

      _op, keys ->
        keys
    end)
  end

  defp materialized_text_keys(_ops, _expected_index), do: MapSet.new()

  defp pending_ops_disjoint_from_unmaterialized_text?(%State{} = state, pending_ops) do
    with %Contract.RhwpSnapshot.Record{} = snap <- latest_rhwp_snapshot(state),
         %Contract.RhwpSnapshot.Record{} = previous <- previous_rhwp_snapshot(snap) do
      changed_keys =
        snap.document_id
        |> text_ops_between(previous.revision, snap.revision)
        |> text_op_keys()

      pending_keys = text_op_keys(pending_ops)

      changed_keys != MapSet.new() and MapSet.disjoint?(changed_keys, pending_keys)
    else
      _ -> false
    end
  end

  defp previous_rhwp_snapshot(%Contract.RhwpSnapshot.Record{
         document_id: document_id,
         revision: revision,
         format: format
       })
       when is_binary(document_id) and is_integer(revision) do
    Repo.one(
      from s in Contract.RhwpSnapshot.Record,
        where: s.document_id == ^document_id and s.format == ^format and s.revision < ^revision,
        order_by: [desc: s.revision],
        limit: 1
    )
  end

  defp previous_rhwp_snapshot(_snap), do: nil

  defp empty_ir(%State{} = state) do
    %{
      "title" => Map.get(state.projection, :title),
      "revision" => state.revision,
      "contract_type" => Map.get(state.projection, :type_key),
      "sections" => [],
      "pages" => [],
      "fields" => []
    }
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
      "pages" => normalize_pages(Map.get(snap, "pages", [])),
      "fields" => Map.get(snap, "fields", []) |> List.wrap()
    }
    |> maybe_put(
      "positional_index",
      normalize_positional_index(Map.get(snap, "positional_index"))
    )
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
  2 for `조`, 3 for `항`, 0 for the title row. The text is a heading label
  only; article body text stays behind `doc.read`.
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
      level -> [sec, p, level, outline_heading_label(text, level)]
    end
  end

  defp outline_row(_, _), do: nil

  defp outline_heading_label(text, 2) do
    trimmed = String.trim(text)

    case Regex.run(~r/^(.+?[)）])(?=\s|$)/u, trimmed) do
      [_, label] -> String.trim(label)
      _ -> strip_outline_body_marker(trimmed)
    end
  end

  defp outline_heading_label(text, _level), do: strip_outline_body_marker(String.trim(text))

  defp strip_outline_body_marker(text) do
    text
    |> String.split(~r/\s+[①②③④⑤⑥⑦⑧⑨⑩]/u, parts: 2)
    |> List.first()
    |> String.trim()
  end

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

  @doc false
  @spec paragraph_text_at(map() | State.t(), non_neg_integer(), non_neg_integer()) ::
          String.t() | nil
  def paragraph_text_at(%State{} = state, sec, para),
    do: paragraph_text_at(to_agent_ir(state), sec, para)

  def paragraph_text_at(%{"sections" => sections}, sec, para),
    do: paragraph_text_from_sections(sections, sec, para)

  def paragraph_text_at(_ir, _sec, _para), do: nil

  @doc """
  Compact doc.read v2 surface: section + logical leaf index window.
  """
  @spec read_window(map() | State.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          map()
  def read_window(%State{} = state, sec, at, size),
    do: read_window(to_agent_ir(state), sec, at, size)

  def read_window(%{"sections" => sections}, sec, at, size)
      when is_list(sections) and is_integer(at) and is_integer(size) do
    section = Enum.find(sections, %{}, fn s -> (s["idx"] || 0) == sec end)

    leaves =
      section
      |> Map.get("paragraphs", [])
      |> logical_read_leaves(sec)

    at = max(at, 0)
    size = max(size, 1)
    {items, rest} = leaves |> Enum.drop(at) |> Enum.split(size)
    next = if rest == [], do: nil, else: at + length(items)

    %{
      "sec" => sec,
      "at" => at,
      "items" => items
    }
    |> maybe_put("next_at", next)
  end

  def read_window(_ir, sec, at, _size),
    do: %{"sec" => sec, "at" => max(at, 0), "items" => []}

  defp logical_read_leaves(paragraphs, sec) do
    paragraphs
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"kind" => "table"} = paragraph ->
        paragraph_table_cells(sec, paragraph["idx"] || 0, paragraph)
        |> Enum.map(fn cell ->
          %{
            "kind" => "cell",
            "sec" => sec,
            "para" => cell["target"]["para"],
            "row" => cell["row"],
            "col" => cell["col"],
            "cell_para" => cell["cell_para_index"],
            "text" => cell["text"] || "",
            "chars" => String.length(cell["text"] || "")
          }
        end)

      %{} = paragraph ->
        text = paragraph["text"] || ""

        [
          %{
            "sec" => sec,
            "para" => paragraph["idx"] || 0,
            "kind" => paragraph["kind"] || "paragraph",
            "text" => text,
            "chars" => String.length(text)
          }
        ]

      _ ->
        []
    end)
  end

  @doc """
  HWP positional metadata for `doc.get`.

  This deliberately exposes only generic section/paragraph/table coordinates.
  Semantic fields, labels, values, and preprocessed editable slots stay out of
  the metadata page.
  """
  @spec positional_index(map() | State.t()) :: map()
  def positional_index(%State{} = state), do: positional_index(to_agent_ir(state))

  def positional_index(%{
        "sections" => sections,
        "positional_index" => %{"paragraphs" => paragraphs} = index
      })
      when is_list(sections) and is_list(paragraphs) do
    paragraph_refs = normalize_positional_paragraph_refs(paragraphs)
    table_refs = normalize_positional_table_refs(Map.get(index, "tables", []))
    pages = pages_from_positional_index(paragraph_refs, table_refs)
    hwp_sections = positional_hwp_sections(sections)
    {tables, cell_count} = table_index_counts(table_refs)

    %{
      "hwp_sections" => hwp_sections,
      "pages" => pages,
      "paragraph_refs" => paragraph_refs,
      "table_controls" => tables,
      "table_cell_count" => cell_count,
      "grid_table_controls" =>
        Enum.count(tables, fn table -> table["hwp_shape"] == "grid_control" end),
      "single_cell_table_controls" =>
        Enum.count(tables, fn table -> table["hwp_shape"] == "single_cell_control" end),
      "note" =>
        "HWP sections and table_controls are format coordinates. table_controls include layout/title/note boxes such as 1x1 controls; they are not semantic business tables."
    }
  end

  def positional_index(%{"sections" => sections} = ir) when is_list(sections) do
    pages = Map.get(ir, "pages", [])
    paragraph_refs = page_paragraph_refs(pages)
    paragraph_pages = paragraph_page_lookup(paragraph_refs)

    {tables, cell_count} =
      sections
      |> Enum.flat_map(&section_table_index/1)
      |> Enum.map(&maybe_put(&1, "page", Map.get(paragraph_pages, {&1["sec"], &1["para"]})))
      |> table_index_counts()

    %{
      "hwp_sections" => positional_hwp_sections(sections),
      "pages" => pages,
      "paragraph_refs" => paragraph_refs,
      "table_controls" => tables,
      "table_cell_count" => cell_count,
      "grid_table_controls" =>
        Enum.count(tables, fn table -> table["hwp_shape"] == "grid_control" end),
      "single_cell_table_controls" =>
        Enum.count(tables, fn table -> table["hwp_shape"] == "single_cell_control" end),
      "note" =>
        "HWP sections and table_controls are format coordinates. table_controls include layout/title/note boxes such as 1x1 controls; they are not semantic business tables."
    }
  end

  def positional_index(_) do
    %{
      "hwp_sections" => [],
      "pages" => [],
      "paragraph_refs" => [],
      "table_controls" => [],
      "table_cell_count" => 0,
      "grid_table_controls" => 0,
      "single_cell_table_controls" => 0,
      "note" =>
        "HWP sections and table_controls are format coordinates. table_controls include layout/title/note boxes such as 1x1 controls; they are not semantic business tables."
    }
  end

  defp section_table_index(section) do
    sec = section["idx"] || 0

    section
    |> Map.get("paragraphs", [])
    |> Enum.flat_map(fn paragraph ->
      para = paragraph["idx"] || 0

      paragraph_tables(sec, para, paragraph)
      |> Enum.map(fn table ->
        %{
          "sec" => sec,
          "para" => para,
          "control_index" => table["control_index"],
          "rows" => table["rows"],
          "cols" => table["cols"],
          "hwp_shape" => table_control_shape(table),
          "cells" => length(table["cells"] || [])
        }
      end)
    end)
  end

  defp table_control_shape(%{"rows" => 1, "cols" => 1}), do: "single_cell_control"
  defp table_control_shape(_table), do: "grid_control"

  defp positional_hwp_sections(sections) do
    Enum.map(sections, fn section ->
      %{
        "sec" => section["idx"] || 0,
        "paragraphs" => length(section["paragraphs"] || [])
      }
    end)
  end

  defp table_index_counts(tables) do
    count =
      Enum.reduce(tables, 0, fn table, acc ->
        acc + table_cell_count(table)
      end)

    {tables, count}
  end

  defp table_cell_count(%{"cells" => cells}) when is_integer(cells), do: cells
  defp table_cell_count(%{"cell_refs" => cells}) when is_list(cells), do: length(cells)

  defp table_cell_count(%{"rows" => rows, "cols" => cols})
       when is_integer(rows) and is_integer(cols),
       do: rows * cols

  defp table_cell_count(_table), do: 0

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
            |> maybe_put_tables(p)
          end)
      }
    end)
  end

  defp normalize_sections(_), do: []

  defp normalize_positional_index(%{} = index) do
    paragraphs = normalize_positional_paragraph_refs(map_value(index, "paragraphs") || [])
    tables = normalize_positional_table_refs(map_value(index, "tables") || [])

    %{"paragraphs" => paragraphs, "tables" => tables}
  end

  defp normalize_positional_index(_), do: nil

  defp normalize_positional_paragraph_refs(refs) when is_list(refs) do
    refs
    |> Enum.map(&normalize_positional_paragraph_ref/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_positional_paragraph_refs(_), do: []

  defp normalize_positional_paragraph_ref(ref) when is_map(ref) do
    with sec when is_integer(sec) <- int_value(ref, "sec"),
         para when is_integer(para) <- int_value(ref, "para"),
         page when is_integer(page) <- int_value(ref, "page") do
      %{"page" => page, "sec" => sec, "para" => para}
      |> maybe_put("off_start", int_value(ref, "off_start"))
      |> maybe_put("off_end", int_value(ref, "off_end"))
    else
      _ -> nil
    end
  end

  defp normalize_positional_paragraph_ref(_), do: nil

  defp normalize_positional_table_refs(refs) when is_list(refs) do
    refs
    |> Enum.map(&normalize_positional_table_ref/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_positional_table_refs(_), do: []

  defp normalize_positional_table_ref(ref) when is_map(ref) do
    with sec when is_integer(sec) <- int_value(ref, "sec"),
         para when is_integer(para) <- int_value(ref, "para"),
         page when is_integer(page) <- int_value(ref, "page") do
      rows = int_value(ref, "rows") || 0
      cols = int_value(ref, "cols") || 0
      raw_cells = map_value(ref, "cell_refs") || map_value(ref, "cells")
      cells = normalize_positional_table_cells(raw_cells || [])
      cell_count = if is_integer(raw_cells), do: raw_cells, else: length(cells)

      %{
        "sec" => sec,
        "para" => para,
        "page" => page,
        "control_index" => int_value(ref, "control_index") || int_value(ref, "control_idx") || 0,
        "rows" => rows,
        "cols" => cols,
        "cells" => cell_count,
        "hwp_shape" => table_control_shape(%{"rows" => rows, "cols" => cols})
      }
      |> maybe_put("cell_refs", cells)
      |> maybe_put("native_shape", map_value(ref, "hwp_shape"))
    else
      _ -> nil
    end
  end

  defp normalize_positional_table_ref(_), do: nil

  defp normalize_positional_table_cells(cells) when is_list(cells) do
    cells
    |> Enum.map(&normalize_positional_table_cell/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_positional_table_cells(_), do: []

  defp normalize_positional_table_cell(cell) when is_map(cell) do
    with cell_index when is_integer(cell_index) <-
           int_value(cell, "cell_index") || int_value(cell, "cell_idx"),
         row when is_integer(row) <- int_value(cell, "row"),
         col when is_integer(col) <- int_value(cell, "col") do
      %{
        "cell_index" => cell_index,
        "row" => row,
        "col" => col,
        "row_span" => int_value(cell, "row_span") || 1,
        "col_span" => int_value(cell, "col_span") || 1
      }
      |> maybe_put("page", int_value(cell, "page"))
      |> maybe_put("bbox", map_value(cell, "bbox"))
    else
      _ -> nil
    end
  end

  defp normalize_positional_table_cell(_), do: nil

  defp pages_from_positional_index(paragraph_refs, table_refs) do
    pages =
      (Enum.map(paragraph_refs, & &1["page"]) ++ Enum.map(table_refs, & &1["page"]))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(pages, fn page ->
      %{
        "page" => page,
        "paragraph_refs" => Enum.filter(paragraph_refs, &(&1["page"] == page))
      }
    end)
  end

  defp normalize_pages(pages) when is_list(pages) do
    pages
    |> Enum.with_index()
    |> Enum.map(fn {page, default_idx} ->
      page_number = map_value(page, "page") || map_value(page, "idx") || default_idx + 1

      %{
        "page" => page_number,
        "paragraph_refs" =>
          page
          |> map_value("paragraph_refs")
          |> List.wrap()
          |> Enum.map(&normalize_paragraph_ref(&1, page_number))
          |> Enum.reject(&is_nil/1)
      }
    end)
  end

  defp normalize_pages(_), do: []

  defp normalize_paragraph_ref(ref, page_number) when is_map(ref) do
    with sec when is_integer(sec) <- map_value(ref, "sec"),
         para when is_integer(para) <- map_value(ref, "para") do
      %{"page" => page_number, "sec" => sec, "para" => para}
    else
      _ -> nil
    end
  end

  defp normalize_paragraph_ref(_ref, _page_number), do: nil

  defp page_paragraph_refs(pages) do
    pages
    |> Enum.flat_map(fn page -> Map.get(page, "paragraph_refs", []) end)
  end

  defp paragraph_page_lookup(paragraph_refs) do
    Map.new(paragraph_refs, fn ref -> {{ref["sec"], ref["para"]}, ref["page"]} end)
  end

  defp maybe_put_kind(paragraph, %{"kind" => kind}) when is_binary(kind),
    do: Map.put(paragraph, "kind", kind)

  defp maybe_put_kind(paragraph, _), do: paragraph

  defp maybe_put_tables(paragraph, %{"tables" => tables}) when is_list(tables),
    do: Map.put(paragraph, "tables", normalize_tables(tables))

  defp maybe_put_tables(paragraph, _), do: paragraph

  defp normalize_tables(tables) do
    Enum.map(tables || [], fn table ->
      %{
        "control_idx" => map_value(table, "control_idx") || map_value(table, "controlIndex") || 0,
        "rows" => map_value(table, "rows") || 0,
        "cols" => map_value(table, "cols") || 0,
        "cells" => normalize_cells(map_value(table, "cells") || [])
      }
    end)
  end

  defp normalize_cells(cells) do
    Enum.map(cells || [], fn cell ->
      %{
        "row" => map_value(cell, "row") || 0,
        "col" => map_value(cell, "col") || 0,
        "cell_idx" => map_value(cell, "cell_idx") || map_value(cell, "cellIndex") || 0,
        "paragraphs" => normalize_cell_paragraphs(map_value(cell, "paragraphs") || [])
      }
    end)
  end

  defp normalize_cell_paragraphs(paragraphs) do
    paragraphs
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {paragraph, default_idx} ->
      %{
        "idx" => map_value(paragraph, "idx") || default_idx,
        "text" => map_value(paragraph, "text") || ""
      }
    end)
  end

  defp paragraph_tables(sec, para, %{"tables" => tables}) do
    Enum.map(tables || [], fn table ->
      control_index = map_value(table, "control_idx") || 0

      %{
        "control_index" => control_index,
        "rows" => map_value(table, "rows") || 0,
        "cols" => map_value(table, "cols") || 0,
        "cells" => paragraph_table_cells(sec, para, table)
      }
    end)
  end

  defp paragraph_tables(_sec, _para, _), do: []

  defp paragraph_table_cells(sec, para, %{"tables" => _tables} = paragraph) do
    paragraph_tables(sec, para, paragraph)
    |> Enum.flat_map(&Map.get(&1, "cells", []))
  end

  defp paragraph_table_cells(sec, para, table) do
    control_index = map_value(table, "control_idx") || 0

    for cell <- map_value(table, "cells") || [],
        cell_paragraph <- map_value(cell, "paragraphs") || [] do
      cell_index = map_value(cell, "cell_idx") || 0
      cell_para_index = map_value(cell_paragraph, "idx") || 0
      text = map_value(cell_paragraph, "text") || ""

      cell_path = [
        %{
          "controlIndex" => control_index,
          "cellIndex" => cell_index,
          "cellParaIndex" => cell_para_index
        }
      ]

      %{
        "control_index" => control_index,
        "row" => map_value(cell, "row") || 0,
        "col" => map_value(cell, "col") || 0,
        "cell_index" => cell_index,
        "cell_para_index" => cell_para_index,
        "text" => text,
        "cell_path" => cell_path,
        "target" => %{
          "type" => "cell",
          "sec" => sec,
          "para" => para,
          "off" => 0,
          "match" => text,
          "cell_path" => cell_path
        }
      }
    end
  end

  defp overlay_post_snapshot_text(ir, document_id, snapshot_revision) do
    document_id
    |> post_snapshot_text_ops(snapshot_revision || 0)
    |> then(&overlay_text_ops(ir, &1))
  end

  defp post_snapshot_text_ops(document_id, snapshot_revision) do
    text_ops_after(document_id, snapshot_revision || 0)
  end

  defp text_ops_after(document_id, snapshot_revision) do
    text_command_kinds = @text_command_kinds

    Repo.all(
      from c in Change,
        where:
          c.document_id == ^document_id and c.command_kind in ^text_command_kinds and
            c.result_revision > ^snapshot_revision,
        order_by: [asc: c.result_revision, asc: c.inserted_at, asc: c.id]
    )
    |> changes_to_text_ops()
  end

  defp text_ops_between(document_id, after_revision, through_revision)
       when is_binary(document_id) and is_integer(after_revision) and is_integer(through_revision) do
    text_command_kinds = @text_command_kinds

    Repo.all(
      from c in Change,
        where:
          c.document_id == ^document_id and c.command_kind in ^text_command_kinds and
            c.result_revision > ^after_revision and c.result_revision <= ^through_revision,
        order_by: [asc: c.result_revision, asc: c.inserted_at, asc: c.id]
    )
    |> changes_to_text_ops()
  end

  defp text_ops_between(_document_id, _after_revision, _through_revision), do: []

  defp text_op_keys(ops) when is_list(ops) do
    ops
    |> Enum.map(&text_op_key/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp text_op_keys(_ops), do: MapSet.new()

  defp text_op_key(op) when is_map(op) do
    sec = int_value(op, "sec")
    para = int_value(op, "para")

    case map_value(op, "cell_path") do
      [_ | _] = cell_path ->
        with %{} = step <- List.last(cell_path),
             control_index when is_integer(control_index) <-
               map_value(step, "controlIndex") || map_value(step, "control_index"),
             cell_index when is_integer(cell_index) <-
               map_value(step, "cellIndex") || map_value(step, "cell_index"),
             cell_para_index when is_integer(cell_para_index) <-
               map_value(step, "cellParaIndex") || map_value(step, "cell_para_index"),
             true <- is_integer(sec) and is_integer(para) do
          {:cell, sec, para, control_index, cell_index, cell_para_index}
        else
          _ -> nil
        end

      _ ->
        if is_integer(sec) and is_integer(para), do: {sec, para}, else: nil
    end
  end

  defp text_op_key(_op), do: nil

  defp changes_to_text_ops(changes) do
    changes
    |> Enum.flat_map(fn %Change{payload: payload} -> payload || [] end)
    |> Enum.flat_map(&normalize_text_op/1)
  end

  defp overlay_text_ops(ir, ops) do
    ops
    |> Enum.reduce(ir, fn op, acc -> apply_text_op(acc, op) end)
    |> refresh_field_values()
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

      "insert_paragraph" ->
        with sec when is_integer(sec) <- int_value(args, "sec"),
             para when is_integer(para) <- int_value(args, "para"),
             off when is_integer(off) <- int_value(args, "off") do
          [
            %{
              kind: "insert_paragraph",
              sec: sec,
              para: para,
              off: off,
              cell_path: map_value(args, "cell_path")
            }
          ]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp normalize_text_op(_), do: []

  defp apply_text_op(ir, %{kind: "insert_paragraph", cell_path: cell_path} = op)
       when cell_path in [nil, []] do
    ir
    |> Map.update("sections", [], &apply_insert_paragraph_to_sections(&1, op))
    |> Map.update("fields", [], &apply_insert_paragraph_to_fields(&1, op))
  end

  defp apply_text_op(ir, %{sec: sec, para: para, off: off} = op)
       when is_integer(sec) and is_integer(para) and is_integer(off) do
    ir
    |> Map.update("sections", [], &apply_text_op_to_sections(&1, op))
    |> Map.update("fields", [], &apply_text_op_to_fields(&1, op))
  end

  defp apply_text_op(ir, _op), do: ir

  defp apply_insert_paragraph_to_sections(sections, op) do
    Enum.map(sections || [], fn section ->
      if map_value(section, "idx") == op.sec do
        Map.update(section, "paragraphs", [], &split_paragraphs(&1, op))
      else
        section
      end
    end)
  end

  defp split_paragraphs(paragraphs, %{para: para, off: off}) do
    Enum.flat_map(paragraphs || [], fn paragraph ->
      idx = map_value(paragraph, "idx")

      cond do
        idx == para and is_binary(map_value(paragraph, "text")) ->
          text = map_value(paragraph, "text")
          off = clamp(off, 0, String.length(text))
          head = String.slice(text, 0, off)
          tail = String.slice(text, off, String.length(text) - off)

          [
            Map.put(paragraph, "text", head),
            paragraph
            |> Map.put("idx", para + 1)
            |> Map.put("text", tail)
            |> Map.drop(["tables"])
          ]

        is_integer(idx) and idx > para ->
          [Map.put(paragraph, "idx", idx + 1)]

        true ->
          [paragraph]
      end
    end)
  end

  defp apply_text_op_to_sections(sections, op) do
    Enum.map(sections || [], fn section ->
      if map_value(section, "idx") == op.sec do
        Map.update(section, "paragraphs", [], fn paragraphs ->
          Enum.map(paragraphs || [], fn paragraph ->
            apply_text_op_to_paragraph(paragraph, op)
          end)
        end)
      else
        section
      end
    end)
  end

  defp apply_text_op_to_paragraph(paragraph, %{cell_path: [_ | _]} = op) do
    if map_value(paragraph, "idx") == op.para do
      Map.update(paragraph, "tables", [], &apply_text_op_to_tables(&1, op))
    else
      paragraph
    end
  end

  defp apply_text_op_to_paragraph(paragraph, op) do
    if map_value(paragraph, "idx") == op.para and is_binary(map_value(paragraph, "text")) do
      Map.put(paragraph, "text", apply_text_to_string(map_value(paragraph, "text"), op))
    else
      paragraph
    end
  end

  defp apply_text_op_to_tables(tables, op) do
    Enum.map(tables || [], fn table ->
      Map.update(table, "cells", [], &apply_text_op_to_cells(&1, table, op))
    end)
  end

  defp apply_text_op_to_cells(cells, table, op) do
    Enum.map(cells || [], fn cell ->
      Map.update(cell, "paragraphs", [], fn paragraphs ->
        Enum.map(paragraphs || [], fn cell_paragraph ->
          if cell_path_matches?(op.cell_path, table, cell, cell_paragraph) do
            Map.put(
              cell_paragraph,
              "text",
              apply_text_to_string(map_value(cell_paragraph, "text") || "", op)
            )
          else
            cell_paragraph
          end
        end)
      end)
    end)
  end

  defp cell_path_matches?(cell_path, table, cell, cell_paragraph) do
    with [_ | _] <- cell_path,
         %{} = step <- List.last(cell_path) do
      (map_value(step, "controlIndex") || map_value(step, "control_index")) ==
        (map_value(table, "control_idx") || 0) and
        (map_value(step, "cellIndex") || map_value(step, "cell_index")) ==
          (map_value(cell, "cell_idx") || 0) and
        (map_value(step, "cellParaIndex") || map_value(step, "cell_para_index")) ==
          (map_value(cell_paragraph, "idx") || 0)
    else
      _ -> false
    end
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

  defp apply_insert_paragraph_to_fields(fields, op) do
    Enum.map(fields || [], &apply_insert_paragraph_to_field(&1, op))
  end

  defp apply_insert_paragraph_to_field(field, %{cell_path: [_ | _]}), do: field

  defp apply_insert_paragraph_to_field(field, op) when is_map(field) do
    pos = map_value(field, "position") || %{}

    if map_value(pos, "cell_path") in [nil, []] and map_value(pos, "sec") == op.sec do
      shift_field_for_paragraph_insert(field, pos, op)
    else
      field
    end
  end

  defp apply_insert_paragraph_to_field(field, _op), do: field

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

  defp shift_field_for_paragraph_insert(field, pos, %{para: para, off: off}) do
    field_para = map_value(pos, "para")
    start_off = map_value(pos, "off_start") || 0
    end_off = map_value(pos, "off_end") || start_off

    cond do
      is_integer(field_para) and field_para > para ->
        pos = Map.put(pos, "para", field_para + 1)
        Map.put(field, "position", pos)

      field_para == para and start_off >= off ->
        pos =
          pos
          |> Map.put("para", para + 1)
          |> Map.put("off_start", max(start_off - off, 0))
          |> Map.put("off_end", max(end_off - off, 0))

        Map.put(field, "position", pos)

      true ->
        field
    end
  end

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

  defp body_text_index(%{"sections" => sections}) when is_list(sections) do
    Map.new(
      for section <- sections,
          paragraph <- map_value(section, "paragraphs") || [],
          sec = map_value(section, "idx"),
          para = map_value(paragraph, "idx"),
          is_integer(sec) and is_integer(para) do
        {{sec, para}, map_value(paragraph, "text") || ""}
      end
    )
  end

  defp body_text_index(_ir), do: %{}

  defp document_text_index(%{"sections" => sections}) when is_list(sections) do
    Map.merge(body_text_index(%{"sections" => sections}), cell_text_index(sections))
  end

  defp document_text_index(_ir), do: %{}

  defp cell_text_index(sections) do
    Map.new(
      for section <- sections || [],
          paragraph <- map_value(section, "paragraphs") || [],
          table <- map_value(paragraph, "tables") || [],
          cell <- map_value(table, "cells") || [],
          cell_paragraph <- map_value(cell, "paragraphs") || [],
          sec = map_value(section, "idx"),
          para = map_value(paragraph, "idx"),
          control_index = map_value(table, "control_idx") || 0,
          cell_index = map_value(cell, "cell_idx") || 0,
          cell_para_index = map_value(cell_paragraph, "idx") || 0,
          is_integer(sec) and is_integer(para) and is_integer(control_index) and
            is_integer(cell_index) and is_integer(cell_para_index) do
        {{:cell, sec, para, control_index, cell_index, cell_para_index},
         map_value(cell_paragraph, "text") || ""}
      end
    )
  end

  defp field_text(sections, pos, field) when is_map(pos) do
    with true <- map_value(pos, "cell_path") in [nil, []],
         sec when is_integer(sec) <- map_value(pos, "sec"),
         para when is_integer(para) <- map_value(pos, "para"),
         start_off when is_integer(start_off) <- map_value(pos, "off_start"),
         end_off when is_integer(end_off) <- map_value(pos, "off_end"),
         text when is_binary(text) <- paragraph_text_from_sections(sections, sec, para) do
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

  defp paragraph_text_from_sections(sections, sec, para) do
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
end
