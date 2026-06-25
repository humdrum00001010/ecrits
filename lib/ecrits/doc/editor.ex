defmodule Ecrits.Doc.Editor do
  @moduledoc """
  Per-document authoritative editor process (design §6).

  One `Editor` owns exactly one document handle and serialises every writer
  (user + agent) through a single mailbox. Different documents run in different
  Editors, so documents are parallel while a single document is strictly
  serial. This is what makes "two authoritative copies" impossible and reduces
  conflicts to *serial ordering* (§6.1).

  ## Write protocol

  Writes are serialized by this GenServer's mailbox. The document surface does
  not expose ordering tokens; callers edit by ref/op and receive the engine-level
  result.

  Subscribers (a browser LiveView, the agent) receive `{:doc_applied, info}`
  broadcasts so everyone observes the same serial order.
  """

  use GenServer

  alias Ecrits.Doc.Op

  @type t :: pid()

  # --- client API ----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Read text through the owned handle."
  @spec read(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(editor, opts \\ []), do: GenServer.call(editor, {:read, opts})

  @doc "Literal search through the owned handle."
  @spec find(t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def find(editor, pattern, opts \\ []), do: GenServer.call(editor, {:find, pattern, opts})

  @doc """
  Full-IR element enumeration through the owned handle (the backend's optional
  `elements/2`). Returns `{:error, {:not_supported, _}}` when the backend (or
  its deployed NIF) can't enumerate, so callers fall back to `find`/`read`.
  """
  @spec elements(t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def elements(editor, opts \\ []), do: GenServer.call(editor, {:elements, opts})

  @doc "Structural tree through the owned handle."
  @spec outline(t(), term() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def outline(editor, ref \\ nil, opts \\ []), do: GenServer.call(editor, {:outline, ref, opts})

  @doc "Reflective discovery (element type, native property names, children)."
  @spec inspect_element(t(), term() | nil) :: {:ok, map()} | {:error, term()}
  def inspect_element(editor, ref \\ nil), do: GenServer.call(editor, {:inspect, ref})

  @doc "Native property read."
  @spec get(t(), term(), [String.t()] | nil) :: {:ok, map()} | {:error, term()}
  def get(editor, ref, props \\ nil), do: GenServer.call(editor, {:get, ref, props})

  @doc "Property edit (write)."
  @spec set(t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def set(editor, ref, props), do: GenServer.call(editor, {:set, ref, props})

  @doc "Structural edit (write)."
  @spec apply(t(), map()) :: {:ok, map()} | {:error, term()}
  def apply(editor, op), do: GenServer.call(editor, {:apply, op})

  @doc "Persist (export) the document."
  @spec save(t(), keyword()) :: :ok | {:error, term()}
  def save(editor, opts \\ []), do: GenServer.call(editor, {:save, opts})

  @doc """
  Export the in-memory document to bytes WITHOUT touching disk. `format`
  defaults to the document's own (from its path extension). Backends without
  `export_bytes/2` return `{:error, {:not_supported, _}}`.
  """
  @spec export_bytes(t(), atom() | nil) :: {:ok, binary()} | {:error, term()}
  def export_bytes(editor, format \\ nil), do: GenServer.call(editor, {:export_bytes, format})

  @doc """
  Replace the in-memory model with one parsed from `bytes`.

  This is the server-twin SYNC for browser-authority documents: while a human
  viewer holds the doc, its browser WASM model is the authority and this
  editor is only a shadow. Browser checkpoints push their exported bytes here
  so the shadow never lags — without it, a viewer detach (tab switch) leaves a
  stale NIF copy that a later server-routed save would write over the
  browser's edits. The reload marks the editor clean (it now mirrors the
  authority exactly); on parse failure the old model is kept.
  """
  @spec reload_from_bytes(t(), binary()) :: :ok | {:error, term()}
  def reload_from_bytes(editor, bytes) when is_binary(bytes),
    do: GenServer.call(editor, {:reload_from_bytes, bytes})

  @doc """
  Rasterize one slide/page to a PNG at `path` (read-only; Office/Impress docs).
  Backends without `render_page/4` return `{:error, {:not_supported, _}}`.
  """
  @spec render(t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def render(editor, page, path, opts \\ []),
    do: GenServer.call(editor, {:render, page, path, opts}, 60_000)

  @doc """
  Whether the document has unsaved edits.
  """
  @spec dirty?(t()) :: boolean()
  def dirty?(editor), do: GenServer.call(editor, :dirty?)

  @doc """
  Save target for an autonomous (turn-end) persist: `{:ok, path}` when the
  document carries a real on-disk path it can be exported to, otherwise
  `{:error, :no_save_target}`. Used by the Pool/turn handler to decide whether a
  dirty doc can be auto-persisted without guessing a path.
  """
  @spec save_target(t()) :: {:ok, String.t()} | {:error, :no_save_target}
  def save_target(editor), do: GenServer.call(editor, :save_target)

  @doc "Subscribe the caller to `{:doc_applied, info}` broadcasts."
  @spec subscribe(t()) :: :ok
  def subscribe(editor), do: GenServer.call(editor, {:subscribe, self()})

  @doc "Applied-op history (oldest first)."
  @spec history(t()) :: [map()]
  def history(editor), do: GenServer.call(editor, :history)

  @doc "Document summary (id, kind, path)."
  @spec info(t()) :: map()
  def info(editor), do: GenServer.call(editor, :info)

  @spec stop(t()) :: :ok
  def stop(editor), do: GenServer.stop(editor)

  # --- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    # Trap exits so `terminate/2` actually RUNS on a supervisor-initiated shutdown
    # (`DynamicSupervisor.terminate_child`, which Pool.close uses on tab-close).
    # Without this the `:shutdown` signal kills the GenServer immediately and
    # terminate/2 is SKIPPED — so `backend.close/1` never fires and the office UNO
    # session + its `.~lock.<file>#` leak (the "close of libre never works" bug).
    Process.flag(:trap_exit, true)

    backend = Keyword.fetch!(opts, :backend)
    path = Keyword.fetch!(opts, :path)
    open_opts = Keyword.get(opts, :open_opts, [])

    # `create?` mints a NEW blank document (engine template) instead of reading
    # `path` off disk; `path` is then only the save target (the file need not
    # exist yet). Falls back to a clear error if the backend has no `new/1`.
    load =
      if Keyword.get(opts, :create?, false) do
        if function_exported?(backend, :new, 1),
          do: backend.new(open_opts),
          else: {:error, {:create_unsupported, backend}}
      else
        backend.open(path, open_opts)
      end

    case load do
      {:ok, handle} ->
        {:ok,
         %{
           document_id: Keyword.fetch!(opts, :document_id),
           kind: Keyword.get(opts, :kind, backend.kind()),
           backend: backend,
           handle: handle,
           path: path,
           dirty?: false,
           history: [],
           subscribers: MapSet.new()
         }}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{backend: backend, handle: handle}) do
    # Best-effort: a backend whose governor is a separate process (office's
    # singleton Instance) may already be down/restarting when we terminate, so a
    # close call can `exit`. Swallow it — terminate must not itself crash (that
    # turned a recoverable office error into a LiveView-channel cascade).
    try do
      backend.close(handle)
    catch
      _kind, _reason -> :ok
    end

    :ok
  end

  @impl true
  def handle_call(:history, _from, st), do: {:reply, Enum.reverse(st.history), st}

  def handle_call(:info, _from, st) do
    {:reply,
     %{
       id: st.document_id,
       kind: st.kind,
       path: st.path,
       dirty: dirty_state?(st),
       backing: :server
     }, st}
  end

  def handle_call(:dirty?, _from, st), do: {:reply, dirty_state?(st), st}

  def handle_call(:save_target, _from, st), do: {:reply, save_target_of(st), st}

  def handle_call({:subscribe, pid}, _from, st) do
    Process.monitor(pid)
    {:reply, :ok, %{st | subscribers: MapSet.put(st.subscribers, pid)}}
  end

  def handle_call({:read, opts}, _from, st),
    do: {:reply, st.backend.read(st.handle, opts), st}

  def handle_call({:find, pattern, opts}, _from, st),
    do: {:reply, st.backend.find(st.handle, pattern, opts), st}

  def handle_call({:elements, opts}, _from, st) do
    # Optional backend capability: surface a clean not_supported error when the
    # backend doesn't implement `elements/2` so the Tools layer falls back.
    if Code.ensure_loaded?(st.backend) and function_exported?(st.backend, :elements, 2) do
      {:reply, st.backend.elements(st.handle, opts), st}
    else
      {:reply, {:error, {:not_supported, "backend has no elements/2"}}, st}
    end
  end

  def handle_call({:outline, ref, opts}, _from, st),
    do: {:reply, st.backend.outline(st.handle, ref, opts), st}

  def handle_call({:inspect, ref}, _from, st),
    do: {:reply, st.backend.inspect(st.handle, ref), st}

  def handle_call({:get, ref, props}, _from, st),
    do: {:reply, st.backend.get(st.handle, ref, props), st}

  def handle_call({:render, page, path, opts}, _from, st) do
    result =
      if function_exported?(st.backend, :render_page, 4) do
        st.backend.render_page(st.handle, page, path, Keyword.get(opts, :width, 1280))
      else
        {:error, {:not_supported, "render is not supported by this document backend"}}
      end

    {:reply, result, st}
  end

  def handle_call({:save, opts}, _from, st) do
    case save_via(st, opts) do
      :ok ->
        {:reply, :ok, mark_clean(st)}

      {:ok, _} = ok ->
        {:reply, ok, mark_clean(st)}

      {:error, _} = error ->
        {:reply, error, st}
    end
  end

  def handle_call({:export_bytes, format}, _from, st) do
    if function_exported?(st.backend, :export_bytes, 2) do
      {:reply, st.backend.export_bytes(st.handle, format || format_of(st)), st}
    else
      {:reply, {:error, {:not_supported, "backend #{inspect(st.backend)} has no export_bytes/2"}},
       st}
    end
  end

  def handle_call({:reload_from_bytes, bytes}, _from, st) when is_binary(bytes) do
    # Open the NEW model first and only then close the old handle, so a parse
    # failure keeps the current (still-valid) model instead of losing the doc.
    #
    # Path-native backends (office/UNO) export `reopen/2`: their `open/2` opens a
    # FILE, so handing it raw bytes would treat the byte buffer as a path (the
    # pptx save->close crash). Bytes-native backends (rhwp) have no `reopen/2` and
    # fall back to `open(bytes, [])`, which they accept directly.
    reopened =
      if function_exported?(st.backend, :reopen, 2) do
        st.backend.reopen(st.handle, bytes)
      else
        st.backend.open(bytes, [])
      end

    case reopened do
      {:ok, new_handle} ->
        st.backend.close(st.handle)
        {:reply, :ok, mark_clean(%{st | handle: new_handle})}

      {:error, _} = error ->
        {:reply, error, st}
    end
  end

  def handle_call({:set, ref, props}, _from, st) do
    write(st, %{kind: :set, ref: ref, props: props}, fn ->
      st.backend.set(st.handle, ref, props)
    end)
  end

  def handle_call({:apply, op}, _from, st) do
    case Op.normalize(op) do
      {:ok, op} ->
        write(st, %{kind: :edit, op: op}, fn applied_op ->
          st.backend.edit(st.handle, Map.get(applied_op, :op, op))
        end)

      {:error, reason} ->
        {:reply, {:error, reason}, st}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, st) do
    {:noreply, %{st | subscribers: MapSet.delete(st.subscribers, pid)}}
  end

  # --- write pipeline ------------------------------------------------------

  defp write(st, descriptor, run) do
    do_write(st, descriptor, run)
  end

  defp do_write(st, descriptor, run) do
    result =
      case descriptor do
        %{kind: :edit, op: op} -> run.(%{op: op})
        _ -> run.()
      end

    case result do
      {:ok, applied} ->
        entry =
          descriptor
          |> Map.put(:applied, applied)

        st =
          st |> Map.put(:dirty?, true) |> Map.put(:history, [entry | Map.get(st, :history, [])])

        info = Map.put_new(applied, :invalidated, Map.get(applied, :invalidated, []))

        broadcast(st, %{op: descriptor_op(descriptor)})
        {:reply, {:ok, info}, st}

      {:error, _reason} = error ->
        {:reply, error, st}
    end
  end

  defp descriptor_op(%{kind: :edit, op: op}), do: op

  defp descriptor_op(%{kind: :set, ref: ref, props: props}),
    do: %{op: "set", ref: ref, props: props}

  defp descriptor_op(other), do: other

  defp dirty_state?(st), do: Map.get(st, :dirty?, false)

  defp mark_clean(st), do: Map.put(st, :dirty?, false)

  # The document's own export format, derived from its save-target extension
  # (.hwpx -> :hwpx, everything else .hwp). Office backends don't reach this
  # (they have no export_bytes/2).
  defp format_of(%{path: path}) when is_binary(path) do
    if String.ends_with?(String.downcase(path), ".hwpx"), do: :hwpx, else: :hwp
  end

  defp format_of(_st), do: :hwp

  defp save_via(st, opts) do
    if function_exported?(st.backend, :save, 2) do
      st.backend.save(st.handle, opts)
    else
      {:error, {:not_supported, "backend #{inspect(st.backend)} has no save/2"}}
    end
  end

  # A server-backed doc can be autonomously persisted iff it carries a real
  # on-disk path (the create/clone/open target). Editors that hold no path
  # (`nil`/blank) have no safe destination, so the turn-end auto-save MUST skip
  # them rather than write to a guessed location.
  defp save_target_of(%{path: path}) when is_binary(path) and path != "", do: {:ok, path}
  defp save_target_of(_st), do: {:error, :no_save_target}

  defp broadcast(st, info) do
    Enum.each(st.subscribers, fn pid -> send(pid, {:doc_applied, info}) end)
  end
end
