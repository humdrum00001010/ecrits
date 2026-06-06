defmodule Ecrits.Doc.Pool do
  @moduledoc """
  Multi-document registry (design §4.3).

  The Pool maps `document_id => %{kind, backing, editor_pid, path, revision}`
  and starts exactly one `Ecrits.Doc.Editor` per document. Documents run in
  parallel (separate Editors), while a single document's ops are serial (its
  Editor's mailbox).

    * `open/3`     — load a document into the pool (need not be the one the
      session is viewing).
    * `list/1`     — `[%{id, kind, path, revision, backing}]`.
    * `with_doc/3` — run a function against a document's Editor (serial).
    * `route/2`    — where the authoritative model lives: `{:server, editor}`
      for headless/Office docs, `{:browser, lv_pid}` for a viewed HWP doc.
    * `close/2`    — drop a document.

  `backing` is `:server` for the headless HWP/Office case (NIF authority). The
  `:browser` backing (viewed HWP → WASM authority, agent ops pushed to the
  LiveView) is represented but not exercised here: browser registration is the
  live LiveView wiring left for follow-up. `route/2` returns `{:browser, pid}`
  once a viewer registers via `attach_browser/3`.
  """

  use GenServer

  alias Ecrits.Doc
  alias Ecrits.Doc.Editor

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
    * `dirty` only — current revision ahead of the last `save` (so a doc that
      already `doc.save`d, or one that was opened/cloned but never edited, is
      excluded → the auto-save is idempotent and a no-op).
    * `save_target` only — a doc with no on-disk path is skipped rather than
      written to a guessed location.
  """
  @spec dirty_docs(GenServer.server()) :: [%{id: document_id(), kind: atom(), editor: pid(), path: String.t()}]
  def dirty_docs(pool \\ @default_name), do: GenServer.call(pool, :dirty_docs)

  @spec with_doc(GenServer.server(), document_id(), (Editor.t() -> term())) ::
          term() | {:error, :not_found}
  def with_doc(pool \\ @default_name, document_id, fun) when is_function(fun, 1) do
    case GenServer.call(pool, {:editor, document_id}) do
      {:ok, editor} -> fun.(editor)
      {:error, _} = error -> error
    end
  end

  @doc "Authoritative location of a document's model."
  @spec route(GenServer.server(), document_id()) ::
          {:server, Editor.t()} | {:browser, pid()} | {:error, :not_found}
  def route(pool \\ @default_name, document_id),
    do: GenServer.call(pool, {:route, document_id})

  @doc """
  Register a viewing LiveView as the browser authority for `document_id`.

  A viewer is the browser authority for AT MOST ONE document — the one it is
  currently rendering in its WASM model. Attaching `lv_pid` to a document
  therefore *detaches* it from any OTHER document it was previously the browser
  authority for, so navigating between documents in one viewer never leaves a
  stale `:browser` backing behind. (The viewer's browser bridge always targets
  its single open doc, so a stale attachment would otherwise route an unrelated
  doc's edits to the wrong, currently-viewed document — design §6.2.)
  """
  @spec attach_browser(GenServer.server(), document_id(), pid()) :: :ok | {:error, :not_found}
  def attach_browser(pool \\ @default_name, document_id, lv_pid) when is_pid(lv_pid),
    do: GenServer.call(pool, {:attach_browser, document_id, lv_pid})

  @doc """
  Relinquish `lv_pid`'s browser authority over `document_id` (if it holds it).

  The document falls back to its server NIF editor. Used when a viewer closes a
  document or navigates to a non-pooled file. A no-op when `lv_pid` is not the
  current browser owner of `document_id`.
  """
  @spec detach_browser(GenServer.server(), document_id(), pid()) :: :ok
  def detach_browser(pool \\ @default_name, document_id, lv_pid) when is_pid(lv_pid),
    do: GenServer.call(pool, {:detach_browser, document_id, lv_pid})

  @spec info(GenServer.server(), document_id()) :: {:ok, map()} | {:error, :not_found}
  def info(pool \\ @default_name, document_id),
    do: GenServer.call(pool, {:info, document_id})

  @doc """
  Mark `document_id` as the active/focused document (the one the user is
  viewing). `doc.context` surfaces this as `active_document`. Returns
  `{:error, :not_found}` if the document is not in the pool.
  """
  @spec set_active(GenServer.server(), document_id()) :: :ok | {:error, :not_found}
  def set_active(pool \\ @default_name, document_id),
    do: GenServer.call(pool, {:set_active, document_id})

  @doc "Clear the active document if (and only if) it is `document_id`."
  @spec clear_active(GenServer.server(), document_id()) :: :ok
  def clear_active(pool \\ @default_name, document_id),
    do: GenServer.call(pool, {:clear_active, document_id})

  @doc "The active document id, or nil when none is set / it is gone."
  @spec active(GenServer.server()) :: document_id() | nil
  def active(pool \\ @default_name), do: GenServer.call(pool, :active)

  @spec close(GenServer.server(), document_id()) :: :ok | {:error, :not_found}
  def close(pool \\ @default_name, document_id),
    do: GenServer.call(pool, {:close, document_id})

  # --- server --------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, %{sup: sup, docs: %{}, by_path: %{}, active: nil}}
  end

  @impl true
  def handle_call({:open, path, opts}, _from, st) do
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
          revision: revision(doc),
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
        # A doc routes to the browser WASM ONLY while its viewer is alive. If the
        # LiveView that claimed it has died (an orphaned attachment — pre-fix
        # legacy, or a navigate/close race before {:DOWN} is processed), fall back
        # to the headless server editor so the doc stays reachable instead of
        # routing to a dead pid.
        %{browser: lv} = doc when is_pid(lv) ->
          cond do
            Process.alive?(lv) -> {:browser, lv}
            is_pid(doc[:editor]) -> {:server, doc[:editor]}
            true -> {:error, :not_found}
          end

        %{editor: editor} when is_pid(editor) -> {:server, editor}
        _ -> {:error, :not_found}
      end

    {:reply, reply, st}
  end

  def handle_call({:attach_browser, document_id, lv_pid}, _from, st) do
    case Map.get(st.docs, document_id) do
      nil ->
        {:reply, {:error, :not_found}, st}

      _doc ->
        Process.monitor(lv_pid)
        # A viewer authoritatively renders ONE document. Drop any other doc this
        # same lv_pid was browser-backing (a previously-viewed doc it navigated
        # away from) before claiming this one, so exactly the currently-viewed
        # doc routes `:browser` and everything else routes to its server editor.
        docs = detach_pid_everywhere(st.docs, lv_pid)
        docs = put_in(docs[document_id].browser, lv_pid)
        {:reply, :ok, %{st | docs: docs}}
    end
  end

  def handle_call({:detach_browser, document_id, lv_pid}, _from, st) do
    docs =
      case Map.get(st.docs, document_id) do
        %{browser: ^lv_pid} = doc -> Map.put(st.docs, document_id, Map.put(doc, :browser, nil))
        _ -> st.docs
      end

    {:reply, :ok, %{st | docs: docs}}
  end

  def handle_call({:info, document_id}, _from, st) do
    reply =
      case Map.get(st.docs, document_id) do
        nil ->
          {:error, :not_found}

        doc ->
          {:ok,
           %{
             id: document_id,
             kind: doc.kind,
             path: doc.path,
             revision: revision(doc),
             backing: backing(doc)
           }}
      end

    {:reply, reply, st}
  end

  def handle_call({:set_active, document_id}, _from, st) do
    if Map.has_key?(st.docs, document_id) do
      {:reply, :ok, %{st | active: document_id}}
    else
      {:reply, {:error, :not_found}, st}
    end
  end

  def handle_call({:clear_active, document_id}, _from, st) do
    active = if st.active == document_id, do: nil, else: st.active
    {:reply, :ok, %{st | active: active}}
  end

  def handle_call(:active, _from, st) do
    {:reply, st.active, st}
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
        active = if st.active == document_id, do: nil, else: st.active
        {:reply, :ok, %{st | docs: docs, by_path: by_path, active: active}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, st) do
    # an editor or an attached browser LV went down
    docs =
      st.docs
      |> Enum.reduce(%{}, fn {id, doc}, acc ->
        cond do
          doc.editor == pid -> acc
          true -> Map.put(acc, id, doc)
        end
      end)
      # A crashed viewer relinquishes its browser claim on every doc it backed
      # (set to nil, keeping the uniform doc shape) so those docs fall back to
      # their server editors.
      |> detach_pid_everywhere(pid)

    active = if st.active && Map.has_key?(docs, st.active), do: st.active, else: nil
    {:noreply, %{st | docs: docs, active: active}}
  end

  # --- helpers -------------------------------------------------------------

  # Clear `lv_pid`'s `:browser` claim from EVERY document it currently backs.
  # Keeps the `:browser` key (set to nil) so the doc shape stays uniform and
  # `route/2` falls back to the server editor for it.
  defp detach_pid_everywhere(docs, lv_pid) do
    Map.new(docs, fn
      {id, %{browser: ^lv_pid} = doc} -> {id, %{doc | browser: nil}}
      {id, doc} -> {id, doc}
    end)
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

        doc = %{kind: kind, backend: backend, path: path, editor: editor, browser: nil}

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

  # A pooled doc qualifies for turn-end auto-save iff it is server-backed (no
  # attached browser viewer), its Editor is alive and dirty, and it has a real
  # save-target path. Anything else yields [] so the turn handler skips it.
  defp dirty_entry(id, %{browser: lv}) when is_pid(lv), do: dirty_entry_browser(id, lv)

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

  # Browser-backed docs are never auto-persisted from the server copy.
  defp dirty_entry_browser(_id, _lv), do: []

  defp fetch_editor(st, document_id) do
    case Map.get(st.docs, document_id) do
      %{editor: editor} when is_pid(editor) -> {:ok, editor}
      _ -> {:error, :not_found}
    end
  end

  defp revision(%{editor: editor}) when is_pid(editor) do
    if Process.alive?(editor), do: Editor.revision(editor), else: 0
  end

  defp revision(_doc), do: 0

  defp backing(%{browser: lv}) when is_pid(lv), do: :browser
  defp backing(_doc), do: :server

  defp document_id_for(path, kind) do
    hash =
      :crypto.hash(:sha256, "#{kind}:#{path}")
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 16)

    "d_#{kind}_#{hash}"
  end
end
