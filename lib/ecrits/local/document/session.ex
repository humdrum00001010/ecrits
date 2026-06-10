defmodule Ecrits.Local.Document.Session do
  @moduledoc """
  Active local document session backed by one workspace file.

  The session owns current bytes for a local document. Saves replace the
  canonical workspace file atomically; checkpoints are in-memory only.
  """

  use GenServer

  alias Ecrits.Local.Document
  alias Ecrits.Local.Metadata

  @registry Ecrits.Local.Document.Registry

  def start_link(args) do
    document_id = Keyword.fetch!(args, :id)
    GenServer.start_link(__MODULE__, args, name: via(document_id))
  end

  def child_spec(args) do
    %{
      id: {__MODULE__, Keyword.fetch!(args, :id)},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def document(target), do: call(target, :document)
  def read(target), do: call(target, :read)
  def checkpoint(target, bytes, attrs \\ %{}), do: call(target, {:checkpoint, bytes, attrs})
  def save(target, bytes, attrs \\ %{}), do: call(target, {:save, bytes, attrs})
  def record_mutation(target, envelope), do: call(target, {:record_mutation, envelope})

  def close(target) do
    target
    |> resolve()
    |> case do
      pid when is_pid(pid) ->
        result = GenServer.stop(pid, :normal)
        _ = :sys.get_state(@registry)
        result

      nil ->
        {:error, :not_found}
    end
  end

  def whereis(document_id) when is_binary(document_id) do
    case Registry.lookup(@registry, document_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def whereis(_document_id), do: nil

  @impl true
  def init(args) do
    path = Keyword.fetch!(args, :path)

    with {:ok, bytes} <- File.read(path) do
      document = Document.build(args, bytes)

      {:ok,
       %{
         args: args,
         document: document,
         bytes: bytes,
         snapshots: []
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:document, _from, state) do
    {:reply, {:ok, state.document}, state}
  end

  def handle_call(:read, _from, state) do
    {:reply, {:ok, state.bytes}, state}
  end

  def handle_call({:checkpoint, bytes, attrs}, _from, state) when is_binary(bytes) do
    persist_snapshot(state, bytes, attrs, write_canonical?: false)
  end

  def handle_call({:checkpoint, _bytes, _attrs}, _from, state) do
    {:reply, {:error, :invalid_bytes}, state}
  end

  def handle_call({:save, bytes, attrs}, _from, state) when is_binary(bytes) do
    with :ok <-
           Ecrits.Local.FS.write(
             state.document.workspace_root,
             state.document.relative_path,
             bytes
           ) do
      persist_snapshot(state, bytes, attrs, write_canonical?: true)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:save, _bytes, _attrs}, _from, state) do
    {:reply, {:error, :invalid_bytes}, state}
  end

  def handle_call({:record_mutation, envelope}, _from, state) when is_map(envelope) do
    record = mutation_record(state.document, envelope)
    {:reply, {:ok, Metadata.envelope(record)}, state}
  end

  def handle_call({:record_mutation, _envelope}, _from, state) do
    {:reply, {:error, :invalid_mutation}, state}
  end

  defp persist_snapshot(state, bytes, attrs, opts) do
    saved? = Keyword.fetch!(opts, :write_canonical?)
    attrs = attrs |> Map.new() |> Map.put("kind", snapshot_kind(opts))
    snapshot = snapshot_record(state.document, bytes, saved?, attrs)

    current_bytes = bytes
    document = Document.build(state.args, current_bytes)
    snapshot = Metadata.envelope(snapshot)
    snapshots = state.snapshots ++ [snapshot_summary(snapshot)]

    state = %{
      state
      | document: document,
        bytes: current_bytes,
        snapshots: snapshots
    }

    publish(document, snapshot)
    {:reply, {:ok, document, snapshot}, state}
  end

  defp call(target, message) do
    target
    |> resolve()
    |> case do
      pid when is_pid(pid) -> GenServer.call(pid, message)
      nil -> {:error, :not_found}
    end
  end

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(%Document{id: document_id}), do: whereis(document_id)
  defp resolve(document_id) when is_binary(document_id), do: whereis(document_id)
  defp resolve(_target), do: nil

  defp snapshot_record(_document, bytes, saved?, attrs) do
    attrs
    |> Map.new()
    |> Map.merge(%{
      "saved" => saved?,
      "path" => nil,
      "byte_size" => byte_size(bytes),
      "sha256" => Document.sha256(bytes)
    })
  end

  defp snapshot_summary(snapshot) do
    %{
      "saved" => snapshot["saved"],
      "path" => snapshot["path"],
      "sha256" => snapshot["sha256"]
    }
  end

  defp mutation_record(%Document{} = document, envelope) do
    %{
      "document_id" => document.id,
      "relative_path" => document.relative_path,
      "event_id" => string_param(envelope, "eventId", "event_id"),
      "site_id" => string_param(envelope, "siteId", "site_id"),
      "lamport" => integer_param(envelope, "lamport"),
      "body" => map_param(envelope, "body"),
      "received_at_ms" => System.system_time(:millisecond)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp string_param(envelope, primary, fallback) do
    case Map.get(envelope, primary) || Map.get(envelope, fallback) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp integer_param(envelope, key) do
    case Map.get(envelope, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> nil
        end

      _value ->
        nil
    end
  end

  defp map_param(envelope, key) do
    case Map.get(envelope, key) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp snapshot_kind(write_canonical?: true), do: "save"
  defp snapshot_kind(write_canonical?: false), do: "checkpoint"

  defp publish(document, %{"saved" => true} = snapshot) do
    Phoenix.PubSub.broadcast(Ecrits.PubSub, Document.topic(document.id), {
      :local_document_saved,
      document,
      snapshot
    })
  end

  defp publish(document, snapshot) do
    Phoenix.PubSub.broadcast(Ecrits.PubSub, Document.topic(document.id), {
      :local_document_checkpointed,
      document,
      snapshot
    })
  end

  defp via(document_id), do: {:via, Registry, {@registry, document_id}}
end
