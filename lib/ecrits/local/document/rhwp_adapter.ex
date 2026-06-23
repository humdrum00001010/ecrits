defmodule Ecrits.Local.Document.RhwpAdapter do
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
  alias Ecrits.Doc.Pool
  alias Ecrits.Local.Document
  alias Ecrits.Local.Document.ByteSpool

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

  defp format_atom("hwpx"), do: :hwpx
  defp format_atom(_format), do: :hwp
end
