defmodule Ecrits.Document.PreviewSnapshot do
  @moduledoc """
  Immutable, content-addressed bytes for durable document preview cards.

  Chat transcripts retain only the snapshot id and metadata. The bytes live in
  the application's temporary cache, separate from both the mutable workspace
  document and the destructive browser-upload spool.
  """

  alias Ecrits.Document

  @dir_name "ecrits-document-preview-snapshots"
  @max_bytes 256 * 1024 * 1024
  @id_regex ~r/\A[0-9a-f]{64}\z/
  @document_id_regex ~r/\Alocal-[A-Za-z0-9_-]{16,64}\z/

  @type descriptor :: %{
          required(:id) => String.t(),
          required(:document_id) => String.t(),
          required(:byte_size) => non_neg_integer(),
          required(:sha256) => String.t()
        }

  @spec put(String.t(), binary()) :: {:ok, descriptor()} | {:error, term()}
  def put(document_id, bytes)
      when is_binary(document_id) and is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    id = Document.sha256(bytes)
    path = path(document_id, id)

    with true <- valid_document_id?(document_id),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- persist_once(path, bytes, id) do
      {:ok, %{id: id, document_id: document_id, byte_size: byte_size(bytes), sha256: id}}
    else
      false -> {:error, :invalid_document_id}
      {:error, _reason} = error -> error
    end
  end

  def put(document_id, bytes) when is_binary(document_id) and is_binary(bytes),
    do: {:error, :too_large}

  def put(_document_id, _bytes), do: {:error, :invalid_bytes}

  @spec fetch(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(document_id, id) when is_binary(document_id) and is_binary(id) do
    with true <- valid_document_id?(document_id),
         true <- valid_id?(id),
         {:ok, bytes} <- File.read(path(document_id, id)),
         ^id <- Document.sha256(bytes) do
      {:ok, bytes}
    else
      false -> {:error, :invalid_snapshot_ref}
      digest when is_binary(digest) -> {:error, :snapshot_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def fetch(_document_id, _id), do: {:error, :invalid_snapshot_ref}

  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Regex.match?(@id_regex, id)
  def valid_id?(_id), do: false

  @doc false
  @spec dir() :: String.t()
  def dir, do: Path.join(System.tmp_dir!(), @dir_name)

  @doc false
  @spec path(String.t(), String.t()) :: String.t()
  def path(document_id, id), do: Path.join([dir(), document_id, id <> ".bin"])

  defp valid_document_id?(document_id), do: Regex.match?(@document_id_regex, document_id)

  defp persist_once(path, bytes, id) do
    case File.write(path, bytes, [:binary, :exclusive]) do
      :ok ->
        :ok

      {:error, :eexist} ->
        verify_existing(path, id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_existing(path, id) do
    case File.read(path) do
      {:ok, bytes} ->
        if Document.sha256(bytes) == id, do: :ok, else: {:error, :snapshot_digest_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
