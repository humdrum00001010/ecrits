defmodule Ecrits.WorkspaceHandoff do
  @moduledoc """
  Server-owned durable handoff for workspace identity and chat-rail display state.

  The store is deliberately narrow. It writes workspace paths, stable rail
  identities/selections, and completed agent display state as JSON. Process ids,
  references, current turns, queued work, injected adapters, and arbitrary
  adapter options never cross this boundary.
  """

  use GenServer

  alias Ecrits.Agent
  require Logger

  @name __MODULE__
  @version 1
  @persisted_adapter_opt_keys ~w(
    model reasoning_effort sandbox permission_mode approval_policy access_control
  )

  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name, @name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec put_workspace_path(String.t(), String.t()) :: :ok | {:error, term()}
  def put_workspace_path(live_session_id, path)
      when is_binary(live_session_id) and live_session_id != "" and is_binary(path) and path != "" do
    call({:put_workspace_path, live_session_id, Path.expand(path)})
  end

  def put_workspace_path(_live_session_id, _path), do: {:error, :invalid_workspace_handoff}

  @spec fetch_workspace_path(String.t()) :: {:ok, String.t()} | :error | {:error, term()}
  def fetch_workspace_path(live_session_id)
      when is_binary(live_session_id) and live_session_id != "" do
    call({:fetch_workspace_path, live_session_id})
  end

  def fetch_workspace_path(_live_session_id), do: :error

  @doc false
  @spec put_chat_rail_state(String.t(), map()) :: :ok | {:error, term()}
  def put_chat_rail_state(workspace_path, rail_state)
      when is_binary(workspace_path) and workspace_path != "" and is_map(rail_state) do
    call({:put_chat_rail_state, Path.expand(workspace_path), rail_state})
  end

  def put_chat_rail_state(_workspace_path, _rail_state),
    do: {:error, :invalid_chat_rail_state}

  @doc false
  @spec put_agent_state(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_agent_state(workspace_path, agent_id, agent_state)
      when is_binary(workspace_path) and workspace_path != "" and is_binary(agent_id) and
             agent_id != "" and is_map(agent_state) do
    call({:put_agent_state, Path.expand(workspace_path), agent_id, agent_state})
  end

  def put_agent_state(_workspace_path, _agent_id, _agent_state),
    do: {:error, :invalid_agent_state}

  @doc false
  @spec put_agent_state_async(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_agent_state_async(workspace_path, agent_id, agent_state)
      when is_binary(workspace_path) and workspace_path != "" and is_binary(agent_id) and
             agent_id != "" and is_map(agent_state) do
    cast({:put_agent_state, Path.expand(workspace_path), agent_id, agent_state})
  end

  def put_agent_state_async(_workspace_path, _agent_id, _agent_state),
    do: {:error, :invalid_agent_state}

  @doc false
  @spec delete_chat_rail(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_chat_rail(workspace_path, rail_key)
      when is_binary(workspace_path) and workspace_path != "" and is_binary(rail_key) and
             rail_key != "" do
    call({:delete_chat_rail, Path.expand(workspace_path), rail_key})
  end

  def delete_chat_rail(_workspace_path, _rail_key), do: {:error, :invalid_chat_rail}

  @doc false
  @spec fetch_chat_rail_state(String.t()) :: {:ok, map()} | :error | {:error, term()}
  def fetch_chat_rail_state(workspace_path)
      when is_binary(workspace_path) and workspace_path != "" do
    call({:fetch_chat_rail_state, Path.expand(workspace_path)})
  end

  def fetch_chat_rail_state(_workspace_path), do: :error

  @doc false
  def store_path do
    case Process.whereis(@name) do
      pid when is_pid(pid) -> GenServer.call(pid, :store_path)
      nil -> nil
    end
  end

  @impl true
  def init(opts) do
    store_path =
      Keyword.get(opts, :store_path) ||
        Application.get_env(:ecrits, :workspace_handoff_store_path) ||
        default_store_path()

    {:ok, load_store(store_path)}
  end

  @impl true
  def handle_call({:put_workspace_path, live_session_id, path}, _from, state) do
    state = ensure_runtime_state(state)

    persist_reply(state, %{
      state
      | workspace_paths: Map.put(state.workspace_paths, live_session_id, path)
    })
  end

  def handle_call({:fetch_workspace_path, live_session_id}, _from, state) do
    state = ensure_runtime_state(state)
    {:reply, Map.fetch(state.workspace_paths, live_session_id), state}
  end

  def handle_call({:put_chat_rail_state, workspace_path, rail_state}, _from, state) do
    state = ensure_runtime_state(state)

    case normalize_chat_rail_state(rail_state) do
      {:ok, normalized} ->
        persist_reply(state, %{
          state
          | chat_rails: Map.put(state.chat_rails, workspace_path, normalized)
        })

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_agent_state, workspace_path, agent_id, agent_state}, _from, state) do
    state = ensure_runtime_state(state)

    case put_agent_state_in_memory(state, workspace_path, agent_id, agent_state) do
      {:ok, next} -> persist_reply(state, next)
      :ignored -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_chat_rail, workspace_path, rail_key}, _from, state) do
    state = ensure_runtime_state(state)

    case Map.fetch(state.chat_rails, workspace_path) do
      {:ok, rail_state} ->
        rail_state = %{
          rail_state
          | foregrounds: Map.delete(rail_state.foregrounds, rail_key),
            active_foregrounds:
              Map.reject(rail_state.active_foregrounds, fn {_key, selected} ->
                selected == rail_key
              end),
            foreground_order: Enum.reject(rail_state.foreground_order, &(&1 == rail_key))
        }

        next = %{state | chat_rails: Map.put(state.chat_rails, workspace_path, rail_state)}
        persist_reply(state, next)

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:fetch_chat_rail_state, workspace_path}, _from, state) do
    state = ensure_runtime_state(state)
    {:reply, Map.fetch(state.chat_rails, workspace_path), state}
  end

  def handle_call(:store_path, _from, state) do
    state = ensure_runtime_state(state)
    {:reply, state.store_path, state}
  end

  @impl true
  def handle_cast({:put_agent_state, workspace_path, agent_id, agent_state}, state) do
    state = ensure_runtime_state(state)

    case put_agent_state_in_memory(state, workspace_path, agent_id, agent_state) do
      {:ok, next} when next == state ->
        {:noreply, state}

      {:ok, next} ->
        case write_store(next) do
          :ok -> {:noreply, next}
          {:error, _reason} -> {:noreply, state}
        end

      :ignored ->
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  defp persist_reply(state, state), do: {:reply, :ok, state}

  defp persist_reply(old_state, next_state) do
    case write_store(next_state) do
      :ok -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, {:store_write_failed, reason}}, old_state}
    end
  end

  defp put_agent_state_in_memory(state, workspace_path, agent_id, agent_state) do
    with {:ok, normalized_agent} <- normalize_agent_state(agent_state),
         true <- normalized_agent.id == agent_id,
         {:ok, rail_state} <- Map.fetch(state.chat_rails, workspace_path) do
      case Enum.find(rail_state.foregrounds, fn {_rail_key, meta} ->
             meta.agent_id == agent_id
           end) do
        {rail_key, meta} ->
          with :ok <- accept_agent_instance(meta, normalized_agent) do
            foregrounds =
              Map.put(
                rail_state.foregrounds,
                rail_key,
                Map.put(meta, :agent_state, normalized_agent)
              )

            rail_state = %{rail_state | foregrounds: foregrounds}
            {:ok, %{state | chat_rails: Map.put(state.chat_rails, workspace_path, rail_state)}}
          end

        nil ->
          # A delayed agent event must never resurrect an intentionally removed rail.
          :ignored
      end
    else
      false -> {:error, :agent_id_mismatch}
      :error -> :ignored
      {:error, reason} -> {:error, reason}
    end
  end

  defp accept_agent_instance(
         %{agent_state: %{instance_id: current}},
         %{instance_id: incoming}
       )
       when is_binary(current) and current != "" and is_binary(incoming) and incoming != "" and
              current != incoming,
       do: {:error, :stale_agent_instance}

  defp accept_agent_instance(_meta, _agent_state), do: :ok

  defp load_store(path) do
    empty = %{store_path: path, workspace_paths: %{}, chat_rails: %{}}

    with {:ok, bytes} <- File.read(path),
         {:ok, json} <- Jason.decode(bytes),
         @version <- json["version"] do
      workspace_paths = normalize_string_map(json["workspace_paths"])

      chat_rails =
        json
        |> Map.get("chat_rails", %{})
        |> Enum.reduce(%{}, fn {workspace_path, rail_state}, acc ->
          case normalize_chat_rail_state(rail_state) do
            {:ok, normalized} -> Map.put(acc, workspace_path, normalized)
            {:error, _reason} -> acc
          end
        end)

      %{empty | workspace_paths: workspace_paths, chat_rails: chat_rails}
    else
      _missing_corrupt_or_newer -> empty
    end
  end

  # Code reload updates this module without restarting the long-lived handoff
  # process. Migrate both historical in-memory shapes on the first call instead
  # of letting a newly-loaded callback index fields that the old state never had.
  defp ensure_runtime_state(
         %{store_path: store_path, workspace_paths: workspace_paths, chat_rails: chat_rails} =
           state
       )
       when is_binary(store_path) and is_map(workspace_paths) and is_map(chat_rails),
       do: state

  defp ensure_runtime_state(legacy) when is_map(legacy) do
    store_path = configured_store_path()
    loaded = load_store(store_path)

    workspace_paths =
      case Map.get(legacy, :workspace_paths) do
        paths when is_map(paths) -> normalize_string_map(paths)
        _old_shape -> legacy_workspace_paths(legacy)
      end

    chat_rails =
      case Map.get(legacy, :chat_rails) do
        rails when is_map(rails) -> normalize_legacy_chat_rails(rails)
        _old_shape -> legacy_chat_rails(legacy)
      end

    migrated = %{
      loaded
      | workspace_paths: Map.merge(loaded.workspace_paths, workspace_paths),
        chat_rails: Map.merge(loaded.chat_rails, chat_rails)
    }

    case write_store(migrated) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("workspace handoff migration write failed: #{inspect(reason)}")
    end

    migrated
  end

  defp legacy_workspace_paths(legacy) do
    legacy
    |> Enum.filter(fn {key, path} -> is_binary(key) and is_binary(path) end)
    |> Map.new()
  end

  defp legacy_chat_rails(legacy) do
    Enum.reduce(legacy, %{}, fn
      {{:chat_rails, path}, rail_state}, acc when is_binary(path) and is_map(rail_state) ->
        case normalize_chat_rail_state(rail_state) do
          {:ok, normalized} -> Map.put(acc, Path.expand(path), normalized)
          {:error, _reason} -> acc
        end

      _entry, acc ->
        acc
    end)
  end

  defp normalize_legacy_chat_rails(rails) do
    Enum.reduce(rails, %{}, fn
      {path, rail_state}, acc when is_binary(path) and is_map(rail_state) ->
        case normalize_chat_rail_state(rail_state) do
          {:ok, normalized} -> Map.put(acc, Path.expand(path), normalized)
          {:error, _reason} -> acc
        end

      _entry, acc ->
        acc
    end)
  end

  defp write_store(state) do
    payload = %{
      "version" => @version,
      "workspace_paths" => state.workspace_paths,
      "chat_rails" =>
        Map.new(state.chat_rails, fn {path, rail_state} -> {path, dump_rail_state(rail_state)} end)
    }

    directory = Path.dirname(state.store_path)
    temp = state.store_path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      with :ok <- File.mkdir_p(directory),
           :ok <- File.write(temp, Jason.encode_to_iodata!(payload), [:binary]),
           :ok <- File.chmod(temp, 0o600),
           :ok <- File.rename(temp, state.store_path) do
        :ok
      else
        {:error, reason} = error ->
          if is_atom(reason), do: error, else: {:error, reason}
      end
    rescue
      error -> {:error, Exception.message(error)}
    after
      _ = File.rm(temp)
    end
  end

  defp normalize_chat_rail_state(value) when is_map(value) do
    foregrounds = field(value, :foregrounds) || %{}
    active = field(value, :active_foregrounds) || %{}
    order = field(value, :foreground_order) || []

    with true <- is_map(foregrounds),
         true <- is_map(active),
         true <- is_list(order) do
      normalized_foregrounds =
        Enum.reduce(foregrounds, %{}, fn {rail_key, meta}, acc ->
          case normalize_foreground(rail_key, meta) do
            {:ok, key, normalized} -> Map.put(acc, key, normalized)
            :error -> acc
          end
        end)

      normalized_active =
        active
        |> Enum.filter(fn {key, rail_key} ->
          is_binary(key) and is_binary(rail_key) and
            Map.has_key?(normalized_foregrounds, rail_key)
        end)
        |> Map.new()

      normalized_order =
        order
        |> Enum.filter(&(is_binary(&1) and Map.has_key?(normalized_foregrounds, &1)))
        |> then(&Enum.uniq(&1 ++ Map.keys(normalized_foregrounds)))

      {:ok,
       %{
         foregrounds: normalized_foregrounds,
         active_foregrounds: normalized_active,
         foreground_order: normalized_order
       }}
    else
      _ -> {:error, :invalid_chat_rail_state}
    end
  end

  defp normalize_chat_rail_state(_value), do: {:error, :invalid_chat_rail_state}

  defp normalize_foreground(rail_key, meta) when is_binary(rail_key) and is_map(meta) do
    agent_id = field(meta, :agent_id)
    owner_session_id = field(meta, :owner_session_id)
    provider = field(meta, :provider)

    if is_binary(agent_id) and agent_id != "" and is_binary(owner_session_id) and
         owner_session_id != "" and (is_nil(provider) or is_binary(provider)) do
      normalized = %{
        agent_id: agent_id,
        owner_session_id: owner_session_id,
        provider: provider
      }

      normalized =
        case field(meta, :agent_state) do
          agent_state when is_map(agent_state) ->
            case normalize_agent_state(agent_state) do
              {:ok, %{id: ^agent_id} = state} -> Map.put(normalized, :agent_state, state)
              {:error, _reason} -> normalized
              {:ok, _mismatched_state} -> normalized
            end

          _missing ->
            normalized
        end

      {:ok, rail_key, normalized}
    else
      :error
    end
  end

  defp normalize_foreground(_rail_key, _meta), do: :error

  defp normalize_agent_state(value) when is_map(value) do
    id = field(value, :id)
    instance_id = field(value, :instance_id)
    provider_session_id = field(value, :provider_session_id)
    title = field(value, :title)
    title_user_edited? = field(value, :title_user_edited?) == true
    transcript = field(value, :transcript) || []
    adapter_opts = field(value, :adapter_opts) || %{}

    with true <- is_binary(id) and id != "",
         true <- is_nil(instance_id) or is_binary(instance_id),
         true <- is_nil(provider_session_id) or is_binary(provider_session_id),
         true <- is_nil(title) or is_binary(title),
         true <- is_list(transcript),
         true <- is_map(adapter_opts),
         {:ok, dialogs} <- normalize_dialogs(transcript) do
      {:ok,
       %{
         id: id,
         instance_id: instance_id,
         provider_session_id: provider_session_id,
         title: title,
         title_user_edited?: title_user_edited?,
         transcript: dialogs,
         adapter_opts: normalize_adapter_opts(adapter_opts)
       }}
    else
      _ -> {:error, :invalid_agent_state}
    end
  end

  defp normalize_agent_state(_value), do: {:error, :invalid_agent_state}

  defp normalize_dialogs(dialogs) do
    {:ok,
     Enum.map(dialogs, fn dialog ->
       dialog
       |> Agent.load_dialog!()
       |> Agent.dump_dialog()
     end)}
  rescue
    _error -> {:error, :invalid_agent_transcript}
  end

  defp normalize_adapter_opts(opts) do
    opts
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = to_string(key)

      if key in @persisted_adapter_opt_keys and json_scalar?(value) do
        Map.put(acc, key, if(is_atom(value), do: Atom.to_string(value), else: value))
      else
        acc
      end
    end)
  end

  defp json_scalar?(value),
    do:
      is_nil(value) or is_binary(value) or is_boolean(value) or is_number(value) or is_atom(value)

  defp dump_rail_state(rail_state) do
    %{
      "foregrounds" =>
        Map.new(rail_state.foregrounds, fn {rail_key, meta} ->
          {rail_key,
           %{
             "agent_id" => meta.agent_id,
             "owner_session_id" => meta.owner_session_id,
             "provider" => meta.provider,
             "agent_state" => dump_agent_state(Map.get(meta, :agent_state))
           }}
        end),
      "active_foregrounds" => rail_state.active_foregrounds,
      "foreground_order" => rail_state.foreground_order
    }
  end

  defp dump_agent_state(nil), do: nil

  defp dump_agent_state(agent_state) do
    %{
      "id" => agent_state.id,
      "instance_id" => agent_state.instance_id,
      "provider_session_id" => agent_state.provider_session_id,
      "title" => agent_state.title,
      "title_user_edited?" => agent_state.title_user_edited?,
      "transcript" => agent_state.transcript,
      "adapter_opts" => agent_state.adapter_opts
    }
  end

  defp normalize_string_map(value) when is_map(value) do
    value
    |> Enum.filter(fn {key, item} -> is_binary(key) and is_binary(item) end)
    |> Map.new()
  end

  defp normalize_string_map(_value), do: %{}

  defp field(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp default_store_path do
    if Application.get_env(:ecrits, :env) == :test do
      Path.join(
        System.tmp_dir!(),
        "ecrits-workspace-handoff-test-#{System.pid()}.json"
      )
    else
      Path.join([System.user_home!(), ".ecrits", "workspace_handoff.json"])
    end
  end

  defp configured_store_path do
    Application.get_env(:ecrits, :workspace_handoff_store_path) || default_store_path()
  end

  defp call(message) do
    case Process.whereis(@name) do
      pid when is_pid(pid) -> GenServer.call(pid, message)
      nil -> {:error, :workspace_handoff_unavailable}
    end
  end

  defp cast(message) do
    case Process.whereis(@name) do
      pid when is_pid(pid) -> GenServer.cast(pid, message)
      nil -> {:error, :workspace_handoff_unavailable}
    end
  end
end
