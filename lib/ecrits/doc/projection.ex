defmodule Ecrits.Doc.Projection do
  @moduledoc """
  Deterministic, grep-able UTF-8 text projection of an on-disk document.

  This is the "MarkdownProjection" of the exfuse doc-VFS migration
  (`docs/plans/2026-06-23-exfuse-doc-vfs-migration.md`, Layer 3 / Phase 1). It
  renders a WHOLE document — HWP/HWPX/docx/pptx/xlsx — to a single stable byte
  blob that a FUSE filesystem serves as `<name>.md`, so a human (or the agent,
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
    3. `render_elements/1` serializes the FULL IR as JSONL — one node per line,
       in document order, keys sorted recursively for byte-stability. The
       mounted `.md` therefore SHOWS the document's IR (refs, types, text,
       table/cell/picture/structural nodes, empty nodes), not a lossy text
       flattening. In parallel it records a `line_index` of `{byte_range, ref}`
       that `write_back/3` uses to map an edited line back to its node.
       `project_file/2` returns ONLY the bytes; the index is internal.

  Write-back diffs the edited JSONL against the live IR node-by-node (`ref` is
  the stable identity): a changed `"text"` becomes a direct text edit on that
  node's model; a changed/added/removed node is a structural change (rejected in
  v1). So editing the mounted IR IS editing the document.

  Determinism: the blob carries no timestamps and no random ordering — the same
  document content always projects to the same bytes (the basis of
  `fingerprint/1`).
  """

  alias Ecrits.Doc.Editor
  alias Ecrits.Doc.Pool

  @typedoc "A byte offset range `{start, length}` into the projected blob."
  @type byte_range :: {non_neg_integer(), non_neg_integer()}

  @typedoc "An internal line-index entry: where a node's text lives + its source ref."
  @type line_index_entry :: {byte_range(), Ecrits.Doc.ref()}

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
  The projected filename for a source `name`: append `".md"`.

      iex> Ecrits.Doc.Projection.projected_name("report.hwp")
      "report.hwp.md"
  """
  @spec projected_name(String.t()) :: String.t()
  def projected_name(name) when is_binary(name), do: name <> ".md"

  @doc """
  Recover the source basename from a projected name by stripping the trailing
  `".md"`. Returns `nil` when `proj_name` does not end in `".md"` (so a non-
  projection file in the mount is not mistaken for a source document).

      iex> Ecrits.Doc.Projection.source_basename("report.hwp.md")
      "report.hwp"
      iex> Ecrits.Doc.Projection.source_basename("notes.txt")
      nil
  """
  @spec source_basename(String.t()) :: String.t() | nil
  def source_basename(proj_name) when is_binary(proj_name) do
    if String.ends_with?(proj_name, ".md") do
      String.replace_suffix(proj_name, ".md", "")
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
    with {:ok, projection} <- build_projection(abs_path) do
      {:ok, projection.bytes}
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
      # The projection is IR JSONL; show the nodes' TEXT (not raw JSON), drop
      # empty/structural nodes, and collapse the paragraph+run duplicate.
      texts =
        bytes
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&ir_line_text/1)
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

  # A projected JSONL line -> its node "text" (falls back to the raw line).
  defp ir_line_text(line) do
    case Jason.decode(line) do
      {:ok, %{"text" => t}} when is_binary(t) -> t
      _ -> line
    end
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

  # Run `Editor.elements/2` against the open doc's Editor, serialized through the
  # Pool. `with_doc/2` returns `{:error, :not_found}` if the Editor vanished
  # between open and read; otherwise it returns the Editor's reply verbatim.
  @spec elements(Pool.document_id()) :: {:ok, [map()]} | {:error, term()}
  defp elements(document_id) do
    Pool.with_doc(document_id, fn editor -> Editor.elements(editor) end)
  end

  # --- IR -> deterministic blob + line index -------------------------------

  # Serialize the FULL document IR as JSONL: one node per line, in document
  # order. This IS the projection — the mounted `.md` shows the document's IR
  # (refs, types, text, table/cell/picture/structural nodes, empty nodes), NOT a
  # lossy text flattening. Byte-stable (keys sorted recursively) so the same IR
  # always yields the same bytes. The parallel `line_index` records, per node,
  # the `{byte_range, ref}` write-back uses to map an edited line to its node.
  @spec render_elements([map()]) :: projection()
  defp render_elements(nodes) do
    {chunks, index, _offset} =
      Enum.reduce(nodes, {[], [], 0}, fn node, {chunks, index, offset} ->
        line = encode_ir_node(node) <> "\n"
        size = byte_size(line)
        entry = {{offset, size}, node_field(node, "ref")}
        {[line | chunks], [entry | index], offset + size}
      end)

    bytes = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    %{
      bytes: bytes,
      line_index: Enum.reverse(index),
      fingerprint: :erlang.phash2(bytes)
    }
  end

  # Deterministic JSON for one IR node: keys sorted recursively (via
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

  # --- write-back: edited IR JSONL -> direct text edits on the live doc -------

  @doc """
  Apply a direct overwrite of the projected `.md` back onto the live document at
  `abs_path` (FUSE write-back / Phase 2). Diffs the incoming `new_bytes` text
  against the current projection's editable lines and applies one `replace_text`
  per changed paragraph (via the same edit engine `doc.edit` uses), so the agent
  editing the mounted file IS editing the document.

  `opts`: `:root` (workspace root, for the edit ctx path guard).

  Returns `{:ok, %{applied: n, doc: name}}`, or `{:error, reason}` —
  `:structural_change` when the paragraph COUNT changed (add/remove a line, which
  this v1 does not route — use `doc.*` for structural edits), `:unroutable` when
  a changed line maps to a non-paragraph node (table/control), or an engine
  error. Never raises. On success, broadcasts `{:vfs_doc_edited, info}` on
  `doc_vfs:<root>` so the chat rail can show where the edit landed.
  """
  @spec write_back(String.t(), binary(), keyword()) ::
          {:ok, %{applied: non_neg_integer(), doc: String.t()}} | {:error, term()}
  def write_back(abs_path, new_bytes, opts \\ [])
      when is_binary(abs_path) and is_binary(new_bytes) do
    with {:ok, old_nodes} <- ir_nodes(abs_path),
         {:ok, new_nodes} <- parse_ir_jsonl(new_bytes) do
      cond do
        # A line added/removed/reordered changes the node count — a structural
        # edit this v1 does not route (use `doc.*` for insert/delete/move).
        length(new_nodes) != length(old_nodes) ->
          {:error, :structural_change}

        true ->
          case compute_ir_changes(old_nodes, new_nodes) do
            {:error, reason} -> {:error, reason}
            [] -> {:ok, %{applied: 0, doc: Path.basename(abs_path)}}
            changes -> apply_changes(abs_path, changes, opts)
          end
      end
    end
  rescue
    error -> {:error, {:writeback_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The document's current IR nodes — the OLD state write-back diffs against.
  defp ir_nodes(abs_path) do
    with {:ok, kind} <- kind_for(abs_path),
         {:ok, document_id} <- Pool.open(abs_path, kind: kind) do
      elements(document_id)
    end
  end

  # Parse the edited file back into IR nodes: one JSON object per non-empty line.
  defp parse_ir_jsonl(bytes) do
    bytes
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, %{} = node} -> {:cont, {:ok, [node | acc]}}
        {:ok, _other} -> {:halt, {:error, {:invalid_ir_line, String.slice(line, 0, 80)}}}
        {:error, _} -> {:halt, {:error, {:invalid_ir_json, String.slice(line, 0, 80)}}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      error -> error
    end
  end

  # Diff old vs new IR node-by-node (positional; `ref` is the stable identity).
  # A changed `"text"` on a routable node becomes a `{ref, old, new}` text edit;
  # a changed `ref` is a structural change; a text change on a non-routable node
  # (table/control/cell) is `:unroutable`.
  defp compute_ir_changes(old_nodes, new_nodes) do
    old_nodes
    |> Enum.zip(new_nodes)
    |> Enum.reduce_while([], fn {old, new}, acc ->
      old_ref = node_field(old, "ref")
      new_ref = node_field(new, "ref")
      old_text = node_field(old, "text")
      new_text = node_field(new, "text")

      cond do
        old_ref != new_ref ->
          {:halt, {:error, :structural_change}}

        old_text == new_text ->
          {:cont, acc}

        not is_binary(new_text) ->
          {:halt, {:error, :unroutable}}

        true ->
          case encode_op_ref(old_ref) do
            nil -> {:halt, {:error, :unroutable}}
            ref -> {:cont, [{ref, old_text, new_text} | acc]}
          end
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      changes -> changes |> Enum.reverse() |> dedup_office_runs()
    end
  end

  # Office emits both a paragraph (`p1`) and its child run (`p1/r0`) carrying the
  # same text; an edit touching both (e.g. `sed` over the JSONL) yields two
  # changes. Keep only the parent — one paragraph-level `replace_text` suffices;
  # applying the child too would no-op or fail. rhwp emits no run nodes, so this
  # only affects office string refs.
  defp dedup_office_runs(changes) do
    refs = MapSet.new(changes, fn {ref, _old, _new} -> ref end)

    Enum.reject(changes, fn {ref, _old, _new} ->
      is_binary(ref) and
        Enum.any?(refs, fn parent ->
          is_binary(parent) and parent != ref and String.starts_with?(ref, parent <> "/")
        end)
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
         :ok <- apply_ops_directly(editor, changes),
         :ok <- save_editor(editor, abs_path, kind) do
      broadcast_edit(abs_path, changes, opts)
      {:ok, %{applied: length(changes), doc: Path.basename(abs_path)}}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:writeback_unroutable, other}}
    end
  end

  defp apply_ops_directly(editor, changes) do
    Enum.reduce_while(changes, :ok, fn {ref, old, new}, _acc ->
      op = %{"op" => "replace_text", "ref" => ref, "query" => old, "replacement" => new}

      case Editor.apply(editor, op) do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

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

  # Office refs are op-applicable strings ("p3"). rhwp refs are maps; encode a
  # plain paragraph to "hwp:s<sec>/p<para>". Table/control nodes are not routable
  # by a text replace -> nil (the write-back rejects a change that lands on one).
  defp encode_op_ref(ref) when is_binary(ref), do: ref

  defp encode_op_ref(%{} = ref) do
    section = ref["section"]
    paragraph = ref["paragraph"]

    cond do
      ref["type"] in ["table", "control"] -> nil
      Map.has_key?(ref, "control") -> nil
      is_integer(section) and is_integer(paragraph) -> "hwp:s#{section}/p#{paragraph}"
      true -> nil
    end
  end

  defp encode_op_ref(_ref), do: nil

  defp broadcast_edit(abs_path, changes, opts) do
    root = opts[:root]

    if is_binary(root) do
      hit = Enum.find_value(changes, fn {_ref, _old, new} -> new end)

      # Carry the applied edits as `replace_text` ops so the viewer can LIVE-STREAM
      # the change into the open editor incrementally (apply op + repaint the one
      # page) instead of reloading the whole document.
      ops =
        Enum.map(changes, fn {ref, old, new} ->
          %{"op" => "replace_text", "ref" => ref, "query" => old, "replacement" => new}
        end)

      Phoenix.PubSub.broadcast(
        Ecrits.PubSub,
        "doc_vfs:" <> Path.expand(root),
        {:vfs_doc_edited,
         %{
           path: abs_path,
           doc: Path.basename(abs_path),
           applied: length(changes),
           marker: hit,
           ops: ops
         }}
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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
