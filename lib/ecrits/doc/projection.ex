defmodule Ecrits.Doc.Projection do
  @moduledoc """
  Deterministic, grep-able UTF-8 JSONL projection of an on-disk document.

  This is the JSONL projection of the exfuse doc-VFS migration
  (`docs/plans/2026-06-23-exfuse-doc-vfs-migration.md`, Layer 3 / Phase 1). It
  renders a WHOLE document — HWP/HWPX/docx/pptx/xlsx — to a single stable byte
  blob that a FUSE filesystem serves as `<name>.jsonl`, so a human (or the agent,
  whose cwd is the workspace root) can `cat`/`rg` the document's text without an
  MCP round-trip.

  ## How the bytes are produced

  The projection goes through the REAL server-side doc layer, never a bespoke
  parser:

    1. `Ecrits.Doc.Pool.open/2` loads the document into the pool, inferring the
       backend `kind:` from the file extension. `open/2` is idempotent — a doc
       the workspace is already viewing is reused, not reopened — so projection
       NEVER disposes the doc afterwards (lifecycle is the FUSE/Session layer's
       job, not ours).
    2. `Ecrits.Doc.Editor.elements/2` returns the FULL document IR (not the
       30-paragraph `doc.read` window). Each IR node is a map carrying at least
       `"ref"`, `"type"`, and (for text-bearing leaves) `"text"`, in document
       order.
    3. `render_elements/1` serializes the FULL IR as one JSONL value in this
       nested list shape: `[section[paragraph[payload_node]]]`. Positional HWPX
       refs are not written into payload objects; the section/paragraph/payload
       list positions are the compact address. The mounted `.jsonl` therefore
       shows the editable payload IR (types, text, table/cell/picture/structural
       nodes, empty nodes) without fixed positional ref fields like
       `{"ref":[0,385,0]}`. Rich non-positional refs are kept only when removing
       them would discard semantic addressing. `project_file/2` returns ONLY the
       bytes; the index is internal.

  Write-back diffs the edited JSONL against the live IR node-by-node. For
  positional payloads with no `"ref"` field, the nested list position is the
  stable identity and the live old node supplies the hidden backend ref; legacy
  buffers that still include `"ref"` must keep it unchanged. A changed `"text"`
  becomes a direct text edit on that node's model, and changed node fields become
  backend property writes. A newly inserted payload node shaped like
  `%{"type" => "table", "cells" => [[...]], "header" => true}` becomes a native
  table insertion. A newly inserted picture payload shaped like
  `%{"type" => "picture", "src" => "/path/image.png"}` becomes native picture
  insertion with a readable default size derived from the image aspect;
  `"width"`/`"height"` are only needed for intentional HWPUNIT resizing. Extra
  positional fields such as `"x"`/`"y"` or `"PosX"`/`"PosY"` are only applied on
  creation when the new payload explicitly sets `"treatAsChar": false`;
  otherwise a new picture stays inline at its nested-list position. Removing an
  existing picture payload deletes that picture control. Other add/remove/reorder
  edits remain structural changes. So editing the mounted IR IS editing the
  document.

  Determinism: the blob carries no timestamps and no random ordering — the same
  document content always projects to the same bytes (the basis of
  `fingerprint/1`).
  """

  alias Ecrits.Doc.Editor
  alias Ecrits.Doc.Pool
  alias Ecrits.Fuse.DocMount

  @typedoc "A byte offset range `{start, length}` into the projected blob."
  @type byte_range :: {non_neg_integer(), non_neg_integer()}

  @typedoc "An internal line-index entry: where a JSONL record lives + its source ref, if any."
  @type line_index_entry :: {byte_range(), Ecrits.Doc.ref() | nil}

  @typedoc "The internal full projection (only `:bytes` is exposed publicly today)."
  @type projection :: %{
          bytes: binary(),
          line_index: [line_index_entry()],
          fingerprint: term()
        }

  @supported_exts ~w(.hwp .hwpx .docx .pptx .xlsx)

  @doc "The file extensions this projection can render (downcased, with the dot)."
  @spec supported_exts() :: [String.t()]
  def supported_exts, do: @supported_exts

  @doc """
  Whether `path` names a document this projection supports, by extension
  (case-insensitive).
  """
  @spec supported?(String.t()) :: boolean()
  def supported?(path) when is_binary(path) do
    path |> Path.extname() |> String.downcase() |> Kernel.in(@supported_exts)
  end

  def supported?(_path), do: false

  @doc """
  The projected filename for a source `name`: append `".jsonl"`.

      iex> Ecrits.Doc.Projection.projected_name("report.hwp")
      "report.hwp.jsonl"
  """
  @spec projected_name(String.t()) :: String.t()
  def projected_name(name) when is_binary(name), do: name <> ".jsonl"

  @doc """
  Recover the source basename from a projected name by stripping the trailing
  `".jsonl"`. Returns `nil` when `proj_name` does not end in `".jsonl"` (so a non-
  projection file in the mount is not mistaken for a source document).

      iex> Ecrits.Doc.Projection.source_basename("report.hwp.jsonl")
      "report.hwp"
      iex> Ecrits.Doc.Projection.source_basename("notes.txt")
      nil
  """
  @spec source_basename(String.t()) :: String.t() | nil
  def source_basename(proj_name) when is_binary(proj_name) do
    if String.ends_with?(proj_name, ".jsonl") do
      String.replace_suffix(proj_name, ".jsonl", "")
    else
      nil
    end
  end

  def source_basename(_proj_name), do: nil

  @doc """
  Render the document at absolute `abs_path` to its deterministic UTF-8 blob.

  Opens the document through `Ecrits.Doc.Pool` (kind inferred from the
  extension) and reads its full IR via `Ecrits.Doc.Editor.elements/2`. Returns
  `{:ok, bytes}` on success, or `{:error, reason}` for an unsupported extension,
  an open/parse failure, or a backend (NIF/UNO) error. Never raises.

  `opts` is reserved for future projection knobs and is currently ignored.
  """
  @spec project_file(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def project_file(abs_path, opts \\ [])

  def project_file(abs_path, opts) when is_binary(abs_path) and is_list(opts) do
    abs_path = canonical_file_path(abs_path)

    case build_projection(abs_path) do
      {:ok, projection} ->
        {:ok, projection.bytes}

      {:error, reason} = error ->
        if poisoned_document_reason?(reason) do
          _ = Pool.close_by_path(abs_path)

          with {:ok, projection} <- build_projection(abs_path) do
            {:ok, projection.bytes}
          end
        else
          error
        end
    end
  rescue
    error -> {:error, {:projection_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def project_file(_abs_path, _opts), do: {:error, :invalid_path}

  @doc """
  A stable fingerprint of the document's projected content: it changes iff the
  projection bytes change.

  Returns `{:ok, term}` (a `:erlang.phash2/1` of the bytes — the cheapest
  correct option, since the Editor/Pool expose no independent IR fingerprint)
  or `{:error, reason}` when the document cannot be projected. Used for the FUSE
  `getattr` size/mtime signal.
  """
  @spec fingerprint(String.t()) :: {:ok, term()} | {:error, term()}
  def fingerprint(abs_path) when is_binary(abs_path) do
    case project_file(abs_path) do
      {:ok, bytes} -> {:ok, :erlang.phash2(bytes)}
      {:error, _reason} = error -> error
    end
  end

  def fingerprint(_abs_path), do: {:error, :invalid_path}

  @doc """
  A small post-edit excerpt of the document at `abs_path`, for surfacing WHERE
  an edit landed (the chat-rail doc-edit card).

  Projects the document (reflecting the live, possibly-unsaved Editor), drops the
  structural `#! <type>` annotation lines, and returns a `:context`-line window
  around the first text line that contains `:marker` (the edit's inserted/
  replaced text). Returns `{:ok, %{found?: boolean, rows: [%{text, hit?}]}}` —
  `hit?` flags the edited line. `found?` is false (rows empty) when the marker is
  absent (e.g. a pure deletion) or the doc cannot be projected. Never raises.
  """
  @spec edit_excerpt(String.t(), keyword()) ::
          {:ok, %{found?: boolean(), rows: [%{text: String.t(), hit?: boolean()}]}}
  def edit_excerpt(abs_path, opts \\ []) do
    marker = opts |> Keyword.get(:marker) |> normalize_marker()
    context = Keyword.get(opts, :context, 3)

    with marker when is_binary(marker) <- marker,
         {:ok, bytes} <- project_file(abs_path) do
      # The projection is nested IR JSONL; show the nodes' TEXT (not raw JSON),
      # drop empty/structural nodes, and collapse the paragraph+run duplicate.
      texts =
        case parse_ir_jsonl(bytes) do
          {:ok, nodes} -> nodes
          _ -> []
        end
        |> Enum.map(fn node -> node |> normalize_ir_value() |> Map.get("text") end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.dedup()

      case Enum.find_index(texts, &String.contains?(&1, marker)) do
        nil ->
          {:ok, %{found?: false, rows: []}}

        i ->
          lo = max(i - context, 0)
          hi = min(i + context, length(texts) - 1)
          rows = for n <- lo..hi, do: %{text: Enum.at(texts, n), hit?: n == i}
          {:ok, %{found?: true, rows: rows}}
      end
    else
      _ -> {:ok, %{found?: false, rows: []}}
    end
  rescue
    _ -> {:ok, %{found?: false, rows: []}}
  end

  # The inserted text may be multi-paragraph (insert_text with "\n" splits into
  # paragraphs, each its own projected line), so match on the FIRST non-empty
  # line of the marker.
  defp normalize_marker(m) when is_binary(m) do
    m |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.find(&(&1 != ""))
  end

  defp normalize_marker(_), do: nil

  # --- internal projection build -------------------------------------------

  # Open the doc (idempotent) and run the full-IR render against its Editor.
  # Factored out of `project_file/2` so a future `Writeback` can reuse the same
  # open+render path and recover the `line_index` (which `project_file/2` drops).
  @spec build_projection(String.t()) :: {:ok, projection()} | {:error, term()}
  defp build_projection(abs_path) do
    abs_path = canonical_file_path(abs_path)

    with {:ok, kind} <- kind_for(abs_path),
         {:ok, document_id} <- Pool.open(abs_path, kind: kind),
         {:ok, nodes} <- elements(document_id) do
      {:ok, render_elements(nodes)}
    end
  end

  # Resolve the Pool/backend `kind` from the file extension. Mirrors
  # `Ecrits.Doc.backend_for/1`'s accepted kinds; an unsupported extension is a
  # clean `{:error, {:unsupported, ext}}` rather than a guessed default.
  @spec kind_for(String.t()) :: {:ok, Ecrits.Doc.kind()} | {:error, {:unsupported, String.t()}}
  defp kind_for(abs_path) do
    case abs_path |> Path.extname() |> String.downcase() do
      ".hwp" -> {:ok, :hwp}
      ".hwpx" -> {:ok, :hwpx}
      ".docx" -> {:ok, :docx}
      ".pptx" -> {:ok, :pptx}
      ".xlsx" -> {:ok, :xlsx}
      other -> {:error, {:unsupported, other}}
    end
  end

  defp canonical_file_path(path) when is_binary(path) do
    path = Path.expand(path)
    Path.join(DocMount.canonical_root(Path.dirname(path)), Path.basename(path))
  end

  defp poisoned_document_reason?(reason) do
    text = inspect(reason)

    String.contains?(text, "lock_failed") or
      String.contains?(text, "mutex poisoned") or
      String.contains?(text, "nif_panicked")
  end

  # Run `Editor.elements/2` against the open doc's Editor, serialized through the
  # Pool. `with_doc/2` returns `{:error, :not_found}` if the Editor vanished
  # between open and read; otherwise it returns the Editor's reply verbatim.
  @spec elements(Pool.document_id()) :: {:ok, [map()]} | {:error, term()}
  defp elements(document_id) do
    Pool.with_doc(document_id, fn editor -> Editor.elements(editor) end)
  end

  # --- IR -> deterministic blob + line index -------------------------------

  # Serialize the FULL document IR as one JSONL value:
  #
  #   [
  #     [ [payload_node, payload_node], [payload_node] ],
  #     [ [payload_node] ]
  #   ]
  #
  # The list nesting is the editable ordering surface:
  # sections -> paragraphs -> payload nodes.
  # Positional node refs are omitted from payload JSON entirely: the nested list
  # position is the address. Write-back zips the edited payload at that position
  # against the current live IR and uses the live node's hidden backend ref.
  # Rich/non-positional refs are kept because they carry semantic addressing.
  # Byte-stable (keys sorted recursively) so the same IR always yields the same
  # bytes.
  @spec render_elements([map()]) :: projection()
  defp render_elements(nodes) do
    line =
      nodes
      |> nested_payloads()
      |> encode_ir_node()
      |> Kernel.<>("\n")

    bytes = IO.iodata_to_binary(line)

    %{
      bytes: bytes,
      line_index: [{{0, byte_size(bytes)}, nil}],
      fingerprint: :erlang.phash2(bytes)
    }
  end

  # Deterministic JSON for one JSONL value: keys sorted recursively (via
  # `Jason.OrderedObject`) so identical IR always serializes to identical bytes
  # (the fingerprint and the write-back round-trip both rely on this). Jason
  # escapes embedded newlines, so a node always occupies exactly one line.
  defp encode_ir_node(node), do: node |> deep_order() |> Jason.encode!()

  defp nested_payloads(nodes) do
    payload_entries =
      nodes
      |> Enum.with_index()
      |> Enum.map(fn {node, fallback_index} ->
        {section_id, paragraph_id} = node_position(node, fallback_index)
        %{section_id: section_id, paragraph_id: paragraph_id, node: node}
      end)

    section_ids =
      payload_entries
      |> Enum.map(& &1.section_id)
      |> uniq_preserving_order()

    Enum.map(section_ids, fn section_id ->
      section_payloads = Enum.filter(payload_entries, &(&1.section_id == section_id))

      section_payloads
      |> Enum.map(& &1.paragraph_id)
      |> uniq_preserving_order()
      |> Enum.map(fn paragraph_id ->
        section_payloads
        |> Enum.filter(&(&1.paragraph_id == paragraph_id))
        |> Enum.map(fn entry -> projected_node(entry.node) end)
      end)
    end)
  end

  defp uniq_preserving_order(values) do
    values
    |> Enum.reduce({[], MapSet.new()}, fn value, {acc, seen} ->
      if MapSet.member?(seen, value) do
        {acc, seen}
      else
        {[value | acc], MapSet.put(seen, value)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp projected_node(node) do
    node = normalize_ir_value(node)
    type = Map.get(node, "type")

    case compact_positional_ref(Map.get(node, "ref"), type) do
      nil -> node
      _positional_ref -> Map.delete(node, "ref")
    end
  end

  # HWPX element refs often carry only monotonically increasing positional
  # indexes. The mounted nested list already carries those positions, so these
  # refs are omitted from payload JSON; keep richer refs as maps so no semantic
  # addressing fields disappear.
  defp compact_positional_ref(%{"cell" => %{} = cell} = ref, _type) do
    with section when is_integer(section) <- Map.get(ref, "section", 0),
         parent_para when is_integer(parent_para) <-
           Map.get(cell, "parentParaIndex", Map.get(ref, "paragraph")),
         control when is_integer(control) <- Map.get(cell, "controlIndex"),
         cell_index when is_integer(cell_index) <- Map.get(cell, "cellIndex"),
         cell_para when is_integer(cell_para) <- Map.get(cell, "cellParaIndex"),
         offset when is_integer(offset) <- Map.get(ref, "offset", 0) do
      [section, parent_para, control, cell_index, cell_para, offset]
    else
      _ -> nil
    end
  end

  defp compact_positional_ref(%{} = ref, type) when type not in [nil, "", "paragraph"] do
    allowed = MapSet.new(["section", "paragraph", "control", "type"])

    with true <- ref_keys_subset?(ref, allowed),
         section when is_integer(section) <- Map.get(ref, "section", 0),
         paragraph when is_integer(paragraph) <- Map.get(ref, "paragraph"),
         control when is_integer(control) <- Map.get(ref, "control") do
      [section, paragraph, control]
    else
      _ -> nil
    end
  end

  defp compact_positional_ref(%{} = ref, _type) do
    allowed = MapSet.new(["section", "paragraph", "offset", "length"])

    with true <- ref_keys_subset?(ref, allowed),
         section when is_integer(section) <- Map.get(ref, "section", 0),
         paragraph when is_integer(paragraph) <- Map.get(ref, "paragraph"),
         offset when is_integer(offset) <- Map.get(ref, "offset", 0) do
      case Map.get(ref, "length") do
        length when is_integer(length) -> [section, paragraph, offset, length]
        nil -> [section, paragraph, offset]
        _other -> nil
      end
    else
      _ -> compact_section_ref(ref)
    end
  end

  defp compact_positional_ref(_ref, _type), do: nil

  defp compact_section_ref(ref) do
    allowed = MapSet.new(["section"])

    with true <- ref_keys_subset?(ref, allowed),
         section when is_integer(section) <- Map.get(ref, "section") do
      [section]
    else
      _ -> nil
    end
  end

  defp ref_keys_subset?(ref, allowed) do
    ref
    |> Map.keys()
    |> Enum.all?(&MapSet.member?(allowed, &1))
  end

  defp node_position(node, fallback_index) do
    ref =
      node
      |> node_field("ref")
      |> normalize_ir_value()

    cond do
      is_map(ref) ->
        section_id = integer_ref_field(ref, "section") || 0

        paragraph_id =
          integer_ref_field(ref, "paragraph") ||
            nested_integer_ref(ref, ["cell", "parentParaIndex"])

        {section_id, paragraph_id || fallback_index}

      true ->
        {0, fallback_index}
    end
  end

  defp integer_ref_field(ref, key) do
    case Map.get(ref, key) do
      value when is_integer(value) -> value
      _other -> nil
    end
  end

  defp nested_integer_ref(ref, path) do
    case get_in(ref, path) do
      value when is_integer(value) -> value
      _other -> nil
    end
  end

  defp deep_order(%{} = map) do
    map
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {to_string(k), deep_order(v)} end)
    |> Jason.OrderedObject.new()
  end

  defp deep_order(list) when is_list(list), do: Enum.map(list, &deep_order/1)
  defp deep_order(other), do: other

  # --- write-back: edited IR JSONL -> direct edits on the live doc ------------

  @doc """
  Apply a direct overwrite of the projected `.jsonl` back onto the live document
  at `abs_path` (FUSE write-back / Phase 2). Diffs the incoming `new_bytes`
  against the current projection's reconstructed payload nodes and applies
  changed fields directly to the mounted server editor: paragraph `"text"`
  changes become scoped text edits, cell `"text"` changes become whole-cell
  `set_cell` writes, a newly inserted `%{"type" => "table", "cells" => ...}`
  payload becomes native `insert_table`, and other node-field changes become
  native property writes.
  This is not the MCP/browser `doc.edit` -> `doc.apply_edit` path; that path remains the
  semantic hook for non-FUSE editor requests and may only be used later to resync
  an already-open browser viewer.

  `opts`: `:root` (workspace root, for the edit ctx path guard).

  Returns `{:ok, %{applied: n, doc: name}}`, or `{:error, reason}` —
  `:structural_change` when the payload count/order/identity changed outside the
  supported new-table payload shape,
  `:unroutable` when a changed node has no backend ref, or an engine error. Never
  raises. On success, broadcasts `{:vfs_doc_edited, info}` on `doc_vfs:<root>` so
  the chat rail can show where the file edit landed.
  """
  @spec write_back(String.t(), binary(), keyword()) ::
          {:ok, %{applied: non_neg_integer(), doc: String.t()}} | {:error, term()}
  def write_back(abs_path, new_bytes, opts \\ [])
      when is_binary(abs_path) and is_binary(new_bytes) do
    abs_path = canonical_file_path(abs_path)

    result =
      with {:ok, old_nodes} <- ir_nodes(abs_path),
           {:ok, new_nodes} <- parse_ir_jsonl(new_bytes) do
        case compute_ir_changes(old_nodes, new_nodes) do
          {:error, reason} -> {:error, reason}
          [] -> {:ok, %{applied: 0, doc: Path.basename(abs_path)}}
          changes -> apply_changes(abs_path, changes, opts)
        end
      end

    case result do
      {:error, reason} = error ->
        if poisoned_document_reason?(reason), do: Pool.close_by_path(abs_path)
        error

      ok ->
        ok
    end
  rescue
    error ->
      _ = Pool.close_by_path(canonical_file_path(abs_path))
      {:error, {:writeback_raised, Exception.message(error)}}
  catch
    kind, reason ->
      reason = {kind, reason}
      if poisoned_document_reason?(reason), do: Pool.close_by_path(canonical_file_path(abs_path))
      {:error, reason}
  end

  # The document's current IR nodes — the OLD state write-back diffs against.
  defp ir_nodes(abs_path) do
    abs_path = canonical_file_path(abs_path)

    with {:ok, kind} <- kind_for(abs_path),
         {:ok, document_id} <- Pool.open(abs_path, kind: kind) do
      elements(document_id)
    end
  end

  # Parse the edited file back into IR nodes. Current projections are one nested
  # JSONL value (`[section[paragraph[payload_node]]]`). Old flat one-node-per-line
  # JSONL and the short-lived layered-record JSONL are still accepted so stale
  # buffers fail structurally only if their node identity actually diverges.
  defp parse_ir_jsonl(bytes) do
    bytes
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> decode_jsonl_values()
    |> case do
      {:ok, []} ->
        {:ok, []}

      {:ok, [nested]} when is_list(nested) ->
        parse_nested_projection(nested)

      {:ok, values} ->
        cond do
          Enum.all?(values, &raw_ir_node?/1) ->
            {:ok, Enum.map(values, &expand_projected_node/1)}

          Enum.all?(values, &layer_record?/1) ->
            parse_layered_records(values)

          Enum.all?(values, &is_list/1) ->
            parse_nested_projection(values)

          true ->
            {:error, :invalid_ir_jsonl}
        end

      error ->
        error
    end
  end

  defp decode_jsonl_values(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} -> {:halt, {:error, {:invalid_ir_json, String.slice(line, 0, 80)}}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp raw_ir_node?(%{"kind" => _}), do: false
  defp raw_ir_node?(%{"ref" => _, "type" => _}), do: true
  defp raw_ir_node?(_record), do: false

  defp layer_record?(%{"kind" => kind}) when kind in ["doc", "sec", "para", "payload"], do: true
  defp layer_record?(_record), do: false

  defp parse_nested_projection(sections) when is_list(sections) do
    sections
    |> Enum.reduce_while({:ok, []}, fn section, {:ok, acc} ->
      case nodes_from_nested_section(section) do
        {:ok, nodes} -> {:cont, {:ok, [nodes | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, nested_nodes} -> {:ok, nested_nodes |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp nodes_from_nested_section(section) when is_list(section) do
    section
    |> Enum.reduce_while({:ok, []}, fn paragraph, {:ok, acc} ->
      case nodes_from_nested_paragraph(paragraph) do
        {:ok, nodes} -> {:cont, {:ok, [nodes | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, nested_nodes} -> {:ok, nested_nodes |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp nodes_from_nested_section(_section), do: {:error, :invalid_section_list}

  defp nodes_from_nested_paragraph(paragraph) when is_list(paragraph) do
    paragraph
    |> Enum.reduce_while({:ok, []}, fn
      %{} = node, {:ok, acc} -> {:cont, {:ok, [expand_projected_node(node) | acc]}}
      _other, {:ok, _acc} -> {:halt, {:error, :invalid_payload_node}}
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      error -> error
    end
  end

  defp nodes_from_nested_paragraph(_paragraph), do: {:error, :invalid_paragraph_list}

  defp parse_layered_records(records) do
    with :ok <- validate_layer_records(records),
         {:ok, section_ids} <- section_order(records),
         {:ok, nodes} <- nodes_from_layers(section_ids, layer_maps(records)) do
      {:ok, nodes}
    end
  end

  defp validate_layer_records(records) do
    if Enum.all?(records, &(Map.get(&1, "kind") in ["doc", "sec", "para", "payload"])) do
      :ok
    else
      {:error, :invalid_layer_record}
    end
  end

  defp section_order(records) do
    case Enum.find(records, &(Map.get(&1, "kind") == "doc")) do
      %{"sec" => section_ids} when is_list(section_ids) ->
        {:ok, section_ids}

      nil ->
        section_ids =
          records
          |> Enum.filter(&(Map.get(&1, "kind") == "sec"))
          |> Enum.map(&Map.get(&1, "id"))
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(&sort_key/1)

        {:ok, section_ids}

      _other ->
        {:error, :invalid_doc_layer}
    end
  end

  defp layer_maps(records) do
    %{
      sec:
        records
        |> Enum.filter(&(Map.get(&1, "kind") == "sec"))
        |> Map.new(fn record -> {layer_key(Map.get(record, "id")), record} end),
      para:
        records
        |> Enum.filter(&(Map.get(&1, "kind") == "para"))
        |> Map.new(fn record ->
          {{layer_key(Map.get(record, "sec")), layer_key(Map.get(record, "id"))}, record}
        end),
      payload:
        records
        |> Enum.filter(&(Map.get(&1, "kind") == "payload"))
        |> Map.new(fn record ->
          key =
            {layer_key(Map.get(record, "sec")), layer_key(Map.get(record, "para")),
             layer_key(Map.get(record, "id"))}

          {key, record}
        end)
    }
  end

  defp nodes_from_layers(section_ids, maps) do
    section_ids
    |> Enum.reduce_while({:ok, []}, fn section_id, {:ok, acc} ->
      case Map.fetch(maps.sec, layer_key(section_id)) do
        {:ok, %{"para" => paragraph_ids}} when is_list(paragraph_ids) ->
          case nodes_from_paragraphs(section_id, paragraph_ids, maps) do
            {:ok, nodes} -> {:cont, {:ok, Enum.reverse(nodes) ++ acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:ok, _section} ->
          {:halt, {:error, :invalid_section_layer}}

        :error ->
          {:halt, {:error, :missing_section_layer}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      error -> error
    end
  end

  defp nodes_from_paragraphs(section_id, paragraph_ids, maps) do
    paragraph_ids
    |> Enum.reduce_while({:ok, []}, fn paragraph_id, {:ok, acc} ->
      key = {layer_key(section_id), layer_key(paragraph_id)}

      case Map.fetch(maps.para, key) do
        {:ok, %{"payload" => payload_ids}} when is_list(payload_ids) ->
          case nodes_from_payloads(section_id, paragraph_id, payload_ids, maps) do
            {:ok, nodes} -> {:cont, {:ok, Enum.reverse(nodes) ++ acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:ok, _paragraph} ->
          {:halt, {:error, :invalid_paragraph_layer}}

        :error ->
          {:halt, {:error, :missing_paragraph_layer}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      error -> error
    end
  end

  defp nodes_from_payloads(section_id, paragraph_id, payload_ids, maps) do
    payload_ids
    |> Enum.reduce_while({:ok, []}, fn payload_id, {:ok, acc} ->
      key = {layer_key(section_id), layer_key(paragraph_id), layer_key(payload_id)}

      case Map.fetch(maps.payload, key) do
        {:ok, %{"node" => %{} = node}} -> {:cont, {:ok, [expand_projected_node(node) | acc]}}
        {:ok, _payload} -> {:halt, {:error, :invalid_payload_layer}}
        :error -> {:halt, {:error, :missing_payload_layer}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      error -> error
    end
  end

  defp layer_key(value), do: inspect(value)

  defp sort_key(value) when is_integer(value), do: {0, value}
  defp sort_key(value) when is_float(value), do: {1, value}
  defp sort_key(value), do: {2, inspect(value)}

  defp expand_projected_node(node) do
    node = normalize_ir_value(node)
    type = Map.get(node, "type")

    case expand_positional_ref(Map.get(node, "ref"), type) do
      nil -> node
      ref -> Map.put(node, "ref", ref)
    end
  end

  defp expand_positional_ref([section], _type) when is_integer(section) do
    %{"section" => section}
  end

  defp expand_positional_ref([section, paragraph, offset], "paragraph")
       when is_integer(section) and is_integer(paragraph) and is_integer(offset) do
    %{"section" => section, "paragraph" => paragraph, "offset" => offset}
  end

  defp expand_positional_ref([section, paragraph, offset, length], "paragraph")
       when is_integer(section) and is_integer(paragraph) and is_integer(offset) and
              is_integer(length) do
    %{"section" => section, "paragraph" => paragraph, "offset" => offset, "length" => length}
  end

  defp expand_positional_ref(
         [section, parent_para, control, cell_index, cell_para, offset],
         "cell"
       )
       when is_integer(section) and is_integer(parent_para) and is_integer(control) and
              is_integer(cell_index) and is_integer(cell_para) and is_integer(offset) do
    %{
      "section" => section,
      "paragraph" => parent_para,
      "offset" => offset,
      "cell" => %{
        "parentParaIndex" => parent_para,
        "controlIndex" => control,
        "cellIndex" => cell_index,
        "cellParaIndex" => cell_para
      }
    }
  end

  defp expand_positional_ref([section, paragraph, control], type)
       when is_integer(section) and is_integer(paragraph) and is_integer(control) and
              is_binary(type) and type not in ["", "paragraph", "cell"] do
    %{"section" => section, "paragraph" => paragraph, "control" => control, "type" => type}
  end

  defp expand_positional_ref(_ref, _type), do: nil

  # Diff old vs new IR node-by-node. Nested positional projections intentionally
  # omit `"ref"` from edited payloads; in that case the payload's list position is
  # the identity and the old live node supplies the hidden backend ref. Legacy
  # projections that still include a `"ref"` must keep it unchanged.
  # `"text"` changes become edit ops; other changed fields become backend
  # property writes. Nothing is silently ignored: unsupported fields are allowed
  # to reach the backend and fail there, while identity/shape edits are a
  # structural change.
  defp compute_ir_changes(old_nodes, new_nodes) do
    case scan_ir_changes(old_nodes, new_nodes, 0, 0, []) do
      {:ok, changes} -> changes |> Enum.reverse() |> dedup_office_runs()
      {:error, reason} -> {:error, reason}
    end
  end

  defp scan_ir_changes(old_nodes, new_nodes, old_index, new_index, acc) do
    old_done? = old_index >= length(old_nodes)
    new_done? = new_index >= length(new_nodes)

    cond do
      old_done? and new_done? ->
        {:ok, acc}

      new_done? ->
        with {:ok, delete} <- payload_delete_change(Enum.at(old_nodes, old_index)) do
          scan_ir_changes(old_nodes, new_nodes, old_index + 1, new_index, [delete | acc])
        end

      old_done? ->
        with {:ok, insert} <-
               payload_insert_change(
                 Enum.at(new_nodes, new_index),
                 insertion_anchor(old_nodes, old_index)
               ) do
          scan_ir_changes(old_nodes, new_nodes, old_index, new_index + 1, [insert | acc])
        end

      true ->
        old = Enum.at(old_nodes, old_index)
        new = Enum.at(new_nodes, new_index)

        cond do
          inserted_payload?(new) and not existing_insert_payload_match?(old, new) ->
            with {:ok, insert} <-
                   payload_insert_change(new, insertion_anchor(old_nodes, old_index)) do
              scan_ir_changes(old_nodes, new_nodes, old_index, new_index + 1, [insert | acc])
            end

          deletable_payload?(old) and aligns_after_deleted_payload?(old_nodes, old_index, new) ->
            with {:ok, delete} <- payload_delete_change(old) do
              scan_ir_changes(old_nodes, new_nodes, old_index + 1, new_index, [delete | acc])
            end

          true ->
            case existing_node_changes(old, new) do
              {:ok, node_changes} ->
                scan_ir_changes(
                  old_nodes,
                  new_nodes,
                  old_index + 1,
                  new_index + 1,
                  Enum.reverse(node_changes) ++ acc
                )

              {:error, reason} ->
                {:error, reason}
            end
        end
    end
  end

  defp existing_node_changes(old, new) do
    old_node = normalize_ir_value(old)
    new_node = normalize_ir_value(new)
    old_ref = Map.get(old_node, "ref")
    new_ref = Map.get(new_node, "ref")
    old_type = Map.get(old_node, "type")
    new_type = Map.get(new_node, "type")
    raw_ref = node_field(old, "ref") || old_ref

    cond do
      Map.has_key?(new_node, "ref") and old_ref != new_ref ->
        {:error, :structural_change}

      old_type != new_type ->
        {:error, :structural_change}

      is_nil(raw_ref) ->
        {:error, :unroutable}

      true ->
        changes_for_node(old_node, new_node, raw_ref, old_type)
    end
  end

  defp inserted_table_payload?(node) do
    node = normalize_ir_value(node)

    Map.get(node, "type") == "table" and
      (is_list(Map.get(node, "cells")) or positive_int?(Map.get(node, "rows")) or
         positive_int?(Map.get(node, "cols")))
  end

  defp inserted_picture_payload?(node) do
    node = normalize_ir_value(node)

    Map.get(node, "type") == "picture" and
      (present_string?(Map.get(node, "src")) or present_string?(Map.get(node, "path")) or
         present_string?(Map.get(node, "image_base64")) or nonempty_list?(Map.get(node, "bins")))
  end

  defp inserted_payload?(node),
    do: inserted_table_payload?(node) or inserted_picture_payload?(node)

  defp existing_table_payload_match?(old, new) do
    old = normalize_ir_value(old)
    new = normalize_ir_value(new)

    Map.get(old, "type") == "table" and Map.get(new, "type") == "table" and
      not Map.has_key?(new, "cells")
  end

  defp existing_picture_payload_match?(old, new) do
    old = normalize_ir_value(old)
    new = normalize_ir_value(new)

    Map.get(old, "type") == "picture" and Map.get(new, "type") == "picture"
  end

  defp existing_insert_payload_match?(old, new),
    do: existing_table_payload_match?(old, new) or existing_picture_payload_match?(old, new)

  defp deletable_payload?(node) do
    node = normalize_ir_value(node)
    Map.get(node, "type") == "picture" and not is_nil(node_field(node, "ref"))
  end

  defp aligns_after_deleted_payload?(old_nodes, old_index, new) do
    case Enum.at(old_nodes, old_index + 1) do
      nil ->
        false

      next_old ->
        case existing_node_changes(next_old, new) do
          {:ok, _changes} -> true
          {:error, _reason} -> false
        end
    end
  end

  defp payload_insert_change(node, anchor) do
    cond do
      inserted_table_payload?(node) -> table_insert_change(node, anchor)
      inserted_picture_payload?(node) -> picture_insert_change(node, anchor)
      true -> {:error, :structural_change}
    end
  end

  defp payload_delete_change(node) do
    node = normalize_ir_value(node)

    cond do
      not deletable_payload?(node) ->
        {:error, :structural_change}

      true ->
        marker = picture_marker(node)
        {:ok, {:delete_node, %{"op" => "delete_node", "ref" => node_field(node, "ref")}, marker}}
    end
  end

  defp positive_int?(value), do: is_integer(value) and value > 0
  defp nonempty_list?(value), do: is_list(value) and value != []
  defp present_string?(value), do: is_binary(value) and value != ""

  defp table_insert_change(node, anchor) do
    node = normalize_ir_value(node)
    cells = coerce_table_cells(Map.get(node, "cells", []))
    rows = table_rows(node, cells)
    cols = table_cols(node, cells)

    cond do
      Map.get(node, "type") != "table" ->
        {:error, :structural_change}

      not (rows > 0 and cols > 0) ->
        {:error, {:invalid_table_payload, "table payload needs cells or positive rows/cols"}}

      true ->
        op =
          %{
            "op" => "insert_table",
            "ref" => anchor,
            "rows" => rows,
            "cols" => cols
          }
          |> maybe_put_nonempty("cells", cells)
          |> maybe_put_bool("header", Map.get(node, "header"))
          |> maybe_put_string("header_color", Map.get(node, "header_color"))

        {:ok, {:insert_table, op, first_table_marker(cells)}}
    end
  end

  defp picture_insert_change(node, anchor) do
    node = normalize_ir_value(node)
    src = Map.get(node, "src") || Map.get(node, "path")
    bins = picture_bins(node)

    cond do
      Map.get(node, "type") != "picture" ->
        {:error, :structural_change}

      not (present_string?(src) or nonempty_list?(bins)) ->
        {:error, {:invalid_picture_payload, "picture payload needs src/path/image_base64/bins"}}

      true ->
        op =
          %{"op" => "insert_picture", "ref" => anchor}
          |> maybe_put_string("src", src)
          |> maybe_put_nonempty("bins", bins)
          |> maybe_put_string("extension", Map.get(node, "extension"))
          |> maybe_put_integer("width", Map.get(node, "width") || Map.get(node, "Width"))
          |> maybe_put_integer("height", Map.get(node, "height") || Map.get(node, "Height"))
          |> maybe_put_integer("natural_width_px", Map.get(node, "natural_width_px"))
          |> maybe_put_integer("natural_height_px", Map.get(node, "natural_height_px"))
          |> maybe_put_string("description", Map.get(node, "description") || Map.get(node, "alt"))

        {:ok, {:insert_picture, op, picture_marker(node), picture_insert_props(node)}}
    end
  end

  defp picture_bins(node) do
    cond do
      nonempty_list?(Map.get(node, "bins")) -> Map.get(node, "bins")
      present_string?(Map.get(node, "image_base64")) -> [Map.get(node, "image_base64")]
      true -> []
    end
  end

  @picture_insert_only_fields ~w(type text src path image_base64 bins extension description alt
                                 natural_width_px natural_height_px)
  @picture_insert_property_fields ~w(width height Width Height x y PosX PosY horzOffset
                                     vertOffset TreatAsChar treatAsChar Caption caption
                                     horzRelTo vertRelTo horzAlign vertAlign textWrap)
  @picture_insert_position_fields ~w(x y PosX PosY horzOffset vertOffset
                                     horzRelTo vertRelTo horzAlign vertAlign)

  defp picture_insert_props(node) do
    node = normalize_ir_value(node)

    node
    |> Map.take(picture_insert_property_fields(node))
    |> Enum.reject(fn {key, value} ->
      key in @picture_insert_only_fields or is_nil(value)
    end)
    |> Map.new()
  end

  defp picture_insert_property_fields(node) do
    if picture_insert_floating?(node) do
      @picture_insert_property_fields
    else
      @picture_insert_property_fields -- @picture_insert_position_fields
    end
  end

  defp picture_insert_floating?(node) do
    Map.get(node, "treatAsChar") == false or Map.get(node, "TreatAsChar") == false
  end

  defp picture_marker(node) do
    Enum.find_value(["description", "alt", "src", "path", "text"], fn key ->
      value = Map.get(node, key)

      cond do
        is_binary(value) and value != "" -> value
        true -> nil
      end
    end)
  end

  defp coerce_table_cells(cells) when is_list(cells) do
    Enum.map(cells, fn
      row when is_list(row) -> Enum.map(row, &to_string/1)
      value -> [to_string(value)]
    end)
  end

  defp coerce_table_cells(_cells), do: []

  defp table_rows(node, cells) do
    case Map.get(node, "rows") do
      rows when is_integer(rows) and rows > 0 -> rows
      _ -> length(cells)
    end
  end

  defp table_cols(node, cells) do
    case Map.get(node, "cols") do
      cols when is_integer(cols) and cols > 0 ->
        cols

      _ ->
        cells
        |> Enum.map(&length/1)
        |> Enum.max(fn -> 0 end)
    end
  end

  defp first_table_marker(cells) do
    cells
    |> List.flatten()
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp maybe_put_nonempty(map, _key, []), do: map
  defp maybe_put_nonempty(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_bool(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp maybe_put_bool(map, _key, _value), do: map

  defp maybe_put_integer(map, key, value) when is_integer(value), do: Map.put(map, key, value)
  defp maybe_put_integer(map, _key, _value), do: map

  defp maybe_put_string(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp maybe_put_string(map, _key, _value), do: map

  defp insertion_anchor(old_nodes, old_index) do
    unsafe_paragraphs = unsafe_insert_anchor_paragraphs(old_nodes)

    previous =
      old_nodes
      |> Enum.take(old_index)
      |> Enum.reverse()
      |> Enum.find_value(&body_ref_at_end(&1, unsafe_paragraphs))

    next =
      old_nodes
      |> Enum.drop(old_index)
      |> Enum.find_value(&body_ref_at_end(&1, unsafe_paragraphs))

    previous || next || "end"
  end

  defp unsafe_insert_anchor_paragraphs(nodes) do
    Enum.reduce(nodes, MapSet.new(), fn node, acc ->
      node = normalize_ir_value(node)
      type = Map.get(node, "type")
      ref = node_field(node, "ref") |> normalize_ir_value()

      if unsafe_insert_anchor_type?(type) and is_map(ref) and
           is_integer(Map.get(ref, "paragraph")) do
        MapSet.put(acc, {Map.get(ref, "section", 0), Map.get(ref, "paragraph")})
      else
        acc
      end
    end)
  end

  defp unsafe_insert_anchor_type?(type),
    do: type in ["section_def", "column_def", "page_number_pos", "table", "picture"]

  defp body_ref_at_end(node, unsafe_paragraphs) do
    node = normalize_ir_value(node)

    with true <- Map.get(node, "type") == "paragraph",
         %{} = ref <- node_field(node, "ref") |> normalize_ir_value(),
         true <- body_paragraph_ref?(ref),
         false <- unsafe_insert_anchor_paragraph?(ref, unsafe_paragraphs),
         text when is_binary(text) <- node |> normalize_ir_value() |> Map.get("text") do
      %{
        "section" => Map.get(ref, "section", 0),
        "paragraph" => Map.get(ref, "paragraph"),
        "offset" => String.length(text)
      }
    else
      _ -> nil
    end
  end

  defp unsafe_insert_anchor_paragraph?(ref, unsafe_paragraphs) do
    MapSet.member?(unsafe_paragraphs, {Map.get(ref, "section", 0), Map.get(ref, "paragraph")})
  end

  defp body_paragraph_ref?(ref) do
    is_integer(Map.get(ref, "paragraph")) and is_nil(Map.get(ref, "cell")) and
      is_nil(Map.get(ref, "control")) and is_nil(Map.get(ref, "note"))
  end

  defp changes_for_node(old_node, new_node, raw_ref, type) do
    with {:ok, text_change} <- text_change_for_node(old_node, new_node, raw_ref, type),
         {:ok, prop_change} <- prop_change_for_node(old_node, new_node, raw_ref, type) do
      {:ok, Enum.reject([text_change, prop_change], &is_nil/1)}
    end
  end

  defp text_change_for_node(old_node, new_node, raw_ref, type) do
    old_text = Map.get(old_node, "text")
    new_text = Map.get(new_node, "text")

    cond do
      old_text == new_text ->
        {:ok, nil}

      not (is_binary(old_text) and is_binary(new_text)) ->
        {:error, :unroutable}

      type == "cell" ->
        {:ok, {:text, %{"op" => "set_cell", "ref" => raw_ref, "text" => new_text}, new_text}}

      old_text == "" ->
        {:ok, {:text, %{"op" => "insert_text", "ref" => raw_ref, "text" => new_text}, new_text}}

      true ->
        {:ok,
         {:text,
          %{
            "op" => "replace_text",
            "ref" => raw_ref,
            "query" => old_text,
            "replacement" => new_text
          }, new_text}}
    end
  end

  defp prop_change_for_node(old_node, new_node, raw_ref, type) do
    props =
      old_node
      |> changed_property_keys(new_node)
      |> Map.new(fn key -> {key, Map.get(new_node, key)} end)

    if props == %{} do
      {:ok, nil}
    else
      {:ok, {:set, raw_ref, type, props}}
    end
  end

  defp changed_property_keys(old_node, new_node) do
    old_node
    |> Map.keys()
    |> Kernel.++(Map.keys(new_node))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in ["ref", "type", "text"]))
    |> Enum.filter(&(Map.get(old_node, &1) != Map.get(new_node, &1)))
  end

  defp normalize_ir_value(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_ir_value(v)} end)
  end

  defp normalize_ir_value(list) when is_list(list), do: Enum.map(list, &normalize_ir_value/1)
  defp normalize_ir_value(other), do: other

  # Office emits both a paragraph (`p1`) and its child run (`p1/r0`) carrying the
  # same text; an edit touching both (e.g. `sed` over the JSONL) yields two
  # changes. Keep only the parent — one paragraph-level `replace_text` suffices;
  # applying the child too would no-op or fail. rhwp emits no run nodes, so this
  # only affects office string refs.
  defp dedup_office_runs(changes) do
    refs =
      changes
      |> Enum.flat_map(fn
        {:text, %{"ref" => ref}, _marker} -> [ref]
        _other -> []
      end)
      |> MapSet.new()

    Enum.reject(changes, fn
      {:text, %{"ref" => ref}, _marker} ->
        is_binary(ref) and
          Enum.any?(refs, fn parent ->
            is_binary(parent) and parent != ref and String.starts_with?(ref, parent <> "/")
          end)

      _other ->
        false
    end)
  end

  # A FUSE write is a FILE-LEVEL modification of the document, NOT a `doc.edit`.
  # We apply each changed line straight onto the document's SERVER model
  # (`Editor.apply` -> `backend.edit`) and persist its bytes (`Editor.save`) —
  # the agent-facing `doc.edit`/`doc.save` MCP tools are deliberately NOT on this
  # path. The Pool's server `Editor` is the authoritative file model
  # (`Pool.route/2` is server-only since Phase 3; viewers re-derive from it), so
  # writing it directly IS the file modification.
  defp apply_changes(abs_path, changes, opts) do
    with {:ok, kind} <- kind_for(abs_path),
         {:ok, document_id} <- Pool.open(abs_path, kind: kind),
         {:server, editor} <- Pool.route(Pool, document_id),
         {:ok, applied} <- apply_changes_directly(editor, changes),
         :ok <- save_editor(editor, abs_path, kind) do
      broadcast_edit(abs_path, changes, applied, opts)
      {:ok, %{applied: length(changes), doc: Path.basename(abs_path)}}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:writeback_unroutable, other}}
    end
  end

  defp apply_changes_directly(editor, changes) do
    Enum.reduce_while(changes, {:ok, []}, fn change, {:ok, acc} ->
      case apply_change_directly(editor, change) do
        :ok -> {:cont, {:ok, [%{} | acc]}}
        {:ok, applied} -> {:cont, {:ok, [applied | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, applied} -> {:ok, Enum.reverse(applied)}
      error -> error
    end
  end

  defp apply_change_directly(editor, {:text, op, _marker}) do
    Editor.apply(editor, op)
  end

  defp apply_change_directly(editor, {:insert_table, op, _marker}) do
    Editor.apply(editor, op)
  end

  defp apply_change_directly(editor, {:insert_picture, op, _marker, props}) do
    with {:ok, applied} <- Editor.apply(editor, op),
         :ok <- maybe_set_inserted_picture_props(editor, inserted_control_ref(op, applied), props) do
      {:ok, applied}
    end
  end

  defp apply_change_directly(editor, {:delete_node, op, _marker}) do
    Editor.apply(editor, op)
  end

  defp apply_change_directly(editor, {:set, ref, type, props}) do
    props =
      if is_binary(type) and type != "" do
        Map.put_new(props, "kind", type)
      else
        props
      end

    Editor.set(editor, ref, props)
  end

  defp maybe_set_inserted_picture_props(_editor, _ref_result, props) when props == %{}, do: :ok

  defp maybe_set_inserted_picture_props(editor, {:ok, ref}, props) do
    case Editor.set(editor, ref, Map.put_new(props, "kind", "picture")) do
      {:ok, _applied} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_set_inserted_picture_props(_editor, {:error, reason}, _props), do: {:error, reason}

  defp save_editor(editor, abs_path, kind) do
    case Editor.save(editor, format: save_format(kind), path: abs_path) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp save_format(:hwpx), do: :hwpx
  defp save_format(:docx), do: :docx
  defp save_format(:pptx), do: :pptx
  defp save_format(:xlsx), do: :xlsx
  defp save_format(_kind), do: :hwp

  defp broadcast_edit(abs_path, changes, applied, opts) do
    root = opts[:root]

    if is_binary(root) do
      hit =
        Enum.find_value(changes, fn
          {:text, _op, marker} -> marker
          {:insert_table, _op, marker} -> marker
          {:insert_picture, _op, marker, _props} -> marker
          {:delete_node, _op, marker} -> marker
          _other -> nil
        end)

      # Carry the applied edits as `replace_text` ops so the viewer can LIVE-STREAM
      # the change into the open editor incrementally (apply op + repaint the one
      # page) instead of reloading the whole document.
      ops =
        Enum.flat_map(changes, fn
          {:text, op, _marker} -> [op]
          {:insert_table, op, _marker} -> [op]
          {:insert_picture, op, _marker, _props} -> [browser_edit_op(op)]
          {:delete_node, op, _marker} -> [op]
          _other -> []
        end)

      highlights =
        changes
        |> Enum.zip(applied)
        |> Enum.flat_map(fn
          {{:text, op, marker}, _applied} ->
            [
              %{
                "kind" => "text",
                "op" => op["op"],
                "ref" => op["ref"],
                "text" => marker
              }
            ]

          {{:insert_table, op, _marker}, applied} ->
            table_insert_highlights(op, applied)

          {{:insert_picture, op, marker, _props}, applied} ->
            picture_insert_highlights(op, marker, applied)

          {{:delete_node, op, marker}, _applied} ->
            [
              %{
                "kind" => "delete",
                "op" => op["op"],
                "ref" => op["ref"],
                "text" => marker
              }
            ]

          {{:set, ref, type, props}, _applied} ->
            [
              %{
                "kind" => "set",
                "ref" => ref,
                "type" => type,
                "props" => props
              }
            ]
        end)

      sets =
        changes
        |> Enum.zip(applied)
        |> Enum.flat_map(fn
          {{:set, ref, type, props}, _applied} ->
            props =
              if is_binary(type) and type != "" do
                Map.put_new(props, "kind", type)
              else
                props
              end

            [%{"ref" => ref, "props" => props}]

          {{:insert_picture, op, _marker, props}, applied} ->
            cond do
              props == %{} ->
                []

              not is_map(props) ->
                []

              true ->
                case inserted_control_ref(op, applied) do
                  {:ok, ref} ->
                    [%{"ref" => ref, "props" => Map.put_new(props, "kind", "picture")}]

                  {:error, _reason} ->
                    []
                end
            end

          {_other, _applied} ->
            []
        end)

      Phoenix.PubSub.broadcast(
        Ecrits.PubSub,
        "doc_vfs:" <> DocMount.canonical_root(root),
        {:vfs_doc_edited,
         %{
           path: abs_path,
           doc: Path.basename(abs_path),
           applied: length(changes),
           marker: hit,
           ops: ops,
           highlights: highlights,
           sets: sets
         }}
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp table_insert_highlights(op, applied) do
    with [%{"controlIdx" => control, "paraIdx" => paragraph} | _] <-
           Map.get(applied, :native) || Map.get(applied, "native"),
         section <- table_insert_section(op),
         cells when is_list(cells) <- Map.get(op, "cells") do
      cols = Map.get(op, "cols") || cells |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

      cells
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, row_index} ->
        row
        |> Enum.with_index()
        |> Enum.map(fn {text, col_index} ->
          cell_index = row_index * cols + col_index

          %{
            "kind" => "text",
            "op" => "insert_table",
            "ref" => %{
              "section" => section,
              "paragraph" => paragraph,
              "offset" => 0,
              "cell" => %{
                "parentParaIndex" => paragraph,
                "controlIndex" => control,
                "cellIndex" => cell_index,
                "cellParaIndex" => 0
              }
            },
            "text" => text
          }
        end)
      end)
    else
      _ ->
        [
          %{
            "kind" => "text",
            "op" => "insert_table",
            "ref" => Map.get(op, "ref"),
            "text" => first_table_marker(Map.get(op, "cells", []))
          }
        ]
    end
  end

  defp picture_insert_highlights(op, marker, applied) do
    case inserted_control_ref(op, applied) do
      {:ok, ref} ->
        [
          %{
            "kind" => "picture",
            "op" => "insert_picture",
            "ref" => ref,
            "text" => marker
          }
        ]

      {:error, _reason} ->
        [
          %{
            "kind" => "picture",
            "op" => "insert_picture",
            "ref" => Map.get(op, "ref"),
            "text" => marker
          }
        ]
    end
  end

  defp inserted_control_ref(op, applied) do
    with [%{"controlIdx" => control, "paraIdx" => paragraph} | _] <-
           Map.get(applied, :native) || Map.get(applied, "native"),
         section <- table_insert_section(op),
         true <- is_integer(control) and is_integer(paragraph) do
      {:ok,
       %{
         "section" => section,
         "paragraph" => paragraph,
         "control" => control,
         "type" => "picture"
       }}
    else
      _ -> {:error, :missing_inserted_control_ref}
    end
  end

  defp browser_edit_op(%{"op" => "insert_picture"} = op) do
    atom_op =
      %{
        op: Map.get(op, "op"),
        ref: Map.get(op, "ref"),
        src: Map.get(op, "src"),
        bins: Map.get(op, "bins"),
        image_base64: Map.get(op, "image_base64"),
        extension: Map.get(op, "extension"),
        width: Map.get(op, "width"),
        height: Map.get(op, "height"),
        natural_width_px: Map.get(op, "natural_width_px"),
        natural_height_px: Map.get(op, "natural_height_px"),
        description: Map.get(op, "description")
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case Ecrits.Doc.Rhwp.Image.for_browser(atom_op) do
      {:ok, browser_op} -> normalize_ir_value(browser_op)
      {:error, _reason} -> op
    end
  end

  defp browser_edit_op(op), do: op

  defp table_insert_section(op) do
    case normalize_ir_value(Map.get(op, "ref")) do
      %{"section" => section} when is_integer(section) -> section
      _ -> 0
    end
  end

  # The decoded IR uses string keys; tolerate an atom key as a fallback so a
  # backend that returns atom-keyed nodes still projects.
  defp node_field(node, key) when is_map_key(node, key), do: Map.get(node, key)

  defp node_field(node, key) do
    atom = String.to_existing_atom(key)
    Map.get(node, atom)
  rescue
    ArgumentError -> nil
  end
end
