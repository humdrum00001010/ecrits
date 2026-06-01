defmodule Contract.RhwpSnapshot do
  @moduledoc """
  Legacy DB helpers for hosted RHWP snapshot rows.

  Cloud object persistence is retired. Active local-first HWP/HWPX snapshots
  and checkpoints are written by `Contract.Local.Document` under the mounted
  workspace `.contract` directory.
  """

  import Ecto.Query, only: [from: 2]

  alias Contract.Repo
  alias Contract.RhwpSnapshot.Record

  @retired_error {:error, :cloud_storage_retired}

  @doc """
  Retired hosted snapshot commit path.
  """
  @spec commit(binary() | nil, integer(), binary(), map()) ::
          {:ok, Record.t()} | {:error, term()}
  def commit(nil, _rev, _key, _ir), do: {:error, :no_document}
  def commit(_document_id, _revision, _snapshot_key, _ir), do: @retired_error

  @doc """
  Retired hosted snapshot upload path.
  """
  @spec upload_and_commit(binary() | nil, integer(), binary(), map(), binary()) ::
          {:ok, Record.t()} | {:error, term()}
  def upload_and_commit(nil, _rev, _body, _ir, _format), do: {:error, :no_document}
  def upload_and_commit(_document_id, _revision, _body, _ir, _format), do: @retired_error

  @doc """
  Return the most recent legacy RHWP visual snapshot row for a document.
  """
  @spec latest_for_document(binary() | nil) :: Record.t() | nil
  def latest_for_document(nil), do: nil

  def latest_for_document(document_id) when is_binary(document_id) do
    Repo.one(
      from s in Record,
        where: s.document_id == ^document_id,
        order_by: [desc: s.revision],
        limit: 1
    )
  end

  @spec latest_for_document(binary() | nil, binary() | nil) :: Record.t() | nil
  def latest_for_document(nil, _format), do: nil

  def latest_for_document(document_id, nil) when is_binary(document_id),
    do: latest_for_document(document_id)

  def latest_for_document(document_id, format)
      when is_binary(document_id) and is_binary(format) do
    with {:ok, format} <- normalize_format(format) do
      Repo.one(
        from s in Record,
          where: s.document_id == ^document_id and s.format == ^format,
          order_by: [desc: s.revision],
          limit: 1
      )
    else
      _ -> nil
    end
  end

  @doc """
  Return newest legacy RHWP visual snapshot rows for render fallback.
  """
  @spec candidates_for_document(binary() | nil, binary() | nil, keyword()) :: [Record.t()]
  def candidates_for_document(document_id, format, opts \\ [])
  def candidates_for_document(nil, _format, _opts), do: []

  def candidates_for_document(document_id, nil, opts) when is_binary(document_id) do
    limit = Keyword.get(opts, :limit, 5)

    Repo.all(
      from s in Record,
        where: s.document_id == ^document_id,
        order_by: [desc: s.revision],
        limit: ^limit
    )
  end

  def candidates_for_document(document_id, format, opts)
      when is_binary(document_id) and is_binary(format) do
    limit = Keyword.get(opts, :limit, 5)

    with {:ok, format} <- normalize_format(format) do
      Repo.all(
        from s in Record,
          where: s.document_id == ^document_id and s.format == ^format,
          order_by: [desc: s.revision],
          limit: ^limit
      )
    else
      _ -> []
    end
  end

  @doc """
  True when a legacy RHWP snapshot row exists for the exact document revision.
  """
  @spec committed_for_revision?(binary() | nil, integer() | nil) :: boolean()
  def committed_for_revision?(document_id, revision)
      when is_binary(document_id) and is_integer(revision) do
    Repo.exists?(
      from s in Record,
        where: s.document_id == ^document_id and s.revision == ^revision
    )
  end

  def committed_for_revision?(_document_id, _revision), do: false

  @spec get(binary(), integer(), binary()) :: Record.t() | nil
  def get(document_id, revision, format)
      when is_binary(document_id) and is_integer(revision) and is_binary(format) do
    Repo.get_by(Record, document_id: document_id, revision: revision, format: format)
  end

  @spec key_for(binary(), integer(), binary()) :: {:ok, binary()} | {:error, term()}
  def key_for(document_id, revision, format)
      when is_binary(document_id) and is_integer(revision) and is_binary(format) do
    with {:ok, format} <- normalize_format(format) do
      {:ok, "documents/#{document_id}/snapshots/#{revision}.#{format}"}
    end
  end

  @doc """
  Companion key for a `.hwp` or `.hwpx` snapshot key.
  """
  @spec ir_key_for(binary()) :: binary()
  def ir_key_for(snapshot_key) when is_binary(snapshot_key) do
    cond do
      String.ends_with?(snapshot_key, ".hwp") ->
        String.replace_suffix(snapshot_key, ".hwp", ".ir.json")

      String.ends_with?(snapshot_key, ".hwpx") ->
        String.replace_suffix(snapshot_key, ".hwpx", ".ir.json")

      String.ends_with?(snapshot_key, ".ir.json") ->
        snapshot_key

      true ->
        snapshot_key <> ".ir.json"
    end
  end

  @spec content_type_for(binary()) :: binary()
  def content_type_for("hwp"), do: "application/x-hwp"
  def content_type_for("hwpx"), do: "application/hwp+zip"
  def content_type_for(_), do: "application/octet-stream"

  @spec normalize_format(binary()) :: {:ok, binary()} | {:error, term()}
  def normalize_format(format) when is_binary(format) do
    case String.downcase(format) do
      "hwp" -> {:ok, "hwp"}
      "hwpx" -> {:ok, "hwpx"}
      other -> {:error, {:unsupported_rhwp_format, other}}
    end
  end
end
