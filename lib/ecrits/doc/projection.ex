defmodule Ecrits.Doc.Projection do
  @moduledoc """
  Deterministic, grep-able UTF-8 JSONL projection of an on-disk document.

  This is the JSONL projection of the exfuse doc-VFS migration
  (`docs/plans/2026-06-23-exfuse-doc-vfs-migration.md`, Layer 3 / Phase 1). It
  renders a WHOLE document — HWP/HWPX/docx/pptx/xlsx — to a single stable byte
  blob that the document VFS serves as `<name>.jsonl`, so a human (or the agent,
  whose cwd is the workspace root) can `cat`/`rg` the document's text without an
  MCP round-trip.

  ## How the bytes are produced

  The projection goes through the REAL server-side doc layer, never a bespoke
  parser:

    1. `Ecrits.Doc.Pool.open/2` loads the document into the pool, inferring the
       backend `kind:` from the file extension. `open/2` is idempotent — a doc
       the workspace is already viewing is reused, not reopened — so projection
       NEVER disposes the doc afterwards (lifecycle is the VFS/Session layer's
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
  alias Libreofficex.LokBackend.Ir, as: OfficeIr

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
  or `{:error, reason}` when the document cannot be projected. Used for the VFS
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
  # [deprecated] dead code — no callers in lib or test (dead-code audit 2026-07-13: xref + repo grep + runtime trace)
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
      {:ok, render_elements(nodes, kind)}
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
  @spec render_elements([map()], Ecrits.Doc.kind()) :: projection()
  defp render_elements(nodes, kind) do
    line =
      nodes
      |> nested_for(kind)
      |> encode_ir_node()
      |> Kernel.<>("\n")

    bytes = IO.iodata_to_binary(line)

    %{
      bytes: bytes,
      line_index: [{{0, byte_size(bytes)}, nil}],
      fingerprint: :erlang.phash2(bytes)
    }
  end

  # Office (libre) projects through its own engine IR policy in the dep — ref-
  # addressed (no ref in the bytes), runs and derived fields dropped. rhwp keeps
  # the positional-ref compaction below. The nested shape is the same
  # `[section[paragraph[payload]]]` either way, so the parser/diff is shared.
  defp nested_for(nodes, kind) do
    if office_kind?(kind), do: OfficeIr.project(nodes), else: Ehwp.Ir.project(nodes)
  end

  # Deterministic JSON for one JSONL value: keys sorted recursively (via
  # `Jason.OrderedObject`) so identical IR always serializes to identical bytes
  # (the fingerprint and the write-back round-trip both rely on this). Jason
  # escapes embedded newlines, so a node always occupies exactly one line.
  defp encode_ir_node(node), do: node |> deep_order() |> Jason.encode!()

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
  at `abs_path` (VFS write-back / Phase 2). Diffs the incoming `new_bytes`
  against the current projection's reconstructed payload nodes and applies
  changed fields directly to the mounted server editor: paragraph `"text"`
  changes become scoped text edits, cell `"text"` changes become whole-cell
  `set_cell` writes, a newly inserted `%{"type" => "table", "cells" => ...}`
  payload becomes native `insert_table`, and other node-field changes become
  native property writes.
  This is not the MCP/browser `doc.edit` -> `document.engine.operation.command` path; that path remains the
  semantic hook for non-VFS editor requests and may only be used later to resync
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
      with {:ok, kind} <- kind_for(abs_path),
           {:ok, old_nodes} <- ir_nodes(abs_path),
           {:ok, new_nodes} <- parse_ir_jsonl(new_bytes) do
        case ir_changes(kind, old_nodes, new_nodes) do
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
    case Jason.decode(bytes) do
      {:ok, value} -> parse_projection_values([value])
      {:error, _} -> parse_ir_jsonl_lines(bytes)
    end
  end

  defp parse_ir_jsonl_lines(bytes) do
    bytes
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> decode_jsonl_values()
    |> case do
      {:ok, values} ->
        parse_projection_values(values)

      error ->
        error
    end
  end

  defp parse_projection_values([]), do: {:ok, []}
  defp parse_projection_values([nested]) when is_list(nested), do: parse_nested_projection(nested)

  defp parse_projection_values(values) do
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

  # Re-expand a parsed payload's compacted positional ref back to its JSON-object
  # form. Delegated to the engine IR policy in the ehwp dep; a no-op for non-
  # positional refs, so office payloads (string/absent refs) pass through unchanged.
  defp expand_projected_node(node), do: Ehwp.Ir.expand_node(node)

  defp office_kind?(kind), do: kind in [:docx, :pptx, :xlsx]

  # Dispatch the write-back diff by engine. Office (libre) refs are opaque strings
  # mixing positional ordinals with stable names, so it uses its own ref-addressed
  # diff (`office_changes/2`); the rhwp positional-tuple diff lives in the ehwp dep
  # (`Ehwp.Ir.changes/2`) — both return the change tuples `apply_changes/3` runs.
  defp ir_changes(kind, old_nodes, new_nodes) do
    if office_kind?(kind),
      do: office_changes(old_nodes, new_nodes),
      else: Ehwp.Ir.changes(old_nodes, new_nodes)
  end

  # Office (libre) write-back diff. The projection dropped runs, refs, and
  # non-editable runtime context, so live OLD nodes are shaped the SAME way (via
  # the dep IR policy) and the edited projection recovers refs from the aligned
  # live nodes. Calc cell value/formula fields are deliberately still present and
  # are routed as typed set_cell ops.
  # Office refs are opaque strings, so this scanner mirrors the HWP change
  # classes without reusing HWP's positional ref logic.
  defp office_changes(old_nodes, new_nodes) do
    old_shaped = OfficeIr.shape_old(old_nodes)
    news = Enum.map(new_nodes, &OfficeIr.canonicalize/1)

    case office_scan_changes(old_shaped, news, 0, 0, []) do
      {:ok, changes} -> Enum.reverse(changes)
      {:error, reason} -> {:error, reason}
    end
  end

  defp office_scan_changes(old_nodes, new_nodes, old_index, new_index, acc) do
    old_done? = old_index >= length(old_nodes)
    new_done? = new_index >= length(new_nodes)

    cond do
      old_done? and new_done? ->
        {:ok, acc}

      new_done? ->
        with {:ok, delete} <- office_payload_delete_change(Enum.at(old_nodes, old_index)) do
          office_scan_changes(old_nodes, new_nodes, old_index + 1, new_index, [delete | acc])
        end

      old_done? ->
        with {:ok, insert} <-
               office_payload_insert_change(
                 Enum.at(new_nodes, new_index),
                 office_insertion_anchor(old_nodes, old_index)
               ) do
          office_scan_changes(old_nodes, new_nodes, old_index, new_index + 1, [insert | acc])
        end

      true ->
        old = Enum.at(old_nodes, old_index)
        new = Enum.at(new_nodes, new_index)

        cond do
          office_inserted_payload?(new) and not office_existing_insert_payload_match?(old, new) ->
            with {:ok, insert} <-
                   office_payload_insert_change(
                     new,
                     office_insertion_anchor(old_nodes, old_index)
                   ) do
              office_scan_changes(old_nodes, new_nodes, old_index, new_index + 1, [insert | acc])
            end

          office_deletable_payload?(old) and not office_same_payload_identity?(old.canon, new) and
              office_aligns_after_deleted_payload?(old_nodes, old_index, new) ->
            with {:ok, delete} <- office_payload_delete_change(old) do
              office_scan_changes(old_nodes, new_nodes, old_index + 1, new_index, [delete | acc])
            end

          true ->
            case office_node_changes(old, new) do
              {:ok, node_changes} ->
                office_scan_changes(
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

  defp office_node_changes(old, new_node) do
    old_node = normalize_ir_value(old.canon)
    new_node = normalize_ir_value(new_node)

    cond do
      old_node == new_node -> {:ok, []}
      old.type != Map.get(new_node, "type") -> {:error, :structural_change}
      is_nil(old.ref) -> {:error, :unroutable}
      true -> office_changes_for_node(old_node, new_node, old.ref, old.type)
    end
  end

  defp office_changes_for_node(old_node, new_node, "sheet[" <> _ = ref, "cell") do
    with {:ok, cell_change} <- office_calc_cell_change_for_node(old_node, new_node, ref),
         {:ok, prop_change} <- office_prop_change_for_node(old_node, new_node, ref, "cell") do
      {:ok, Enum.reject([cell_change, prop_change], &is_nil/1)}
    end
  end

  defp office_changes_for_node(old_node, new_node, "section[" <> _ = ref, "column_def") do
    with {:ok, column_change} <- office_column_def_change_for_node(old_node, new_node, ref),
         {:ok, prop_change} <-
           office_prop_change_for_node(old_node, new_node, ref, "column_def") do
      {:ok, Enum.reject([column_change, prop_change], &is_nil/1)}
    end
  end

  defp office_changes_for_node(old_node, new_node, ref, type)
       when type in ["shape", "text_frame", "placeholder", "shape_group"] do
    with {:ok, geometry_change} <- office_geometry_change_for_node(old_node, new_node, ref),
         {:ok, text_change} <- office_text_change_for_node(old_node, new_node, ref, type),
         {:ok, prop_change} <- office_prop_change_for_node(old_node, new_node, ref, type) do
      {:ok, Enum.reject([geometry_change, text_change, prop_change], &is_nil/1)}
    end
  end

  defp office_changes_for_node(old_node, new_node, ref, type) do
    with {:ok, text_change} <- office_text_change_for_node(old_node, new_node, ref, type),
         {:ok, prop_change} <- office_prop_change_for_node(old_node, new_node, ref, type) do
      {:ok, Enum.reject([text_change, prop_change], &is_nil/1)}
    end
  end

  @office_geometry_fields ~w(x y width height)

  defp office_geometry_change_for_node(old_node, new_node, ref) do
    changed =
      Enum.filter(@office_geometry_fields, fn key ->
        Map.get(old_node, key) != Map.get(new_node, key)
      end)

    cond do
      changed == [] ->
        {:ok, nil}

      Enum.any?(changed, &(not is_integer(Map.get(new_node, &1)))) ->
        {:error, {:invalid_geometry, "shape geometry values must be integers in 1/100 mm"}}

      true ->
        op =
          %{"op" => "set_geometry", "ref" => ref}
          |> office_maybe_put_integer("x", changed_geometry_value(changed, new_node, "x"))
          |> office_maybe_put_integer("y", changed_geometry_value(changed, new_node, "y"))
          |> office_maybe_put_integer("w", changed_geometry_value(changed, new_node, "width"))
          |> office_maybe_put_integer("h", changed_geometry_value(changed, new_node, "height"))

        {:ok, {:text, op, inspect(Map.take(new_node, @office_geometry_fields))}}
    end
  end

  defp changed_geometry_value(changed, node, key) do
    if key in changed, do: Map.get(node, key)
  end

  @office_column_def_edit_fields ~w(count gap)

  defp office_column_def_change_for_node(old_node, new_node, ref) do
    changed =
      Enum.filter(@office_column_def_edit_fields, fn key ->
        Map.get(old_node, key) != Map.get(new_node, key)
      end)

    count = Map.get(new_node, "count")

    cond do
      changed == [] ->
        {:ok, nil}

      not office_positive_int?(count) ->
        {:error, {:invalid_column_def, "column_def edits require integer count > 0"}}

      true ->
        op =
          %{"op" => "set_columns", "ref" => ref, "count" => count}
          |> office_maybe_put_integer("gap", Map.get(new_node, "gap"))

        {:ok, {:text, op, Integer.to_string(count)}}
    end
  end

  @office_calc_cell_edit_fields ~w(text value value_type formula)

  defp office_calc_cell_change_for_node(old_node, new_node, ref) do
    changed =
      Enum.filter(@office_calc_cell_edit_fields, fn key ->
        Map.get(old_node, key) != Map.get(new_node, key)
      end)

    value_type = Map.get(new_node, "value_type") || Map.get(old_node, "value_type")

    cond do
      changed == [] ->
        {:ok, nil}

      value_type == "formula" ->
        office_formula_cell_change(changed, new_node, ref)

      value_type == "number" ->
        office_number_cell_change(changed, new_node, ref)

      true ->
        office_text_cell_change(changed, new_node, ref, value_type)
    end
  end

  defp office_formula_cell_change(changed, new_node, ref) do
    if Enum.any?(changed, &(&1 in ["formula", "text", "value_type"])) do
      formula =
        Map.get(new_node, "formula") ||
          Map.get(new_node, "text") ||
          office_calc_value_text(Map.get(new_node, "value"))

      if is_binary(formula) do
        {:ok,
         {:text,
          %{
            "op" => "set_cell",
            "ref" => ref,
            "text" => formula,
            "value_type" => "formula",
            "formula" => formula
          }, formula}}
      else
        {:error, :unroutable}
      end
    else
      {:ok, nil}
    end
  end

  defp office_number_cell_change(changed, new_node, ref) do
    cond do
      "value" in changed and is_number(Map.get(new_node, "value")) ->
        value = Map.get(new_node, "value")

        {:ok,
         {:text,
          %{
            "op" => "set_cell",
            "ref" => ref,
            "text" => office_calc_value_text(value),
            "value_type" => "number",
            "value" => value
          }, office_calc_value_text(value)}}

      "text" in changed and is_binary(Map.get(new_node, "text")) ->
        text = Map.get(new_node, "text")

        {:ok,
         {:text,
          %{
            "op" => "set_cell",
            "ref" => ref,
            "text" => text,
            "value_type" => "number"
          }, text}}

      "value_type" in changed ->
        office_text_cell_change(changed, new_node, ref, "number")

      true ->
        {:ok, nil}
    end
  end

  defp office_text_cell_change(changed, new_node, ref, value_type) do
    text =
      cond do
        "value" in changed -> office_calc_value_text(Map.get(new_node, "value"))
        is_binary(Map.get(new_node, "text")) -> Map.get(new_node, "text")
        true -> office_calc_value_text(Map.get(new_node, "value"))
      end

    if is_binary(text) do
      op =
        %{"op" => "set_cell", "ref" => ref, "text" => text}
        |> office_maybe_put_string("value_type", value_type)

      op =
        if "value" in changed and Map.has_key?(new_node, "value") do
          Map.put(op, "value", Map.get(new_node, "value"))
        else
          op
        end

      {:ok, {:text, op, text}}
    else
      {:error, :unroutable}
    end
  end

  defp office_calc_value_text(value) when is_binary(value), do: value
  defp office_calc_value_text(value) when is_integer(value), do: Integer.to_string(value)
  defp office_calc_value_text(value) when is_float(value), do: Float.to_string(value)
  defp office_calc_value_text(value) when is_boolean(value), do: to_string(value)
  defp office_calc_value_text(nil), do: ""
  defp office_calc_value_text(_value), do: nil

  defp office_text_change_for_node(old_node, new_node, ref, type) do
    old_text = Map.get(old_node, "text")
    new_text = Map.get(new_node, "text")

    cond do
      old_text == new_text ->
        {:ok, nil}

      not (is_binary(old_text) and is_binary(new_text)) ->
        {:error, :unroutable}

      type == "cell" ->
        {:ok, {:text, %{"op" => "set_cell", "ref" => ref, "text" => new_text}, new_text}}

      old_text == "" ->
        {:ok, {:text, %{"op" => "insert_text", "ref" => ref, "text" => new_text}, new_text}}

      true ->
        {:ok,
         {:text,
          %{
            "op" => "replace_text",
            "ref" => ref,
            "query" => old_text,
            "replacement" => new_text
          }, new_text}}
    end
  end

  defp office_prop_change_for_node(old_node, new_node, ref, type) do
    with :ok <- Libreofficex.LokBackend.Ir.validate_property_changes(old_node, new_node) do
      props = office_changed_props(old_node, new_node)

      if props == %{} do
        {:ok, nil}
      else
        {:ok, {:set, ref, type, props}}
      end
    end
  end

  @office_ignored_prop_fields ~w(ref type text props prop_types context row col sheet address display value value_type formula name count gap widths columns x y width height childCount placeholderKind master colors)

  defp office_changed_props(old_node, new_node) do
    old_props = Map.get(old_node, "props")
    new_props = Map.get(new_node, "props")

    nested =
      if is_map(old_props) and is_map(new_props) do
        old_props
        |> Map.keys()
        |> Kernel.++(Map.keys(new_props))
        |> Enum.uniq()
        |> Enum.filter(fn key ->
          Map.has_key?(new_props, key) and Map.get(old_props, key) != Map.get(new_props, key)
        end)
        |> Map.new(fn key -> {key, Map.get(new_props, key)} end)
      else
        %{}
      end

    top_level =
      old_node
      |> Map.keys()
      |> Kernel.++(Map.keys(new_node))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @office_ignored_prop_fields))
      |> Enum.filter(fn key ->
        Map.has_key?(new_node, key) and Map.get(old_node, key) != Map.get(new_node, key)
      end)
      |> Map.new(fn key -> {key, Map.get(new_node, key)} end)

    Map.merge(nested, top_level)
  end

  defp office_inserted_table_payload?(node) do
    node = normalize_ir_value(node)

    Map.get(node, "type") == "table" and
      (is_list(Map.get(node, "cells")) or office_positive_int?(Map.get(node, "rows")) or
         office_positive_int?(Map.get(node, "cols")))
  end

  defp office_inserted_picture_payload?(node) do
    node = normalize_ir_value(node)

    Map.get(node, "type") == "picture" and
      (office_present_string?(Map.get(node, "src")) or
         office_present_string?(Map.get(node, "path")) or
         office_present_string?(Map.get(node, "image_base64")) or
         office_nonempty_list?(Map.get(node, "bins")))
  end

  defp office_inserted_payload?(node),
    do: office_inserted_table_payload?(node) or office_inserted_picture_payload?(node)

  defp office_existing_insert_payload_match?(%{canon: _canon} = old, new),
    do: office_existing_insert_payload_match?(old.canon, new)

  defp office_existing_insert_payload_match?(old, new) do
    old = normalize_ir_value(old)
    new = normalize_ir_value(new)

    cond do
      Map.get(old, "type") == "table" and Map.get(new, "type") == "table" ->
        not (Map.has_key?(new, "cells") or office_positive_int?(Map.get(new, "rows")) or
               office_positive_int?(Map.get(new, "cols")))

      Map.get(old, "type") == "picture" and Map.get(new, "type") == "picture" ->
        true

      true ->
        false
    end
  end

  defp office_deletable_payload?(%{} = old), do: office_deletable_payload?(old.canon, old.ref)
  defp office_deletable_payload?(_old), do: false

  defp office_deletable_payload?(node, ref) do
    type = Map.get(normalize_ir_value(node), "type")
    is_binary(ref) and type in ["picture", "shape", "text_frame", "placeholder", "shape_group"]
  end

  defp office_aligns_after_deleted_payload?(old_nodes, old_index, new) do
    case Enum.at(old_nodes, old_index + 1) do
      nil -> false
      next_old -> office_same_payload_identity?(next_old.canon, new)
    end
  end

  defp office_same_payload_identity?(old, new) do
    old = old |> normalize_ir_value() |> Map.delete("prop_types")
    new = new |> normalize_ir_value() |> Map.delete("prop_types")

    Map.get(old, "type") == Map.get(new, "type") and old == new
  end

  defp office_payload_delete_change(%{} = old) do
    if office_deletable_payload?(old) do
      marker = Map.get(old.canon, "text") || old.ref
      {:ok, {:delete_node, %{"op" => "delete_node", "ref" => old.ref}, marker}}
    else
      {:error, :structural_change}
    end
  end

  defp office_payload_insert_change(node, anchor) do
    cond do
      office_inserted_table_payload?(node) -> office_table_insert_change(node, anchor)
      office_inserted_picture_payload?(node) -> office_picture_insert_change(node, anchor)
      true -> {:error, :structural_change}
    end
  end

  defp office_table_insert_change(node, anchor) do
    node = normalize_ir_value(node)
    cells = office_coerce_table_cells(Map.get(node, "cells", []))
    rows = office_table_rows(node, cells)
    cols = office_table_cols(node, cells)

    cond do
      not (rows > 0 and cols > 0) ->
        {:error, {:invalid_table_payload, "table payload needs cells or positive rows/cols"}}

      true ->
        op =
          %{
            "op" => "insert_table",
            "ref" => office_writer_anchor(anchor),
            "rows" => rows,
            "cols" => cols
          }
          |> office_maybe_put_nonempty("cells", cells)
          |> office_maybe_put_string("name", Map.get(node, "name"))
          |> office_maybe_put_bool("header", Map.get(node, "header"))

        {:ok, {:insert_table, op, first_table_marker(cells)}}
    end
  end

  defp office_picture_insert_change(node, anchor) do
    node = normalize_ir_value(node)
    src = Map.get(node, "src") || Map.get(node, "path")

    op =
      %{"op" => "insert_picture"}
      |> office_picture_anchor(anchor)
      |> office_maybe_put_string("src", src)
      |> office_maybe_put_string("image_base64", Map.get(node, "image_base64"))
      |> office_maybe_put_nonempty("bins", Map.get(node, "bins", []))
      |> office_maybe_put_string("extension", Map.get(node, "extension"))
      |> office_maybe_put_string("name", Map.get(node, "name"))
      |> office_maybe_put_integer("width", Map.get(node, "width") || Map.get(node, "Width"))
      |> office_maybe_put_integer("height", Map.get(node, "height") || Map.get(node, "Height"))
      |> office_maybe_put_integer("w", Map.get(node, "w"))
      |> office_maybe_put_integer("h", Map.get(node, "h"))
      |> office_maybe_put_integer("x", Map.get(node, "x"))
      |> office_maybe_put_integer("y", Map.get(node, "y"))

    {:ok, {:insert_picture, op, office_picture_marker(node), %{}}}
  end

  defp office_picture_anchor(op, "page[" <> rest = anchor) do
    page = rest |> String.split("]", parts: 2) |> List.first()

    op
    |> Map.put("page", page)
    |> office_maybe_put_string("ref", anchor)
  end

  defp office_picture_anchor(op, anchor), do: Map.put(op, "ref", anchor || "end")

  defp office_writer_anchor(anchor) when is_binary(anchor) do
    if Regex.match?(~r/^p\d+$/, anchor), do: anchor, else: "end"
  end

  defp office_writer_anchor(_anchor), do: "end"

  defp office_insertion_anchor(old_nodes, old_index) do
    previous =
      old_nodes
      |> Enum.take(old_index)
      |> Enum.reverse()
      |> Enum.find_value(&office_insert_ref/1)

    next =
      old_nodes
      |> Enum.drop(old_index)
      |> Enum.find_value(&office_insert_ref/1)

    previous || next || "end"
  end

  defp office_insert_ref(%{ref: ref, type: type})
       when is_binary(ref) and type in ["paragraph", "cell", "slide"],
       do: ref

  defp office_insert_ref(_old), do: nil

  defp office_positive_int?(value), do: is_integer(value) and value > 0
  defp office_nonempty_list?(value), do: is_list(value) and value != []
  defp office_present_string?(value), do: is_binary(value) and value != ""

  defp office_coerce_table_cells(cells) when is_list(cells) do
    Enum.map(cells, fn
      row when is_list(row) -> Enum.map(row, &to_string/1)
      value -> [to_string(value)]
    end)
  end

  defp office_coerce_table_cells(_cells), do: []

  defp office_table_rows(node, cells) do
    case Map.get(node, "rows") do
      rows when is_integer(rows) and rows > 0 -> rows
      _ -> length(cells)
    end
  end

  defp office_table_cols(node, cells) do
    case Map.get(node, "cols") do
      cols when is_integer(cols) and cols > 0 ->
        cols

      _ ->
        cells
        |> Enum.map(&length/1)
        |> Enum.max(fn -> 0 end)
    end
  end

  defp office_picture_marker(node) do
    Enum.find_value(["description", "alt", "src", "path", "text"], fn key ->
      value = Map.get(node, key)
      if is_binary(value) and value != "", do: value
    end)
  end

  defp office_maybe_put_nonempty(map, _key, []), do: map

  defp office_maybe_put_nonempty(map, key, value) when is_list(value),
    do: Map.put(map, key, value)

  defp office_maybe_put_nonempty(map, _key, _value), do: map

  defp office_maybe_put_bool(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp office_maybe_put_bool(map, _key, _value), do: map

  defp office_maybe_put_integer(map, key, value) when is_integer(value),
    do: Map.put(map, key, value)

  defp office_maybe_put_integer(map, _key, _value), do: map

  defp office_maybe_put_string(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp office_maybe_put_string(map, _key, _value), do: map

  if Mix.env() == :test do
    @doc false
    def __compute_ir_changes_for_test__(old_nodes, new_nodes),
      do: Ehwp.Ir.changes(old_nodes, new_nodes)

    @doc false
    def __text_highlight_for_test__(op, marker), do: text_highlight(op, marker)
  end

  defp normalize_ir_value(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_ir_value(v)} end)
  end

  defp normalize_ir_value(list) when is_list(list), do: Enum.map(list, &normalize_ir_value/1)
  defp normalize_ir_value(other), do: other

  # The rhwp insert_table op-builder (and its `first_table_marker`) moved to
  # `Ehwp.Ir`, but `broadcast_edit` still surfaces a table-insert highlight marker
  # for the chat rail — so this tiny marker helper stays on the ecrits side.
  defp first_table_marker(cells) do
    cells
    |> List.flatten()
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  # A VFS write is a FILE-LEVEL modification of the document, NOT a `doc.edit`.
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
            [text_highlight(op, marker)]

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

      info =
        %{
          path: abs_path,
          doc: Path.basename(abs_path),
          applied: length(changes),
          marker: hit,
          ops: ops,
          highlights: highlights,
          sets: sets
        }
        |> maybe_put_vfs_agent_id(vfs_agent_id(root, abs_path, opts))

      Phoenix.PubSub.broadcast(
        Ecrits.PubSub,
        "doc_vfs:" <> DocMount.canonical_root(root),
        {:vfs_doc_edited, info}
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp vfs_agent_id(root, abs_path, opts) do
    case Keyword.get(opts, :agent_id) do
      agent_id when is_binary(agent_id) and agent_id != "" ->
        agent_id

      _ ->
        if is_binary(root) do
          Ecrits.Fuse.OpenDocs.owner_agent_id_for_source(root, abs_path) ||
            Ecrits.Fuse.OpenDocs.owner_agent_id(root, Path.basename(abs_path))
        end
    end
  end

  defp maybe_put_vfs_agent_id(info, agent_id) when is_binary(agent_id) and agent_id != "",
    do: Map.put(info, :agent_id, agent_id)

  defp maybe_put_vfs_agent_id(info, _agent_id), do: info

  defp text_highlight(op, marker) do
    %{
      "kind" => "text",
      "op" => op["op"],
      "ref" => op["ref"],
      "text" => marker
    }
    |> Map.merge(text_highlight_range(op, marker))
  end

  defp text_highlight_range(
         %{"op" => "replace_text", "ref" => ref, "query" => query, "replacement" => replacement},
         _marker
       )
       when is_binary(query) and is_binary(replacement) do
    {relative_offset, length, text} = replacement_changed_range(query, replacement)

    %{
      "offset" => ref_offset(ref) + relative_offset,
      "length" => length,
      "text" => text
    }
  end

  defp text_highlight_range(%{"op" => op, "ref" => ref} = edit, marker)
       when op in ["insert_text", "set_char"] do
    text = Map.get(edit, "text", marker)

    if is_binary(text) do
      %{"offset" => ref_offset(ref), "length" => String.length(text), "text" => text}
    else
      %{}
    end
  end

  defp text_highlight_range(_op, _marker), do: %{}

  defp replacement_changed_range(query, replacement) do
    old = String.graphemes(query)
    new = String.graphemes(replacement)
    prefix = common_prefix_count(old, new)
    suffix = common_suffix_count(Enum.drop(old, prefix), Enum.drop(new, prefix))
    length = max(length(new) - prefix - suffix, 0)
    text = new |> Enum.drop(prefix) |> Enum.take(length) |> Enum.join()

    {prefix, length, text}
  end

  defp common_prefix_count(left, right), do: common_prefix_count(left, right, 0)

  defp common_prefix_count([a | left], [b | right], count) when a == b,
    do: common_prefix_count(left, right, count + 1)

  defp common_prefix_count(_left, _right, count), do: count

  defp common_suffix_count(left, right),
    do: common_prefix_count(Enum.reverse(left), Enum.reverse(right), 0)

  defp ref_offset(%{"offset" => offset}) when is_integer(offset), do: max(offset, 0)
  defp ref_offset(%{offset: offset}) when is_integer(offset), do: max(offset, 0)
  defp ref_offset(_ref), do: 0

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
      case inserted_cell_picture_ref(op, section, paragraph, control) do
        {:ok, ref} ->
          {:ok, ref}

        :error ->
          {:ok,
           %{
             "section" => section,
             "paragraph" => paragraph,
             "control" => control,
             "type" => "picture"
           }}
      end
    else
      _ -> {:error, :missing_inserted_control_ref}
    end
  end

  defp inserted_cell_picture_ref(op, section, paragraph, control) do
    ref = op |> Map.get("ref") |> normalize_ir_value()
    cell = ref |> Map.get("cell") |> normalize_ir_value()
    cell_path = normalize_cell_path(Map.get(ref, "cellPath") || Map.get(cell || %{}, "cellPath"))

    with true <- Map.get(op, "inline_in_cell") == true,
         %{} <- cell,
         parent_para when is_integer(parent_para) <-
           Map.get(cell, "parentParaIndex") || paragraph,
         table_control when is_integer(table_control) <- Map.get(cell, "controlIndex"),
         cell_index when is_integer(cell_index) <- Map.get(cell, "cellIndex"),
         cell_para when is_integer(cell_para) <- Map.get(cell, "cellParaIndex") do
      cell_path =
        cell_path ||
          [
            %{
              "controlIndex" => table_control,
              "cellIndex" => cell_index,
              "cellParaIndex" => cell_para
            }
          ]

      cell = Map.put(cell, "cellPath", cell_path)

      {:ok,
       %{
         "section" => section,
         "paragraph" => parent_para,
         "offset" => Map.get(ref, "offset", 0),
         "control" => control,
         "type" => "picture",
         "cell" => cell,
         "cellPath" => cell_path
       }}
    else
      _ -> :error
    end
  end

  defp normalize_cell_path([_ | _] = path) do
    path
    |> Enum.map(&normalize_ir_value/1)
    |> Enum.map(fn step ->
      %{
        "controlIndex" => Map.get(step, "controlIndex") || Map.get(step, "control"),
        "cellIndex" => Map.get(step, "cellIndex") || Map.get(step, "cell"),
        "cellParaIndex" => Map.get(step, "cellParaIndex") || Map.get(step, "cell_para")
      }
    end)
    |> Enum.filter(fn step ->
      is_integer(Map.get(step, "controlIndex")) and is_integer(Map.get(step, "cellIndex")) and
        is_integer(Map.get(step, "cellParaIndex"))
    end)
    |> case do
      [] -> nil
      path -> path
    end
  end

  defp normalize_cell_path(_other), do: nil

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
        description: Map.get(op, "description"),
        inline_in_cell: Map.get(op, "inline_in_cell")
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
end
