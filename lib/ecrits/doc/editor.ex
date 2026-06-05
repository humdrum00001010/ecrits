defmodule Ecrits.Doc.Editor do
  @moduledoc """
  Per-document authoritative editor process (design §6).

  One `Editor` owns exactly one document handle and serialises every writer
  (user + agent) through a single mailbox. Different documents run in different
  Editors, so documents are parallel while a single document is strictly
  serial. This is what makes "two authoritative copies" impossible and reduces
  conflicts to *serial ordering* (§6.1).

  ## Revision protocol (§6.4)

  Every mutation carries a `base_revision`. On `apply/3`:

    * `base_rev == rev` (or `nil`) — clean: apply, `rev = rev + 1`, broadcast.
    * `base_rev > rev` — `{:error, {:stale_revision, ...}}` (future revision).
    * `base_rev < rev` — another writer interleaved: `rebase/2` the op against
      ops applied since `base_rev`. Non-overlapping ⇒ apply with `rebased: true`;
      overlapping the same span ⇒ `{:error, {:conflict, rev, snapshot}}` so the
      caller can retry against the current state.

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

  @doc "Current authoritative revision."
  @spec revision(t()) :: non_neg_integer()
  def revision(editor), do: GenServer.call(editor, :revision)

  @doc "Read text through the owned handle."
  @spec read(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(editor, opts \\ []), do: GenServer.call(editor, {:read, opts})

  @doc "Literal search through the owned handle."
  @spec find(t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def find(editor, pattern, opts \\ []), do: GenServer.call(editor, {:find, pattern, opts})

  @doc "Structural tree through the owned handle."
  @spec outline(t(), term() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def outline(editor, ref \\ nil, opts \\ []), do: GenServer.call(editor, {:outline, ref, opts})

  @doc "Reflective discovery (element type, native property names, children)."
  @spec inspect_element(t(), term() | nil) :: {:ok, map()} | {:error, term()}
  def inspect_element(editor, ref \\ nil), do: GenServer.call(editor, {:inspect, ref})

  @doc "Native property read."
  @spec get(t(), term(), [String.t()] | nil) :: {:ok, map()} | {:error, term()}
  def get(editor, ref, props \\ nil), do: GenServer.call(editor, {:get, ref, props})

  @doc "Property edit (write); honours `base_revision` via the rebase protocol."
  @spec set(t(), term(), map(), non_neg_integer() | nil) :: {:ok, map()} | {:error, term()}
  def set(editor, ref, props, base_rev), do: GenServer.call(editor, {:set, ref, props, base_rev})

  @doc "Structural edit (write); honours `base_revision` via the rebase protocol."
  @spec apply(t(), map(), non_neg_integer() | nil) :: {:ok, map()} | {:error, term()}
  def apply(editor, op, base_rev), do: GenServer.call(editor, {:apply, op, base_rev})

  @doc "Persist (export) the document."
  @spec save(t(), keyword()) :: :ok | {:error, term()}
  def save(editor, opts \\ []), do: GenServer.call(editor, {:save, opts})

  @doc "Subscribe the caller to `{:doc_applied, info}` broadcasts."
  @spec subscribe(t()) :: :ok
  def subscribe(editor), do: GenServer.call(editor, {:subscribe, self()})

  @doc "Applied-op history (oldest first)."
  @spec history(t()) :: [map()]
  def history(editor), do: GenServer.call(editor, :history)

  @doc "Document summary (id, kind, path, revision)."
  @spec info(t()) :: map()
  def info(editor), do: GenServer.call(editor, :info)

  @spec stop(t()) :: :ok
  def stop(editor), do: GenServer.stop(editor)

  # --- server --------------------------------------------------------------

  @impl true
  def init(opts) do
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
           rev: 0,
           history: [],
           subscribers: MapSet.new()
         }}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{backend: backend, handle: handle}) do
    backend.close(handle)
    :ok
  end

  @impl true
  def handle_call(:revision, _from, st), do: {:reply, st.rev, st}

  def handle_call(:history, _from, st), do: {:reply, Enum.reverse(st.history), st}

  def handle_call(:info, _from, st) do
    {:reply,
     %{id: st.document_id, kind: st.kind, path: st.path, revision: st.rev, backing: :server}, st}
  end

  def handle_call({:subscribe, pid}, _from, st) do
    Process.monitor(pid)
    {:reply, :ok, %{st | subscribers: MapSet.put(st.subscribers, pid)}}
  end

  def handle_call({:read, opts}, _from, st),
    do: {:reply, st.backend.read(st.handle, opts), st}

  def handle_call({:find, pattern, opts}, _from, st),
    do: {:reply, st.backend.find(st.handle, pattern, opts), st}

  def handle_call({:outline, ref, opts}, _from, st),
    do: {:reply, st.backend.outline(st.handle, ref, opts), st}

  def handle_call({:inspect, ref}, _from, st),
    do: {:reply, st.backend.inspect(st.handle, ref), st}

  def handle_call({:get, ref, props}, _from, st),
    do: {:reply, st.backend.get(st.handle, ref, props), st}

  def handle_call({:save, opts}, _from, st),
    do: {:reply, save_via(st, opts), st}

  def handle_call({:set, ref, props, base_rev}, _from, st) do
    write(st, base_rev, %{kind: :set, ref: ref, props: props}, fn ->
      st.backend.set(st.handle, ref, props, base_rev)
    end)
  end

  def handle_call({:apply, op, base_rev}, _from, st) do
    case Op.normalize(op) do
      {:ok, op} ->
        write(st, base_rev, %{kind: :edit, op: op}, fn applied_op ->
          st.backend.edit(st.handle, Map.get(applied_op, :op, op), base_rev)
        end)

      {:error, reason} ->
        {:reply, {:error, reason}, st}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, st) do
    {:noreply, %{st | subscribers: MapSet.delete(st.subscribers, pid)}}
  end

  # --- write pipeline (revision + rebase + broadcast) ----------------------

  defp write(st, base_rev, descriptor, run) do
    case classify(base_rev, st.rev) do
      :clean ->
        do_write(st, descriptor, run, false)

      :future ->
        {:reply, {:error, {:stale_revision, expected: st.rev, got: base_rev}}, st}

      :stale ->
        case rebase(descriptor, ops_since(st, base_rev)) do
          {:ok, rebased_descriptor} ->
            do_write(st, rebased_descriptor, run, true)

          :conflict ->
            {:reply, {:error, {:conflict, st.rev, snapshot(st, descriptor)}}, st}
        end
    end
  end

  defp do_write(st, descriptor, run, rebased?) do
    result =
      case descriptor do
        %{kind: :edit, op: op} -> run.(%{op: op})
        _ -> run.()
      end

    case result do
      {:ok, applied} ->
        rev = st.rev + 1

        entry =
          descriptor
          |> Map.put(:revision, rev)
          |> Map.put(:applied, applied)
          |> Map.put(:rebased, rebased?)

        st = %{st | rev: rev, history: [entry | st.history]}

        info =
          applied
          |> Map.put(:revision, rev)
          |> Map.put(:rebased, rebased?)
          |> Map.put_new(:invalidated, Map.get(applied, :invalidated, []))

        broadcast(st, %{revision: rev, rebased: rebased?, op: descriptor_op(descriptor)})
        {:reply, {:ok, info}, st}

      {:error, _reason} = error ->
        {:reply, error, st}
    end
  end

  defp classify(nil, _cur), do: :clean
  defp classify(base, cur) when base == cur, do: :clean
  defp classify(base, cur) when base > cur, do: :future
  defp classify(_base, _cur), do: :stale

  # Content-aware rebase for the verbs the headless NIF can apply today.
  # `replace_text` targets a literal span (`query`). It rebases cleanly past an
  # intervening op iff that op did not consume the same span; if an intervening
  # op replaced the exact same `query`, the spans overlap -> conflict.
  defp rebase(%{kind: :edit, op: %{op: "replace_text"} = op} = descriptor, intervening) do
    query = Map.get(op, :query)

    overlaps? =
      Enum.any?(intervening, fn
        %{kind: :edit, op: %{op: "replace_text", query: ^query}} -> true
        _ -> false
      end)

    if overlaps?, do: :conflict, else: {:ok, descriptor}
  end

  # Property edits (`set`) on the same ref overlap; otherwise rebase cleanly.
  defp rebase(%{kind: :set, ref: ref} = descriptor, intervening) do
    overlaps? =
      Enum.any?(intervening, fn
        %{kind: :set, ref: ^ref} -> true
        _ -> false
      end)

    if overlaps?, do: :conflict, else: {:ok, descriptor}
  end

  # Unknown/structural ops: conservatively conflict so callers re-read state.
  defp rebase(_descriptor, _intervening), do: :conflict

  defp ops_since(st, base_rev) do
    # history is newest-first; entries with revision > base_rev interleaved.
    st.history
    |> Enum.filter(&(&1.revision > base_rev))
    |> Enum.reverse()
  end

  defp snapshot(st, descriptor) do
    ref = descriptor[:ref] || get_in(descriptor, [:op, :ref])

    base = %{revision: st.rev, document_id: st.document_id}

    case st.backend.read(st.handle, []) do
      {:ok, %{text: text}} -> Map.merge(base, %{text: text, ref: ref})
      _ -> Map.put(base, :ref, ref)
    end
  end

  defp descriptor_op(%{kind: :edit, op: op}), do: op

  defp descriptor_op(%{kind: :set, ref: ref, props: props}),
    do: %{op: "set", ref: ref, props: props}

  defp descriptor_op(other), do: other

  defp save_via(st, opts) do
    if function_exported?(st.backend, :save, 2) do
      st.backend.save(st.handle, opts)
    else
      {:error, {:not_supported, "backend #{inspect(st.backend)} has no save/2"}}
    end
  end

  defp broadcast(st, info) do
    Enum.each(st.subscribers, fn pid -> send(pid, {:doc_applied, info}) end)
  end
end
