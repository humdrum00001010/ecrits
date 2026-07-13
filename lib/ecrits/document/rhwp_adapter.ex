defmodule Ecrits.Document.RhwpAdapter do
  @moduledoc """
  Adapter between rhwp's snapshot payload shape and local document sessions.

  This is also the SYNC SEAM between the two arms that can hold the same HWP
  file (design §6.2 "browser is the authority for a viewed doc"):

    * browser -> server: `checkpoint/2`/`save/2` push the viewer's exported
      bytes into the agent pool's server twin (`Ecrits.Doc.Pool.refresh_by_path/3`),
      so a viewer detach (tab switch) never strands the agent tools on a stale
      NIF copy.
    * server -> browser: `open/3`/`load/1` serve a DIRTY server twin's bytes
      (unsaved agent edits made while no viewer was attached) instead of the
      canonical file, so a newly attached viewer doesn't render — and later
      checkpoint over — a model that silently lacks those edits.
  """

  alias Ecrits.Doc.Editor
  alias Ecrits.Doc.Office
  alias Ecrits.Doc.Pool
  alias Ecrits.Document
  alias Ecrits.Document.ByteSpool

  @spec open(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def open(workspace_root, relative_path, opts \\ []) do
    with {:ok, %Document{} = document} <- Document.open(workspace_root, relative_path, opts),
         {:ok, bytes} <- Document.read(document) do
      {:ok, load_response(document, authoritative_bytes(document, bytes))}
    end
  end

  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(document_id) when is_binary(document_id) do
    with {:ok, %Document{} = document} <- Document.document(document_id),
         {:ok, bytes} <- Document.read(document) do
      {:ok, load_response(document, authoritative_bytes(document, bytes))}
    end
  end

  @spec checkpoint(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def checkpoint(document_id, params) when is_binary(document_id) and is_map(params) do
    with {:ok, %Document{} = document} <- Document.document(document_id),
         {:ok, bytes} <- decode_bytes(params),
         :ok <- verify_format(document, params),
         {:ok, saved_document, snapshot} <- Document.checkpoint(document, bytes, attrs(params)) do
      :ok = sync_server_twin(document, bytes)
      {:ok, save_response(saved_document, snapshot)}
    end
  end

  @spec save(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def save(document_id, params) when is_binary(document_id) and is_map(params) do
    with {:ok, %Document{} = document} <- Document.document(document_id),
         {:ok, bytes} <- decode_bytes(params),
         :ok <- verify_format(document, params),
         {:ok, saved_document, snapshot} <- Document.save(document, bytes, attrs(params)) do
      :ok = sync_server_twin(document, bytes)
      {:ok, save_response(saved_document, snapshot)}
    end
  end

  @spec save_replay(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def save_replay(document_id, params) when is_binary(document_id) and is_map(params) do
    with {:ok, %Document{} = document} <- Document.document(document_id),
         :ok <- verify_format(document, params),
         {:ok, kind} <- office_kind(document.format),
         {:ok, journal} <- replay_journal(params),
         {:ok, bytes} <- replay_office_journal(document, kind, journal),
         {:ok, saved_document, snapshot} <- Document.save(document, bytes, attrs(params)) do
      :ok = sync_server_twin(document, bytes)
      {:ok, save_response(saved_document, snapshot)}
    end
  end

  @spec record_mutation(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_mutation(document_id, params) when is_binary(document_id) and is_map(params) do
    with {:ok, _document} <- Document.document(document_id),
         {:ok, mutation} <- Document.record_mutation(document_id, params) do
      {:ok, %{ok: true, local: true, mutation: mutation}}
    end
  end

  defp load_response(%Document{} = document, bytes) do
    %{
      ok: true,
      local: true,
      document_id: document.id,
      relative_path: document.relative_path,
      format: document.format,
      content_type: Document.content_type(document.format),
      byte_size: byte_size(bytes),
      sha256: Document.sha256(bytes),
      bytes: bytes
    }
  end

  defp save_response(%Document{} = document, snapshot) do
    %{
      ok: true,
      local: true,
      document_id: document.id,
      relative_path: document.relative_path,
      format: document.format,
      snapshot: snapshot
    }
  end

  defp decode_bytes(params), do: ByteSpool.decode(params)

  defp replay_journal(params) do
    journal = param(params, :journal) || param(params, :replay_journal)

    case journal do
      [_ | _] = entries -> {:ok, entries}
      _other -> {:error, :missing_replay_journal}
    end
  end

  defp replay_office_journal(%Document{path: path, format: format}, kind, journal)
       when is_binary(path) do
    tmp_path = replay_tmp_path(format)

    case Office.open(path, kind: kind) do
      {:ok, handle} ->
        try do
          with :ok <- apply_replay_journal(handle, journal),
               {:ok, _saved} <- Office.save(handle, format: kind, path: tmp_path),
               {:ok, bytes} <- File.read(tmp_path) do
            {:ok, bytes}
          else
            :ok ->
              case File.read(tmp_path) do
                {:ok, bytes} -> {:ok, bytes}
                {:error, reason} -> {:error, {:office_replay_failed, "read failed: #{reason}"}}
              end

            {:error, reason} ->
              {:error, {:office_replay_failed, replay_error(reason)}}
          end
        after
          _ = Office.close(handle)
          _ = File.rm(tmp_path)
        end

      {:error, reason} ->
        {:error, {:office_replay_failed, replay_error(reason)}}
    end
  end

  defp replay_tmp_path(format) do
    ext = format |> to_string() |> String.trim_leading(".")

    Path.join(
      System.tmp_dir!(),
      "ecrits-office-save-replay-#{System.unique_integer([:positive, :monotonic])}.#{ext}"
    )
  end

  defp apply_replay_journal(handle, journal) do
    Enum.reduce_while(journal, :ok, fn entry, :ok ->
      case apply_replay_entry(handle, entry) do
        :ok -> {:cont, :ok}
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_replay_entry(handle, %{} = entry) do
    case replay_verb(entry) do
      "edit" ->
        case replay_value(entry, :op) do
          %{} = op -> Office.edit(handle, op)
          _other -> {:error, "replay edit entry is missing op"}
        end

      "set" ->
        with ref when is_binary(ref) and ref != "" <- replay_value(entry, :ref),
             %{} = props <- replay_value(entry, :props) do
          Office.set(handle, ref, props)
        else
          _other -> {:error, "replay set entry requires ref and props"}
        end

      verb ->
        {:error, "unsupported replay verb: #{inspect(verb)}"}
    end
  end

  defp apply_replay_entry(_handle, _entry), do: {:error, "replay entry must be an object"}

  defp replay_verb(entry), do: replay_value(entry, :verb) || replay_value(entry, :type)

  defp replay_value(entry, key) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp replay_error(reason) when is_binary(reason), do: reason
  defp replay_error(%{message: message}) when is_binary(message), do: message
  defp replay_error(%{"message" => message}) when is_binary(message), do: message
  defp replay_error(reason), do: inspect(reason)

  defp verify_format(document, params) do
    case param(params, :format) do
      nil ->
        :ok

      format ->
        with {:ok, normalized} <- Document.normalize_format(to_string(format)),
             true <- normalized == document.format do
          :ok
        else
          false -> {:error, :format_mismatch}
          {:error, _} = error -> error
        end
    end
  end

  defp attrs(params) do
    %{
      request_id: param(params, :request_id),
      ir: param(params, :ir),
      context: param(params, :context)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp param(params, key) when is_map(params) and is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  # browser -> server: feed the viewer's checkpoint bytes to the agent pool's
  # server twin. Best-effort by design — no twin open (the common case when no
  # agent has touched the doc) is a no-op, and a refresh failure must never
  # fail the checkpoint itself (the snapshot store write already succeeded).
  defp sync_server_twin(%Document{path: path}, bytes) when is_binary(path) do
    # Truly best-effort: the twin reload reaches a pool Editor (and, for office,
    # its singleton Instance) over GenServer.call — a crash there `exit`s the
    # CALLER, not just returns an error. The checkpoint/save already succeeded,
    # so swallow any failure here instead of taking the LiveView down with it.
    try do
      _ = Pool.refresh_by_path(path, bytes)
      :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp sync_server_twin(_document, _bytes), do: :ok

  # server -> browser: when the agent pool holds a DIRTY twin (unsaved doc.edit
  # ops applied while no viewer was attached), its exported bytes — not the
  # canonical file — are what the viewer must render. Falls back to the disk
  # bytes whenever there is no twin, it is clean, or it cannot export.
  defp authoritative_bytes(%Document{path: path} = document, disk_bytes)
       when is_binary(path) do
    with {:ok, %{id: id}} <- Pool.info_by_path(path),
         {:ok, twin_bytes} when is_binary(twin_bytes) <-
           Pool.with_doc(id, fn editor ->
             if Editor.dirty?(editor) do
               Editor.export_bytes(editor, format_atom(document.format))
             else
               {:error, :clean}
             end
           end) do
      twin_bytes
    else
      _ -> disk_bytes
    end
  end

  defp authoritative_bytes(_document, disk_bytes), do: disk_bytes

  defp office_kind("docx"), do: {:ok, :docx}
  defp office_kind("pptx"), do: {:ok, :pptx}
  defp office_kind("xlsx"), do: {:ok, :xlsx}
  defp office_kind(_format), do: {:error, :unsupported_replay_format}

  defp format_atom("hwpx"), do: :hwpx
  defp format_atom(_format), do: :hwp
end
