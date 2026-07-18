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

  alias Ecrits.AcpAgent.Session, as: AgentSession
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
  @spec set(t(), term(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def set(editor, ref, props, opts \\ []),
    do: GenServer.call(editor, {:set, ref, props, opts})

  @doc "Structural edit (write)."
  @spec apply(t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply(editor, op, opts \\ []), do: GenServer.call(editor, {:apply, op, opts})

  @typedoc """
  One command in an all-or-nothing Editor mailbox transaction.

  `:apply_then_set` covers native inserts whose returned control ref is needed
  by the immediately-following property write.
  """
  @type batch_command ::
          {:apply, map()}
          | {:set, term(), map()}
          | {:apply_then_set, map(), map(), (map() -> {:ok, term()} | {:error, term()})}

  @doc """
  Apply a command batch and persist it as one mailbox-level transaction.

  No other Editor writer can interleave between snapshot, apply, save, and a
  possible rollback. Subscriber events are emitted only after persistence
  succeeds; a failure restores the model, history, dirty revision/owner, and
  save target before the next mailbox request runs. When `:agent_session` and
  the full `:owner` turn identity are supplied, the Editor process itself owns
  that turn's commit fence for the whole transaction. The fence therefore
  survives death of the process waiting on this `GenServer.call/3`.

  An optional `:after_save` callback receives the applied results after the
  source has been persisted but before the commit fence is released. It must
  return `:ok`. Because persistence is already irreversible at that point, a
  callback error is fail-stop: the Editor terminates and does not pretend that
  the saved source was rolled back.
  """
  @spec apply_batch_and_save(t(), [batch_command()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def apply_batch_and_save(editor, commands, opts \\ [])
      when is_list(commands) and is_list(opts),
      do: GenServer.call(editor, {:apply_batch_and_save, commands, opts}, :infinity)

  @doc "Persist (export) the document."
  @spec save(t(), keyword()) :: :ok | {:error, term()}
  def save(editor, opts \\ []), do: GenServer.call(editor, {:save, opts}, :infinity)

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

  @doc "Render a native partial preview from the current in-memory document."
  @spec render_preview(t(), map(), keyword()) ::
          {:ok, binary(), map()} | {:error, term()}
  def render_preview(editor, target, opts \\ []),
    do: GenServer.call(editor, {:render_preview, target, opts}, 60_000)

  @doc """
  Whether the document has unsaved edits.
  """
  @spec dirty?(t()) :: boolean()
  def dirty?(editor), do: GenServer.call(editor, :dirty?)

  @doc "Atomically inspect unsaved state and the writer identity that last mutated it."
  @spec dirty_snapshot(t()) :: %{
          dirty?: boolean(),
          revision: non_neg_integer(),
          owner: term()
        }
  def dirty_snapshot(editor), do: GenServer.call(editor, :dirty_snapshot)

  @doc "Classify whether a dirty snapshot belongs exclusively or partly to one writer."
  @spec owner_status(map(), map()) :: :clean | :exclusive | :mixed | :other
  def owner_status(%{dirty?: false}, _owner), do: :clean
  def owner_status(%{owner: owner}, owner), do: :exclusive

  def owner_status(%{owner: {:mixed, %MapSet{} = owners}}, owner) do
    if MapSet.member?(owners, owner_token(owner)), do: :mixed, else: :other
  end

  def owner_status(_snapshot, _owner), do: :other

  @doc "Persist only when the current dirty revision still belongs to `snapshot`."
  @spec save_if_owner(t(), map(), keyword()) ::
          :ok | {:ok, term()} | {:error, term()} | {:skipped, :owner_changed | :clean}
  def save_if_owner(editor, snapshot, opts \\ []) when is_map(snapshot),
    do: GenServer.call(editor, {:save_if_owner, snapshot, opts}, :infinity)

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
           dirty_revision: 0,
           dirty_owner: nil,
           history: [],
           subscribers: MapSet.new()
         }}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{backend: backend, handle: handle} = st) do
    # Best-effort: a backend whose governor is a separate process (office's
    # singleton Instance) may already be down/restarting when we terminate, so a
    # close call can `exit`. A failed atomic rollback can also retain a newly
    # reopened handle whose first close failed before disposal. Retry every
    # retained handle, swallowing the final failure so terminate itself cannot
    # turn a recoverable office error into a LiveView-channel cascade.
    [handle | Map.get(st, :rollback_cleanup_handles, [])]
    |> Enum.uniq()
    |> Enum.each(&terminate_close_handle(backend, &1, 2))

    :ok
  end

  defp terminate_close_handle(_backend, _handle, 0), do: :ok

  defp terminate_close_handle(backend, handle, attempts_left) do
    # Do not rescue around the fence runner: it executes the transaction in this
    # process, and an unexpected post-mutation failure must retain the Editor's
    # existing fail-stop/restart semantics rather than reply from the old state.
    result =
      try do
        backend.close(handle)
      rescue
        _error -> :retry
      catch
        _kind, _reason -> :retry
      end

    if result == :ok,
      do: :ok,
      else: terminate_close_handle(backend, handle, attempts_left - 1)
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

  def handle_call(:dirty_snapshot, _from, st) do
    {:reply,
     %{
       dirty?: dirty_state?(st),
       revision: Map.get(st, :dirty_revision, 0),
       owner: Map.get(st, :dirty_owner)
     }, st}
  end

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

  def handle_call({:render_preview, target, opts}, _from, st) do
    result =
      if function_exported?(st.backend, :render_preview, 3) do
        st.backend.render_preview(st.handle, target, opts)
      else
        {:error, {:not_supported, "partial preview is not supported by this document backend"}}
      end

    {:reply, result, st}
  end

  def handle_call({:save, opts}, _from, st) do
    save_reply(st, opts)
  end

  def handle_call({:save_if_owner, snapshot, opts}, _from, st) do
    current = %{
      dirty?: dirty_state?(st),
      revision: Map.get(st, :dirty_revision, 0),
      owner: Map.get(st, :dirty_owner)
    }

    cond do
      not current.dirty? -> {:reply, {:skipped, :clean}, st}
      current != snapshot -> {:reply, {:skipped, :owner_changed}, st}
      true -> save_reply(st, opts)
    end
  end

  def handle_call({:apply_batch_and_save, commands, opts}, _from, st) do
    batch_and_save_reply(st, commands, opts)
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

  def handle_call({:set, ref, props, opts}, _from, st) do
    write(st, %{kind: :set, ref: ref, props: props, owner: write_owner(opts)}, fn ->
      st.backend.set(st.handle, ref, props)
    end)
  end

  # Preserve old-shape calls already queued in a hot-reloaded Editor mailbox.
  def handle_call({:set, ref, props}, from, st),
    do: handle_call({:set, ref, props, []}, from, st)

  def handle_call({:apply, op, opts}, _from, st) do
    case Op.normalize(op) do
      {:ok, op} ->
        write(st, %{kind: :edit, op: op, owner: write_owner(opts)}, fn applied_op ->
          st.backend.edit(st.handle, Map.get(applied_op, :op, op))
        end)

      {:error, reason} ->
        {:reply, {:error, reason}, st}
    end
  end

  def handle_call({:apply, op}, from, st),
    do: handle_call({:apply, op, []}, from, st)

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, st) do
    {:noreply, %{st | subscribers: MapSet.delete(st.subscribers, pid)}}
  end

  # --- write pipeline ------------------------------------------------------

  defp write(st, descriptor, run) do
    do_write(st, descriptor, run)
  end

  defp do_write(st, descriptor, run) do
    case execute_write(st, descriptor, run) do
      {:ok, info, next_st, true} ->
        broadcast(next_st, %{op: descriptor_op(descriptor)})
        {:reply, {:ok, info}, next_st}

      {:ok, info, next_st, false} ->
        {:reply, {:ok, info}, next_st}

      {:error, reason, next_st} ->
        {:reply, {:error, reason}, next_st}
    end
  end

  defp execute_write(st, descriptor, run) do
    result =
      case descriptor do
        %{kind: :edit, op: op} -> run.(%{op: op})
        _ -> run.()
      end

    case result do
      {:ok, applied} ->
        info = Map.put_new(applied, :invalidated, Map.get(applied, :invalidated, []))

        if applied_mutated?(applied) do
          entry = Map.put(descriptor, :applied, applied)

          next_st =
            st
            |> Map.put(:dirty_owner, next_dirty_owner(st, Map.get(descriptor, :owner)))
            |> Map.put(:dirty?, true)
            |> Map.put(:dirty_revision, Map.get(st, :dirty_revision, 0) + 1)
            |> Map.put(:history, [entry | Map.get(st, :history, [])])

          {:ok, info, next_st, true}
        else
          {:ok, info, st, false}
        end

      {:error, reason} ->
        {:error, reason, st}
    end
  end

  defp batch_and_save_reply(st, commands, opts) do
    with {:ok, owner} <- batch_write_owner(opts),
         :ok <- validate_after_save(opts) do
      run_batch_commit_fence(st, commands, opts, owner)
    else
      {:error, reason} -> {:reply, {:error, reason}, st}
    end
  end

  defp run_batch_commit_fence(st, commands, opts, owner) do
    transaction = fn ->
      {:editor_batch_transaction, do_batch_and_save_reply(st, commands, opts, owner)}
    end

    result =
      case Keyword.get(opts, :turn_commit_fun) do
        turn_commit when is_function(turn_commit, 2) and is_map(owner) ->
          turn_commit.(owner, transaction)

        turn_commit when is_function(turn_commit, 2) ->
          {:error, :incomplete_turn_identity}

        _default ->
          case Keyword.get(opts, :agent_session) do
            pid when is_pid(pid) and is_map(owner) ->
              AgentSession.with_turn_commit(pid, owner, transaction)

            pid when is_pid(pid) ->
              {:error, :incomplete_turn_identity}

            nil ->
              transaction.()

            _invalid_agent_session ->
              {:error, :invalid_agent_session}
          end
      end

    case result do
      {:editor_batch_transaction, reply} ->
        reply

      {:error, reason} ->
        {:reply, {:error, reason}, st}

      other ->
        {:reply, {:error, {:turn_commit_failed, other}}, st}
    end
  end

  defp do_batch_and_save_reply(st, commands, opts, owner) do
    with :ok <- validate_batch_owner(st, owner),
         {:ok, snapshot} <- capture_batch_snapshot(st, opts) do
      case execute_batch(st, commands, owner) do
        {:ok, applied, next_st, broadcasts} ->
          case validate_batch_commit_owner(next_st, owner) do
            :ok ->
              case save_batch_atomically(next_st, opts) do
                :ok ->
                  finish_batch_save(next_st, applied, broadcasts, opts)

                {:ok, _saved} ->
                  finish_batch_save(next_st, applied, broadcasts, opts)

                {:error, reason} ->
                  rollback_batch(next_st, snapshot, reason, true)
              end

            {:error, reason} ->
              rollback_batch(next_st, snapshot, reason, false)
          end

        {:error, reason, failed_st} ->
          rollback_batch(failed_st, snapshot, reason, false)
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, st}
    end
  end

  defp finish_batch_save(st, applied, broadcasts, opts) do
    st = mark_clean(st)
    run_after_save!(opts, applied)

    Enum.each(broadcasts, fn descriptor ->
      broadcast(st, %{op: descriptor_op(descriptor)})
    end)

    {:reply, {:ok, applied}, st}
  end

  defp validate_after_save(opts) do
    case Keyword.get(opts, :after_save) do
      nil -> :ok
      callback when is_function(callback, 1) -> :ok
      _invalid -> {:error, :invalid_after_save}
    end
  end

  defp run_after_save!(opts, applied) do
    case Keyword.get(opts, :after_save) do
      nil ->
        :ok

      callback ->
        case callback.(applied) do
          :ok -> :ok
          {:error, reason} -> exit({:after_save_failed, reason})
          other -> exit({:after_save_invalid_return, other})
        end
    end
  end

  defp batch_write_owner(opts) do
    case Keyword.fetch(opts, :owner) do
      :error ->
        {:ok, nil}

      {:ok, owner} when is_map(owner) ->
        if Enum.all?([:agent_id, :instance_id, :turn_id], fn key ->
             value = Map.get(owner, key)
             is_binary(value) and value != ""
           end) do
          {:ok, Map.take(owner, [:agent_id, :instance_id, :turn_id])}
        else
          {:error, :incomplete_turn_identity}
        end

      {:ok, nil} ->
        {:ok, nil}

      {:ok, _owner} ->
        {:error, :incomplete_turn_identity}
    end
  end

  defp validate_batch_owner(_st, nil), do: :ok

  defp validate_batch_owner(st, owner) when is_map(owner) do
    snapshot = %{
      dirty?: dirty_state?(st),
      revision: Map.get(st, :dirty_revision, 0),
      owner: Map.get(st, :dirty_owner)
    }

    case owner_status(snapshot, owner) do
      status when status in [:clean, :exclusive] -> :ok
      :mixed -> {:error, :mixed_unsaved_writers}
      :other -> {:error, :owner_changed}
    end
  end

  defp validate_batch_commit_owner(_st, nil), do: :ok

  defp validate_batch_commit_owner(st, owner) when is_map(owner) do
    snapshot = %{
      dirty?: dirty_state?(st),
      revision: Map.get(st, :dirty_revision, 0),
      owner: Map.get(st, :dirty_owner)
    }

    case owner_status(snapshot, owner) do
      :exclusive -> :ok
      :mixed -> {:error, :mixed_unsaved_writers}
      status when status in [:clean, :other] -> {:error, :owner_changed}
    end
  end

  defp capture_batch_snapshot(st, opts) do
    path = Keyword.get(opts, :path, st.path)

    with {:ok, source} <- capture_source_preimage_safely(path),
         {:ok, model} <- capture_model_preimage(st, source, opts) do
      {:ok, %{state: st, path: path, source: source, model: model}}
    end
  end

  defp capture_source_preimage_safely(path) do
    case atomic_boundary(:source_snapshot, fn -> capture_source_preimage(path) end) do
      {:ok, {:ok, _source} = ok} ->
        ok

      {:ok, {:error, _reason} = error} ->
        error

      {:ok, other} ->
        {:error, {:atomic_source_snapshot_failed, {:unexpected_return, other}}}

      {:error, reason} ->
        {:error, {:atomic_source_snapshot_failed, reason}}
    end
  end

  defp capture_source_preimage(path) when is_binary(path) and path != "" do
    case File.read(path) do
      {:ok, bytes} -> {:ok, {:present, bytes}}
      {:error, :enoent} -> {:ok, :missing}
      {:error, reason} -> {:error, {:atomic_source_snapshot_failed, reason}}
    end
  end

  defp capture_source_preimage(_path), do: {:ok, :none}

  defp capture_model_preimage(st, source, opts) do
    cond do
      not dirty_state?(st) and match?({:present, _bytes}, source) and
          same_path?(st.path, Keyword.get(opts, :path, st.path)) ->
        {:present, bytes} = source
        {:ok, {:source, bytes}}

      function_exported?(st.backend, :export_bytes, 2) ->
        case atomic_boundary(:model_snapshot_export, fn ->
               st.backend.export_bytes(
                 st.handle,
                 Keyword.get(opts, :format, format_of(st))
               )
             end) do
          {:ok, {:ok, bytes}} when is_binary(bytes) ->
            {:ok, {:bytes, bytes}}

          {:ok, {:error, reason}} ->
            {:error, {:atomic_model_snapshot_failed, reason}}

          {:ok, other} ->
            {:error, {:atomic_model_snapshot_failed, {:unexpected_return, other}}}

          {:error, reason} ->
            {:error, {:atomic_model_snapshot_failed, reason}}
        end

      true ->
        {:error, :atomic_model_snapshot_unavailable}
    end
  end

  defp same_path?(left, right)
       when is_binary(left) and left != "" and is_binary(right) and right != "",
       do: Path.expand(left) == Path.expand(right)

  defp same_path?(_left, _right), do: false

  defp execute_batch(st, commands, owner) do
    commands
    |> Enum.reduce_while({:ok, st, [], []}, fn command, {:ok, current_st, applied, broadcasts} ->
      case execute_batch_command_safely(current_st, command, owner) do
        {:ok, result, next_st, command_broadcasts} ->
          {:cont,
           {:ok, next_st, [result | applied], Enum.reverse(command_broadcasts, broadcasts)}}

        {:error, reason, failed_st} ->
          {:halt, {:error, reason, failed_st}}
      end
    end)
    |> case do
      {:ok, next_st, applied, broadcasts} ->
        {:ok, Enum.reverse(applied), next_st, Enum.reverse(broadcasts)}

      {:error, reason, failed_st} ->
        {:error, reason, failed_st}
    end
  end

  # A native backend may mutate its handle and only then raise/exit (or return a
  # shape outside the callback contract). Convert every such outcome into the
  # batch error channel while the Editor still owns the mailbox. The caller can
  # then restore the captured model before the next queued writer runs.
  defp execute_batch_command_safely(st, command, owner) do
    stage = batch_command_stage(command)

    case atomic_boundary(stage, fn -> execute_batch_command(st, command, owner) end) do
      {:ok, {:ok, _result, _next_st, _broadcasts} = ok} ->
        ok

      {:ok, {:error, _reason, _failed_st} = error} ->
        error

      {:ok, other} ->
        {:error, {:atomic_unexpected_result, stage, other}, st}

      {:error, reason} ->
        {:error, reason, st}
    end
  end

  defp batch_command_stage({:apply, _op}), do: :batch_apply
  defp batch_command_stage({:set, _ref, _props}), do: :batch_set
  defp batch_command_stage({:apply_then_set, _op, _props, _resolver}), do: :batch_apply_then_set
  defp batch_command_stage(_command), do: :batch_command

  defp execute_batch_command(st, {:apply, op}, owner) do
    execute_batch_apply(st, op, owner)
  end

  defp execute_batch_command(st, {:set, ref, props}, owner) do
    execute_batch_set(st, ref, props, owner)
  end

  defp execute_batch_command(st, {:apply_then_set, op, props, resolve_ref}, owner)
       when is_function(resolve_ref, 1) do
    case execute_batch_apply(st, op, owner) do
      {:ok, applied, applied_st, apply_broadcasts} ->
        case resolve_batch_ref(resolve_ref, applied) do
          {:ok, ref} ->
            case execute_batch_set(applied_st, ref, props, owner) do
              {:ok, _set_result, set_st, set_broadcasts} ->
                {:ok, applied, set_st, apply_broadcasts ++ set_broadcasts}

              {:error, reason, failed_st} ->
                {:error, reason, failed_st}
            end

          {:error, reason} ->
            {:error, reason, applied_st}
        end

      {:error, reason, failed_st} ->
        {:error, reason, failed_st}
    end
  end

  defp execute_batch_command(st, _command, _owner),
    do: {:error, :invalid_batch_command, st}

  defp execute_batch_apply(st, op, owner) do
    case Op.normalize(op) do
      {:ok, normalized_op} ->
        descriptor = %{kind: :edit, op: normalized_op, owner: owner}

        case execute_write(st, descriptor, fn applied_op ->
               st.backend.edit(st.handle, Map.get(applied_op, :op, normalized_op))
             end) do
          {:ok, info, next_st, mutated?} ->
            broadcasts = if mutated?, do: [descriptor], else: []
            {:ok, info, next_st, broadcasts}

          {:error, reason, failed_st} ->
            {:error, reason, failed_st}
        end

      {:error, reason} ->
        {:error, reason, st}
    end
  end

  defp execute_batch_set(st, ref, props, owner) when is_map(props) do
    descriptor = %{kind: :set, ref: ref, props: props, owner: owner}

    case execute_write(st, descriptor, fn -> st.backend.set(st.handle, ref, props) end) do
      {:ok, info, next_st, mutated?} ->
        broadcasts = if mutated?, do: [descriptor], else: []
        {:ok, info, next_st, broadcasts}

      {:error, reason, failed_st} ->
        {:error, reason, failed_st}
    end
  end

  defp execute_batch_set(st, _ref, _props, _owner),
    do: {:error, :invalid_batch_command, st}

  defp resolve_batch_ref(resolve_ref, applied) do
    case resolve_ref.(applied) do
      {:ok, _ref} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_batch_ref, other}}
    end
  rescue
    error -> {:error, {:batch_ref_resolver_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:batch_ref_resolver_failed, {kind, reason}}}
  end

  defp rollback_batch(st, snapshot, reason, restore_source?) do
    source_result = if restore_source?, do: restore_source_preimage_safely(snapshot), else: :ok
    model_result = restore_model_preimage_safely(st, snapshot, source_result)

    case {source_result, model_result} do
      {:ok, {:ok, restored_st}} ->
        {:reply, {:error, reason}, restored_st}

      {source_error, {:ok, restored_st}} ->
        stop_after_rollback_failure(
          restored_st,
          {:atomic_rollback_failed, reason, source_error}
        )

      {:ok, {:error, model_error, failed_st}} ->
        stop_after_rollback_failure(failed_st, {:atomic_rollback_failed, reason, model_error})

      {source_error, {:error, model_error, failed_st}} ->
        stop_after_rollback_failure(
          failed_st,
          {:atomic_rollback_failed, reason, source_error, model_error}
        )
    end
  end

  defp stop_after_rollback_failure(st, reason),
    do: {:stop, reason, {:error, reason}, st}

  defp restore_source_preimage_safely(snapshot) do
    case atomic_boundary(:source_restore, fn -> restore_source_preimage(snapshot) end) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        {:error, {:atomic_source_restore_failed, reason}}

      {:ok, other} ->
        {:error, {:atomic_source_restore_failed, {:unexpected_return, other}}}

      {:error, reason} ->
        {:error, {:atomic_source_restore_failed, reason}}
    end
  end

  defp restore_source_preimage(%{source: :none}), do: :ok

  defp restore_source_preimage(%{path: path, source: {:present, bytes}}) do
    case File.read(path) do
      {:ok, ^bytes} -> :ok
      _other -> Ecrits.FS.atomic_write(path, bytes)
    end
  end

  defp restore_source_preimage(%{path: path, source: :missing}) do
    case File.stat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> File.rm(path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_model_preimage(st, snapshot, source_result) do
    reopen = reopen_model_preimage(st, snapshot, source_result)

    case reopen do
      {:ok, handle} ->
        restored_st = %{snapshot.state | handle: handle}

        # A close may raise before it actually disposes the rejected engine
        # handle. Retry once while the old handle is still reachable. If both
        # attempts fail, try to dispose the newly-opened rollback handle too.
        # If that close also fails, retain the new handle in fail-stop state so
        # terminate/2 can retry both handles instead of orphaning either one.
        case close_rejected_handle(st) do
          :ok ->
            {:ok, restored_st}

          {:error, close_reason} ->
            restored_close = close_handle_once(st.backend, handle, :restored_handle_close)

            failed_st =
              case restored_close do
                :ok -> st
                {:error, _reason} -> retain_rollback_cleanup_handle(st, handle)
              end

            {:error,
             {:atomic_rejected_handle_close_failed, close_reason,
              restored_handle_close_result(restored_close)}, failed_st}
        end

      {:error, reason} ->
        {:error, {:atomic_model_restore_failed, reason}, st}
    end
  end

  defp restore_model_preimage_safely(st, snapshot, source_result) do
    case atomic_boundary(:model_restore, fn ->
           restore_model_preimage(st, snapshot, source_result)
         end) do
      {:ok, {:ok, _restored_st} = ok} ->
        ok

      {:ok, {:error, _reason, _failed_st} = error} ->
        error

      {:ok, other} ->
        {:error, {:atomic_model_restore_failed, {:unexpected_return, other}}, st}

      {:error, reason} ->
        {:error, {:atomic_model_restore_failed, reason}, st}
    end
  end

  defp retain_rollback_cleanup_handle(st, handle) do
    Map.update(st, :rollback_cleanup_handles, [handle], fn handles ->
      [handle | handles] |> Enum.uniq()
    end)
  end

  defp reopen_model_preimage(_st, %{model: {:source, _bytes}}, source_result)
       when source_result != :ok,
       do: {:error, :source_restore_failed}

  defp reopen_model_preimage(st, %{model: {:source, bytes}, path: path}, :ok) do
    call =
      if function_exported?(st.backend, :reopen, 2) do
        fn -> st.backend.reopen(st.handle, bytes) end
      else
        fn -> st.backend.open(path, []) end
      end

    normalize_model_reopen(atomic_boundary(:model_reopen, call))
  end

  defp reopen_model_preimage(st, %{model: {:bytes, bytes}}, _source_result) do
    normalize_model_reopen(atomic_boundary(:model_reopen, fn -> st.backend.open(bytes, []) end))
  end

  defp normalize_model_reopen({:ok, {:ok, _handle} = ok}), do: ok
  defp normalize_model_reopen({:ok, {:error, _reason} = error}), do: error

  defp normalize_model_reopen({:ok, other}),
    do: {:error, {:unexpected_return, other}}

  defp normalize_model_reopen({:error, reason}), do: {:error, reason}

  defp close_rejected_handle(st) do
    first = close_handle_once(st.backend, st.handle, :rejected_handle_close)

    case first do
      :ok ->
        :ok

      {:error, first_reason} ->
        case close_handle_once(st.backend, st.handle, :rejected_handle_close_retry) do
          :ok -> :ok
          {:error, retry_reason} -> {:error, {:close_retry_failed, first_reason, retry_reason}}
        end
    end
  end

  defp close_handle_once(backend, handle, stage) do
    case atomic_boundary(stage, fn -> backend.close(handle) end) do
      {:ok, :ok} -> :ok
      {:ok, other} -> {:error, {:unexpected_return, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp restored_handle_close_result(:ok), do: :closed
  defp restored_handle_close_result({:error, reason}), do: {:close_failed, reason}

  defp save_batch_atomically(st, opts) do
    case atomic_boundary(:batch_save, fn -> save_via(st, opts) end) do
      {:ok, :ok} ->
        :ok

      {:ok, {:ok, _saved} = ok} ->
        ok

      {:ok, {:error, _reason} = error} ->
        error

      {:ok, other} ->
        {:error, {:atomic_unexpected_result, :batch_save, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp atomic_boundary(stage, fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    error ->
      {:error,
       {:atomic_boundary_failed, stage, {:raise, error.__struct__, Exception.message(error)}}}
  catch
    :exit, reason ->
      {:error, {:atomic_boundary_failed, stage, {:exit, reason}}}

    kind, reason ->
      {:error, {:atomic_boundary_failed, stage, {kind, reason}}}
  end

  defp descriptor_op(%{kind: :edit, op: op}), do: op

  defp descriptor_op(%{kind: :set, ref: ref, props: props}),
    do: %{op: "set", ref: ref, props: props}

  defp descriptor_op(other), do: other

  defp dirty_state?(st), do: Map.get(st, :dirty?, false)

  defp next_dirty_owner(st, owner) do
    cond do
      not dirty_state?(st) ->
        owner

      match?({:mixed, %MapSet{}}, Map.get(st, :dirty_owner)) ->
        {:mixed,
         st
         |> Map.get(:dirty_owner)
         |> elem(1)
         |> MapSet.put(owner_token(owner))}

      Map.get(st, :dirty_owner) == owner ->
        owner

      true ->
        {:mixed,
         MapSet.new([
           owner_token(Map.get(st, :dirty_owner)),
           owner_token(owner)
         ])}
    end
  end

  defp owner_token(nil), do: :unowned
  defp owner_token(owner), do: owner

  defp applied_mutated?(%{changed?: false}), do: false
  defp applied_mutated?(%{"changed" => false}), do: false
  defp applied_mutated?(%{op: "noop"}), do: false
  defp applied_mutated?(%{"op" => "noop"}), do: false
  defp applied_mutated?(%{native: native}) when is_list(native), do: native_mutated?(native)
  defp applied_mutated?(%{"native" => native}) when is_list(native), do: native_mutated?(native)
  defp applied_mutated?(%{replaced: 0}), do: false
  defp applied_mutated?(%{"replaced" => 0}), do: false
  defp applied_mutated?(_applied), do: true

  defp native_mutated?(results), do: Enum.any?(results, &native_result_mutated?/1)

  defp native_result_mutated?(%{} = result) do
    ok = Map.get(result, :ok, Map.get(result, "ok"))
    replaced = Map.get(result, :replaced, Map.get(result, "replaced"))
    ok != false and replaced != 0
  end

  defp native_result_mutated?(_result), do: true

  defp mark_clean(st), do: st |> Map.put(:dirty?, false) |> Map.put(:dirty_owner, nil)

  defp write_owner(opts) when is_list(opts) do
    owner = Keyword.get(opts, :owner)

    if is_map(owner) and
         Enum.all?([:agent_id, :instance_id, :turn_id], fn key ->
           value = Map.get(owner, key)
           is_binary(value) and value != ""
         end) do
      Map.take(owner, [:agent_id, :instance_id, :turn_id])
    end
  end

  defp write_owner(_opts), do: nil

  defp save_reply(st, opts) do
    case save_via(st, opts) do
      :ok ->
        {:reply, :ok, mark_clean(st)}

      {:ok, _} = ok ->
        {:reply, ok, mark_clean(st)}

      {:error, _} = error ->
        {:reply, error, st}
    end
  end

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
