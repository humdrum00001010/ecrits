defmodule Ecrits.Local.Document.RhwpAdapter do
  @moduledoc """
  Adapter between rhwp's snapshot payload shape and local document sessions.
  """

  alias Ecrits.Local.Document

  @spec open(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def open(workspace_root, relative_path, opts \\ []) do
    with {:ok, %Document{} = document} <- Document.open(workspace_root, relative_path, opts),
         {:ok, bytes} <- Document.read(document) do
      {:ok, load_response(document, bytes)}
    end
  end

  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(document_id) when is_binary(document_id) do
    with {:ok, %Document{} = document} <- Document.document(document_id),
         {:ok, bytes} <- Document.read(document) do
      {:ok, load_response(document, bytes)}
    end
  end

  @spec checkpoint(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def checkpoint(document_id, params) when is_binary(document_id) and is_map(params) do
    with {:ok, %Document{} = document} <- Document.document(document_id),
         :ok <- verify_format(document, params),
         {:ok, bytes} <- decode_bytes(params),
         {:ok, saved_document, snapshot} <- Document.checkpoint(document, bytes, attrs(params)) do
      {:ok, save_response(saved_document, snapshot)}
    end
  end

  @spec save(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def save(document_id, params) when is_binary(document_id) and is_map(params) do
    with {:ok, %Document{} = document} <- Document.document(document_id),
         :ok <- verify_format(document, params),
         {:ok, bytes} <- decode_bytes(params),
         {:ok, saved_document, snapshot} <- Document.save(document, bytes, attrs(params)) do
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

  defp decode_bytes(%{"bytes_base64" => encoded}) when is_binary(encoded),
    do: Base.decode64(encoded)

  defp decode_bytes(%{bytes_base64: encoded}) when is_binary(encoded),
    do: Base.decode64(encoded)

  defp decode_bytes(%{"bytes" => bytes}) when is_binary(bytes), do: {:ok, bytes}
  defp decode_bytes(%{bytes: bytes}) when is_binary(bytes), do: {:ok, bytes}
  defp decode_bytes(_params), do: {:error, :missing_bytes}

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
end
