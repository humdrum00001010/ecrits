defmodule Ecrits.Doc.Pool do
  @moduledoc """
  Multi-document registry (design §4.3).

  The Pool maps `document_id => %{kind, editor_pid, path}` and starts
  exactly one `Ecrits.Doc.Editor` per document. Documents run in parallel
  (separate Editors), while a single document's ops are serial (its Editor's
  mailbox).

    * `open/3`     — load a document into the pool (need not be the one the
      session is viewing).
    * `list/1`     — `[%{id, kind, path, backing}]`.
    * `with_doc/3` — run a function against a document's Editor (serial).
    * `route/2`    — where the authoritative SERVER model lives: `{:server,
      editor}` for an open doc, `{:error, :not_found}` otherwise.
    * `close/2`    — drop a document.

  Since Phase 3 the Pool is a **server-side doc-runtime registry ONLY**. Three
  cross-cutting concerns that the design assigns to the *edges* moved out of it:

    * the **wasm/NIF routing decision** + the human-viewer registry (`viewers`)
      → `Ecrits.Workspace.Session` (it calls back to `route/2` for the server
      editor when no viewer is attached);
    * **per-agent doc ownership** (`owners`, invariant 2) → `Ecrits.Workspace.Session`;
    * the **global active document** — DELETED; each agent's active doc is its
      own AgentLive state (`pool_document_id`).

  `backing` in `list/1`/`info/2` is therefore always `:server` here (the Pool
  never holds the browser arm); the Session overlays the browser view on top.
  """

  use GenServer

  alias Ecrits.Doc
  alias Ecrits.Doc.Editor
  alias Ecrits.Fuse.DocMount

  @default_name __MODULE__

  @type document_id :: String.t()

  # --- client API ----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @default_name)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, @default_name),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Open `path` into the default-named pool. Returns a stable `document_id`
  (same path/kind opened twice returns the same id and reuses the Editor).
  """
  @spec open(String.t(), keyword()) :: {:ok, document_id()} | {:error, term()}
  def open(path, opts \\ []) when is_binary(path) and is_list(opts),
    do: open(@default_name, path, opts)

  @doc """
  Open `path` into an explicit `pool` process.

  Kept distinct from `open/2` (path + opts) to avoid the two-defaults arg
  ambiguity that would otherwise bind a path string to the `pool` parameter.
  """
  @spec open(GenServer.server(), String.t(), keyword()) ::
          {:ok, document_id()} | {:error, term()}
  def open(pool, path, opts) when is_binary(path) and is_list(opts) do
    GenServer.call(pool, {:open, path, opts})
  end

  @doc """
  Create a NEW empty document whose save target is `path` (the file need not
  exist yet). Returns a stable `document_id`. Mirrors `open/2` but mints a blank
  engine document instead of reading bytes off disk.
  """
  @spec create(String.t(), keyword()) :: {:ok, document_id()} | {:error, term()}
  def create(path, opts \\ []) when is_binary(path) and is_list(opts),
    do: create(@default_name, path, opts)

  @spec create(GenServer.server(), String.t(), keyword()) ::
          {:ok, document_id()} | {:error, term()}
  def create(pool, path, opts) when is_binary(path) and is_list(opts) do
    GenServer.call(pool, {:create, path, opts})
  end

  @spec list(GenServer.server()) :: [map()]
  def list(pool \\ @default_name), do: GenServer.call(pool, :list)

  @doc """
  Enumerate the **server-backed** documents that have unsaved agent edits AND a
  real save-target path — the set the turn-end auto-save should persist.

  Each entry is `%{id, kind, editor, path}`. The predicate is deliberately
  conservative:

    * `:server` backing only — a **browser-backed** (currently-viewed) doc is
      NEVER auto-overwritten here; its authority is the WASM model, not the
      Editor, so persisting the (unedited) server copy would clobber it.
    * `dirty` only — in-memory edits since the last `save` (so a doc that
      already `doc.save`d, or one that was opened/cloned but never edited, is
      excluded → the auto-save is idempotent and a no-op).
    * `save_target` only — a doc with no on-disk path is skipped rather than
      written to a guessed location.
  """
  @spec dirty_docs(GenServer.server()) :: [
          %{id: document_id(), kind: atom(), editor: pid(), path: String.t()}
        ]
  def dirty_docs(pool \\ @default_name), do: GenServer.call(pool, :dirty_docs)

  @spec with_doc(GenServer.server(), document_id(), (Editor.t() -> term())) ::
          term() | {:error, :not_found}
  def with_doc(pool \\ @default_name, document_id, fun) when is_function(fun, 1) do
    case GenServer.call(pool, {:editor, document_id}) do
      {:ok, editor} -> fun.(editor)
      {:error, _} = error -> error
    end
  end

  @doc """
  Authoritative location of a document's SERVER model: `{:server, editor}` for an
  open doc, `{:error, :not_found}` otherwise.

  Since Phase 3 the Pool is a server-side doc-runtime registry ONLY — it no
  longer knows about human viewers / the browser WASM arm. The wasm/NIF routing
  decision (`{:browser, lv}` vs `{:server, editor}`) is made by
  `Ecrits.Workspace.Session`, which holds the `viewers` map and falls back to
  THIS `route/2` for the server editor.
  """
  @spec route(GenServer.server(), document_id()) ::
          {:server, Editor.t()} | {:error, :not_found}
  def route(pool \\ @default_name, document_id),
    do: GenServer.call(pool, {:route, document_id})

  @spec info(GenServer.server(), document_id()) :: {:ok, map()} | {:error, :not_found}
  def info(pool \\ @default_name, document_id),
    do: GenServer.call(pool, {:info, document_id})

  @spec info_by_path(GenServer.server(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def info_by_path(pool \\ @default_name, path) when is_binary(path),
    do: GenServer.call(pool, {:info_by_path, path})

  @spec close(GenServer.server(), document_id()) :: :ok | {:error, :not_found}
  def close(pool \\ @default_name, document_id),
    do: GenServer.call(pool, {:close, document_id})

  @doc """
  Close the twin for the doc at absolute `path` — terminates its Editor, whose
  `terminate/2` runs `backend.close/1` (for office: `uno_close`, which releases
  the LibreOffice `.~lock.<file>#`). No-op when no twin is open for `path`.

  Used when a workspace TAB is explicitly closed: the user is done with the doc,
  so the server twin (and, for office, its held UNO session + on-disk lock) must
  be released. A viewer DETACH (tab switch / navigate-away) deliberately leaves
  the twin in the pool; only an explicit close disposes it. Re-opening the path
  transparently re-creates the twin.
  """
  @spec close_by_path(GenServer.server(), String.t()) :: :ok
  def close_by_path(pool \\ @default_name, path) when is_binary(path) do
    case info_by_path(pool, path) do
      {:ok, %{id: id}} -> _ = close(pool, id)
      _ -> :ok
    end

    :ok
  end

  @doc """
  Refresh the SERVER twin of the doc at `path` from authoritative `bytes` (a
  browser-viewer checkpoint). While a doc is viewed, the browser WASM model is
  the authority and this pool's editor is only a shadow opened from disk —
  without this sync every viewer detach (tab switch / navigate) leaves a stale
  NIF copy that a later server-routed export would write over the browser's
  edits. No-op when no server twin is open for `path`.
  """
  @spec refresh_by_path(GenServer.server(), String.t(), binary()) :: :ok | {:error, term()}
  def refresh_by_path(pool \\ @default_name, path, bytes)
      when is_binary(path) and is_binary(bytes) do
    case info_by_path(pool, path) do
      {:ok, %{id: document_id}} ->
        with_doc(pool, document_id, &Editor.reload_from_bytes(&1, bytes))

      _ ->
        :ok
    end
  end

  # --- server --------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, %{sup: sup, docs: %{}, by_path: %{}}}
  end

  @impl true
  def handle_call({:open, path, opts}, _from, st) do
    path = canonical_path(path)
    kind = Keyword.get(opts, :kind, :hwp)

    case Doc.backend_for(kind) do
      nil ->
        {:reply, {:error, {:unsupported_kind, kind}}, st}

      backend ->
        document_id = Keyword.get(opts, :document_id) || document_id_for(path, kind)

        case Map.get(st.docs, document_id) do
          %{editor: editor} when is_pid(editor) ->
            if Process.alive?(editor),
              do: {:reply, {:ok, document_id}, st},
              else: do_open(st, document_id, path, kind, backend, opts)

          _ ->
            do_open(st, document_id, path, kind, backend, opts)
        end
    end
  end

  def handle_call({:create, path, opts}, _from, st) do
    path = canonical_path(path)
    kind = Keyword.get(opts, :kind, :hwp)

    case Doc.backend_for(kind) do
      nil ->
        {:reply, {:error, {:unsupported_kind, kind}}, st}

      backend ->
        document_id = Keyword.get(opts, :document_id) || document_id_for(path, kind)
        # Reuse the same start/registration path as open, flagging the Editor to
        # mint a blank document instead of reading `path`.
        do_open(st, document_id, path, kind, backend, Keyword.put(opts, :create?, true))
    end
  end

  def handle_call(:list, _from, st) do
    entries =
      Enum.map(st.docs, fn {id, doc} ->
        %{
          id: id,
          kind: doc.kind,
          path: doc.path,
          backing: backing(doc)
        }
      end)

    {:reply, entries, st}
  end

  def handle_call(:dirty_docs, _from, st) do
    entries =
      st.docs
      |> Enum.flat_map(fn {id, doc} -> dirty_entry(id, doc) end)

    {:reply, entries, st}
  end

  def handle_call({:editor, document_id}, _from, st) do
    {:reply, fetch_editor(st, document_id), st}
  end

  def handle_call({:route, document_id}, _from, st) do
    reply =
      case Map.get(st.docs, document_id) do
        %{editor: editor} when is_pid(editor) -> {:server, editor}
        _ -> {:error, :not_found}
      end

    {:reply, reply, st}
  end

  def handle_call({:info, document_id}, _from, st) do
    reply =
      case Map.get(st.docs, document_id) do
        nil -> {:error, :not_found}
        doc -> {:ok, info_entry(document_id, doc)}
      end

    {:reply, reply, st}
  end

  def handle_call({:info_by_path, path}, _from, st) do
    path = canonical_path(path)

    reply =
      with document_id when is_binary(document_id) <- Map.get(st.by_path, path),
           doc when is_map(doc) <- Map.get(st.docs, document_id) do
        {:ok, info_entry(document_id, doc)}
      else
        _ -> {:error, :not_found}
      end

    {:reply, reply, st}
  end

  def handle_call({:close, document_id}, _from, st) do
    case Map.pop(st.docs, document_id) do
      {nil, _docs} ->
        {:reply, {:error, :not_found}, st}

      {doc, docs} ->
        if is_pid(doc.editor) and Process.alive?(doc.editor) do
          DynamicSupervisor.terminate_child(st.sup, doc.editor)
        end

        by_path = Map.delete(st.by_path, doc.path)
        {:reply, :ok, %{st | docs: docs, by_path: by_path}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, st) do
    # an editor went down — drop its doc from the registry
    docs =
      st.docs
      |> Enum.reject(fn {_id, doc} -> doc.editor == pid end)
      |> Map.new()

    {:noreply, %{st | docs: docs}}
  end

  # --- helpers -------------------------------------------------------------

  defp info_entry(document_id, doc) do
    %{
      id: document_id,
      kind: doc.kind,
      path: doc.path,
      backing: backing(doc)
    }
  end

  defp do_open(st, document_id, path, kind, backend, opts) do
    editor_opts = [
      document_id: document_id,
      kind: kind,
      backend: backend,
      path: path,
      create?: Keyword.get(opts, :create?, false),
      open_opts: Keyword.get(opts, :open_opts, [])
    ]

    case DynamicSupervisor.start_child(st.sup, {Editor, editor_opts}) do
      {:ok, editor} ->
        Process.monitor(editor)

        doc = %{kind: kind, backend: backend, path: path, editor: editor}

        st = %{
          st
          | docs: Map.put(st.docs, document_id, doc),
            by_path: Map.put(st.by_path, path, document_id)
        }

        {:reply, {:ok, document_id}, st}

      {:error, reason} ->
        {:reply, {:error, {:open_failed, reason}}, st}
    end
  end

  # A pooled doc qualifies for turn-end auto-save iff its Editor is alive and
  # dirty AND it has a real save-target path. A doc the user is VIEWING (browser
  # WASM authority) has an unedited server Editor — the agent's edits went to the
  # browser, not the NIF — so it is clean and excluded here too, without the
  # Pool needing to know about viewers (that lives in the Session now).
  defp dirty_entry(id, %{editor: editor, kind: kind}) when is_pid(editor) do
    if Process.alive?(editor) and Editor.dirty?(editor) do
      case Editor.save_target(editor) do
        {:ok, path} -> [%{id: id, kind: kind, editor: editor, path: path}]
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp dirty_entry(_id, _doc), do: []

  defp fetch_editor(st, document_id) do
    case Map.get(st.docs, document_id) do
      %{editor: editor} when is_pid(editor) -> {:ok, editor}
      _ -> {:error, :not_found}
    end
  end

  # The Pool only ever holds the server NIF arm; the browser view is overlaid by
  # the Session, so a Pool entry's backing is always `:server`.
  defp backing(_doc), do: :server

  @doc """
  The stable document id `open/3` would mint for `path` + `kind` (sha-derived,
  path/kind-keyed). Exposed so callers can decide whether a doc is already open
  BEFORE calling `open/3` (the `doc.open` already-open invariant).
  """
  @spec document_id_for(String.t(), atom()) :: document_id()
  def document_id_for(path, kind) do
    path = canonical_path(path)

    hash =
      :crypto.hash(:sha256, "#{kind}:#{path}")
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 16)

    "d_#{kind}_#{hash}"
  end

  defp canonical_path(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      path = Path.expand(path)
      Path.join(DocMount.canonical_root(Path.dirname(path)), Path.basename(path))
    else
      path
    end
  end
end
