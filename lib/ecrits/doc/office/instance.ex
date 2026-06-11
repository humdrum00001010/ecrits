defmodule Ecrits.Doc.Office.Instance do
  @moduledoc """
  The single serializing governor for the in-process LibreOffice UNO NIF
  (design §2.1 / Phase 3 backend governor).

  The office backend (`Ecrits.Doc.Office`) is NOT a remote process or a pool of
  workers: it is an **in-process NIF** that boots ONE LibreOffice instance
  (`lok_cpp_init`, a process-wide singleton), serialised by LO's SolarMutex, and
  crash-coupled to the BEAM (a hard UNO fault takes the node). So unlike the HWP
  backend — where each ehwp doc is a cheap, independent NIF resource that runs in
  parallel — every office op MUST go through one place.

  This GenServer IS that place. Its mailbox is the serializer: every `open`,
  `edit`, `get`, `set`, `save`, `read`, … runs inside `handle_call`, so two
  office docs (or two agents) can never drive the UNO model concurrently. We do
  NOT add an analogous serializer for HWP/ehwp — that backend is cheap per-doc
  and parallel, and a serializer there would be pure contention.

  ## Stable handle token (so the LRU is transparent)

  The `Ecrits.Doc.Editor` holds ONE opaque handle for the life of a document. If
  that handle were the raw NIF `session` resource, evicting + reopening a doc
  would invalidate the Editor's handle. So the handle the backend hands the
  Editor is a **stable token** — `%{doc: doc_token, kind, path}` — and the
  Instance maps `doc_token => live UNO session`. The Editor's token never
  changes; the live session behind it may be released and rematerialised under
  the LRU without the Editor ever knowing.

  ## LRU UNO-doc budget (`@budget`)

  Each materialised UNO document holds a real `XComponent` (memory + the office's
  own per-doc state). We cap the number of SIMULTANEOUSLY-materialised docs at a
  small budget. On opening over budget we pick the least-recently-used OTHER doc,
  **save-then-close** it (persist its edits to disk, dispose the XComponent,
  release the NIF resource), and remember its open args. The next op that targets
  an evicted doc **transparently rematerialises** it from disk (its saved bytes)
  before running — so an older doc stays editable after eviction, the agent never
  sees the eviction, and the office never holds more than `@budget` live docs.

  A doc with NO real on-disk save target (a blank/unsaved doc) is NEVER evicted
  (there is nowhere to persist it to and nothing to reopen from); it pins a slot.
  """

  use GenServer

  alias Ecrits.Doc.Office.Native, as: OfficeNative

  @name __MODULE__

  # Number of UNO documents that may be materialised at once. Small on purpose:
  # each live XComponent costs memory + office per-doc state, and the office is a
  # single serialised instance, so a deep working set buys nothing. On opening
  # over this, the LRU evicts (save-then-close) the least-recently-used doc.
  @budget 3

  @typedoc "The stable token the Editor holds; resolves to a live UNO session here."
  @type doc_token :: reference()

  @typedoc "The backend handle: a stable token + the doc's kind/path (NOT the raw NIF session)."
  @type handle :: %{doc: doc_token(), kind: :docx | :pptx, path: String.t() | nil}

  # ── public API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, @name),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "The materialised-document budget (max simultaneously-live UNO docs)."
  @spec budget() :: pos_integer()
  def budget, do: @budget

  @doc """
  Open `path` (a docx/pptx) under the governor. Returns a stable backend
  `handle` (`%{doc, kind, path}`) the Editor holds for the document's life — its
  `doc` token survives LRU eviction/rematerialisation. Opening over `@budget`
  evicts the LRU doc (save-then-close) first.
  """
  @spec open(GenServer.server(), String.t(), keyword()) :: {:ok, handle()} | {:error, term()}
  def open(server \\ @name, path, opts) when is_binary(path) and is_list(opts) do
    GenServer.call(server, {:open, path, opts}, :infinity)
  end

  @doc """
  Write a LibreOffice factory-blank document to `path` (one-shot open factory ->
  export -> close), serialised through this governor like every other NIF touch.
  """
  @spec create_blank_file(GenServer.server(), String.t(), :docx | :pptx) ::
          :ok | {:error, term()}
  def create_blank_file(server \\ @name, path, kind) when is_binary(path) do
    GenServer.call(server, {:create_blank_file, path, kind}, :infinity)
  end

  @doc "Close + forget a document (dispose its UNO session, drop the LRU slot)."
  @spec close(GenServer.server(), handle()) :: :ok
  def close(server \\ @name, handle)

  def close(server, %{doc: doc}), do: GenServer.call(server, {:close, doc}, :infinity)
  def close(_server, _handle), do: :ok

  @doc """
  Run a UNO NIF call for `handle`'s document, serialised through this GenServer
  and transparently rematerialising the doc first if the LRU evicted it.

  `fun` is `(session -> result)` — the closure that issues the actual
  `Native.uno_*` call against the live session. Every `Ecrits.Doc.Office`
  callback funnels through here so the in-process NIF is touched from exactly one
  place, one op at a time.
  """
  @spec run(handle(), (term() -> result)) :: result | {:error, term()} when result: term()
  def run(handle, fun) when is_function(fun, 1), do: run(@name, handle, fun, [])

  @doc """
  Like `run/2`, with options. `write?: true` marks the doc dirty so its next LRU
  eviction is save-then-close (persisting the edit); reads leave it clean so an
  unedited doc is reopened from its original bytes (idempotent, no rewrite).
  """
  @spec run(GenServer.server(), handle(), (term() -> result), keyword()) ::
          result | {:error, term()}
        when result: term()
  def run(server \\ @name, handle, fun, opts)

  def run(server, %{doc: doc}, fun, opts) when is_function(fun, 1) do
    GenServer.call(server, {:run, doc, fun, Keyword.get(opts, :write?, false)}, :infinity)
  end

  def run(_server, _handle, _fun, _opts), do: {:error, :invalid_handle}

  # ── GenServer ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # docs: %{doc_token => entry}
    #   entry: %{session, kind, path, open_opts, install_dir, profile, dirty?, materialised?}
    # lru: [doc_token] — most-recently-used first.
    {:ok, %{docs: %{}, lru: []}}
  end

  @impl true
  def handle_call({:open, path, opts}, _from, st) do
    case OfficeNative.open_session(path, opts) do
      {:ok,
       %{session: session, kind: kind, path: abs, install_dir: install_dir, profile: profile}} ->
        doc = make_ref()

        entry = %{
          session: session,
          kind: kind,
          path: abs,
          open_opts: opts,
          install_dir: install_dir,
          profile: profile,
          dirty?: false,
          materialised?: true
        }

        st =
          st
          |> put_entry(doc, entry)
          |> touch(doc)
          |> enforce_budget(doc)

        {:reply, {:ok, %{doc: doc, kind: kind, path: abs}}, st}

      {:error, _reason} = error ->
        {:reply, error, st}
    end
  end

  def handle_call({:create_blank_file, path, kind}, _from, st) do
    {:reply, OfficeNative.create_blank_file(path, kind), st}
  end

  def handle_call({:close, doc}, _from, st) do
    st =
      case Map.get(st.docs, doc) do
        %{session: session, materialised?: true} ->
          _ = OfficeNative.close_session(session)
          drop(st, doc)

        %{} ->
          drop(st, doc)

        nil ->
          st
      end

    {:reply, :ok, st}
  end

  def handle_call({:run, doc, fun, write?}, _from, st) do
    case Map.get(st.docs, doc) do
      nil ->
        {:reply, {:error, :not_found}, st}

      _entry ->
        case ensure_materialised(st, doc) do
          {:ok, st, %{session: session}} ->
            result = fun.(session)
            st = st |> mark_dirty_if_write(doc, write?, result) |> touch(doc)
            {:reply, result, st}

          {:error, reason, st} ->
            {:reply, {:error, reason}, st}
        end
    end
  end

  @impl true
  def terminate(_reason, st) do
    # Best-effort: persist + dispose every live doc so the office releases cleanly.
    Enum.each(st.docs, fn
      {_doc, %{session: session, materialised?: true} = entry} ->
        _ = maybe_save(entry)
        _ = OfficeNative.close_session(session)

      _ ->
        :ok
    end)

    :ok
  end

  # ── LRU + (re)materialisation ──────────────────────────────────────

  # Ensure `doc` has a live UNO session, reopening it from disk (its saved bytes)
  # if the LRU evicted it. Reopening counts against the budget, so it may evict a
  # DIFFERENT doc in turn.
  defp ensure_materialised(st, doc) do
    case Map.get(st.docs, doc) do
      %{materialised?: true} = entry ->
        {:ok, st, entry}

      %{materialised?: false} = entry ->
        rematerialise(st, doc, entry)

      nil ->
        {:error, :not_found, st}
    end
  end

  defp rematerialise(st, doc, entry) do
    case OfficeNative.reopen_session(entry) do
      {:ok, session} ->
        entry = %{entry | session: session, materialised?: true, dirty?: false}

        st =
          st
          |> put_entry(doc, entry)
          |> touch(doc)
          |> enforce_budget(doc)

        {:ok, st, Map.get(st.docs, doc)}

      {:error, reason} ->
        {:error, reason, st}
    end
  end

  # Keep at most `@budget` docs MATERIALISED. `keep` is the doc we just
  # opened/touched and must not evict. Evict least-recently-used first; a doc with
  # no real save target is un-evictable (nothing to persist/reopen from), so it is
  # skipped and pins a slot.
  defp enforce_budget(st, keep) do
    materialised =
      st.lru
      |> Enum.filter(fn doc -> doc != keep and materialised?(st, doc) end)

    live_count = Enum.count(st.lru, &materialised?(st, &1))

    if live_count <= @budget do
      st
    else
      # LRU-last among evictable docs (st.lru is MRU-first, so reverse to get LRU-first).
      victim =
        materialised
        |> Enum.reverse()
        |> Enum.find(fn doc -> evictable?(st, doc) end)

      case victim do
        nil -> st
        doc -> st |> evict(doc) |> enforce_budget(keep)
      end
    end
  end

  # Save-then-close: persist the doc's edits to its on-disk path, dispose the UNO
  # session (release the NIF resource), and mark it de-materialised so the next op
  # transparently reopens it. Its open args + path stay in the entry.
  defp evict(st, doc) do
    case Map.get(st.docs, doc) do
      %{session: session, materialised?: true} = entry ->
        _ = maybe_save(entry)
        _ = OfficeNative.close_session(session)
        put_entry(st, doc, %{entry | session: nil, materialised?: false, dirty?: false})

      _ ->
        st
    end
  end

  # Persist before eviction ONLY when the doc has pending edits AND a real path,
  # so an unedited doc is reopened from its original bytes (idempotent) and a
  # doc with no save target is never written to a guessed location.
  defp maybe_save(%{dirty?: true, path: path} = entry) when is_binary(path) and path != "" do
    OfficeNative.save_session(entry.session, path, entry.kind)
  end

  defp maybe_save(_entry), do: :ok

  # A doc is evictable iff it has a real on-disk save target: that is both where
  # we persist its edits AND where we reopen it from. A blank/unsaved doc (no
  # path) has neither, so it pins its slot rather than being lost.
  defp evictable?(st, doc) do
    case Map.get(st.docs, doc) do
      %{path: path} when is_binary(path) and path != "" -> true
      _ -> false
    end
  end

  defp materialised?(st, doc) do
    match?(%{materialised?: true}, Map.get(st.docs, doc))
  end

  # A successful WRITE op (set/apply) dirties the doc so the next eviction
  # save-then-closes it (persisting the edit); reads never dirty it, so an
  # unedited doc is reopened from its original bytes (idempotent — no rewrite).
  # A `save` already wrote to disk, so it also clears the dirty flag.
  defp mark_dirty_if_write(st, _doc, _write?, result)
       when result == :ok or (is_tuple(result) and elem(result, 0) == :error),
       do: st

  defp mark_dirty_if_write(st, doc, true, {:ok, _}), do: set_dirty(st, doc, true)
  defp mark_dirty_if_write(st, _doc, false, {:ok, _}), do: st
  defp mark_dirty_if_write(st, _doc, _write?, _result), do: st

  defp set_dirty(st, doc, value) do
    case Map.get(st.docs, doc) do
      %{} = entry -> put_entry(st, doc, %{entry | dirty?: value})
      nil -> st
    end
  end

  # ── small state helpers ────────────────────────────────────────────

  defp put_entry(st, doc, entry), do: %{st | docs: Map.put(st.docs, doc, entry)}

  defp drop(st, doc) do
    %{st | docs: Map.delete(st.docs, doc), lru: List.delete(st.lru, doc)}
  end

  # Move `doc` to the front of the LRU (most-recently-used).
  defp touch(st, doc) do
    %{st | lru: [doc | List.delete(st.lru, doc)]}
  end
end
