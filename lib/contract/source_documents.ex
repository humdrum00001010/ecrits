defmodule Contract.SourceDocuments do
  @moduledoc """
  Owner-scoped product flow for uploaded source documents.

  The upload path is:

      Blobs.put_upload -> SourceDocument -> Providers.parse_document -> SourceClaim
  """

  import Ecto.Query

  alias Contract.{BlobRef, Blobs, Context, Providers, Repo, SourceClaim, SourceDocument}
  alias Contract.Types, as: T

  @spec get(Context.t(), T.source_document_id()) :: T.result(SourceDocument.t())
  def get(%Context{} = ctx, source_document_id) when is_binary(source_document_id) do
    case Repo.get(SourceDocument, source_document_id) do
      nil -> {:error, :not_found}
      %SourceDocument{} = source_document -> authorize_owner(ctx, source_document)
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def get(_ctx, _source_document_id), do: {:error, :not_found}

  @spec list_for_document(Context.t(), T.document_id()) :: [SourceDocument.t()]
  def list_for_document(%Context{user: %{id: owner_id}}, document_id)
      when is_binary(document_id) do
    Repo.all(
      from sd in SourceDocument,
        where: sd.owner_id == ^owner_id and sd.document_id == ^document_id,
        order_by: [desc: sd.inserted_at]
    )
  end

  def list_for_document(_ctx, _document_id), do: []

  @spec create_from_upload(Context.t(), map(), keyword()) ::
          T.result({SourceDocument.t(), [SourceClaim.t()]})
  def create_from_upload(ctx, upload, opts \\ [])

  def create_from_upload(%Context{user: %{id: owner_id}} = ctx, upload, opts) do
    with {:ok, %BlobRef{} = blob_ref} <- Blobs.put_upload(ctx, upload, kind: "source_upload"),
         {:ok, %SourceDocument{} = source_document} <-
           insert_source_document(owner_id, blob_ref, upload, opts) do
      parse_inserted_source_document(ctx, source_document, blob_ref)
    else
      {:error, _} = err -> err
    end
  end

  def create_from_upload(%Context{}, _upload, _opts), do: {:error, :forbidden}
  def create_from_upload(_ctx, _upload, _opts), do: {:error, :forbidden}

  @spec create_from_blob_ref(Context.t(), BlobRef.t(), map(), keyword()) ::
          T.result({SourceDocument.t(), [SourceClaim.t()]})
  def create_from_blob_ref(ctx, blob_ref, attrs, opts \\ [])

  def create_from_blob_ref(
        %Context{user: %{id: owner_id}} = ctx,
        %BlobRef{} = blob_ref,
        attrs,
        opts
      ) do
    upload = %{
      client_name: Map.get(attrs, "file_name") || Map.get(attrs, :file_name),
      client_type: blob_ref.mime_type
    }

    with {:ok, %SourceDocument{} = source_document} <-
           insert_source_document(owner_id, blob_ref, upload, opts) do
      parse_inserted_source_document(ctx, source_document, blob_ref)
    end
  end

  def create_from_blob_ref(%Context{}, _blob_ref, _attrs, _opts), do: {:error, :forbidden}
  def create_from_blob_ref(_ctx, _blob_ref, _attrs, _opts), do: {:error, :forbidden}

  defp insert_source_document(owner_id, %BlobRef{} = blob_ref, upload, opts) do
    attrs = %{
      owner_id: owner_id,
      chat_thread_id: Keyword.get(opts, :chat_thread_id),
      document_id: Keyword.get(opts, :document_id),
      blob_ref_id: blob_ref.id,
      mime_type: blob_ref.mime_type,
      original_filename: upload_name(upload),
      status: "parsing"
    }

    %SourceDocument{}
    |> SourceDocument.changeset(attrs)
    |> Repo.insert()
  end

  defp parse_inserted_source_document(
         ctx,
         %SourceDocument{} = source_document,
         %BlobRef{} = blob_ref
       ) do
    with {:ok, parsed} <- Providers.parse_document(ctx, blob_ref, persist_snapshot?: true),
         {:ok, %SourceDocument{} = parsed_document} <- mark_parsed(source_document, parsed),
         {:ok, claims} <- insert_claims(parsed_document, parsed) do
      {:ok, {parsed_document, claims}}
    else
      {:error, reason} ->
        {:ok, failed_document} = mark_failed(source_document)
        {:error, {:source_parse_failed, reason, failed_document}}
    end
  end

  defp mark_parsed(%SourceDocument{} = source_document, parsed) do
    source_document
    |> SourceDocument.changeset(%{
      status: "ready",
      parser_snapshot_ref: parsed.parser_snapshot_ref,
      regions: parsed.regions || []
    })
    |> Repo.update()
  end

  defp mark_failed(%SourceDocument{} = source_document) do
    source_document
    |> SourceDocument.changeset(%{status: "failed"})
    |> Repo.update()
  end

  defp insert_claims(%SourceDocument{} = source_document, parsed) do
    claims = parsed.raw |> raw_claims() |> Enum.map(&claim_attrs(source_document, &1))

    inserted =
      Enum.map(claims, fn attrs ->
        %SourceClaim{}
        |> SourceClaim.changeset(attrs)
        |> Repo.insert!()
      end)

    {:ok, inserted}
  rescue
    e in Ecto.InvalidChangesetError -> {:error, e.changeset}
  end

  defp raw_claims(raw) when is_map(raw) do
    raw["claims"] || raw[:claims] || raw["source_claims"] || raw[:source_claims] || []
  end

  defp raw_claims(_raw), do: []

  defp claim_attrs(%SourceDocument{} = source_document, claim) when is_map(claim) do
    confidence = claim_value(claim, :confidence)

    %{
      source_document_id: source_document.id,
      region_id: claim_value(claim, :region_id) || "region:" <> Ecto.UUID.generate(),
      proposed_kind: to_string(claim_value(claim, :kind) || claim_value(claim, :proposed_kind)),
      proposed_value:
        value_to_string(claim_value(claim, :value) || claim_value(claim, :proposed_value)),
      proposed_structured: %{
        "anchors" => List.wrap(claim_value(claim, :anchors)),
        "raw" => stringify_map(claim)
      },
      confidence: confidence && to_string(confidence),
      rationale: claim_value(claim, :rationale),
      status: "proposed"
    }
  end

  defp claim_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value_to_string(nil), do: nil
  defp value_to_string(value) when is_binary(value), do: value
  defp value_to_string(value), do: to_string(value)

  defp stringify_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp upload_name(%{client_name: name}) when is_binary(name), do: name
  defp upload_name(%{"client_name" => name}) when is_binary(name), do: name
  defp upload_name(%{filename: name}) when is_binary(name), do: name
  defp upload_name(%{path: path}) when is_binary(path), do: Path.basename(path)
  defp upload_name(_upload), do: nil

  defp authorize_owner(
         %Context{user: %{id: owner_id}},
         %SourceDocument{owner_id: owner_id} = doc
       ),
       do: {:ok, doc}

  defp authorize_owner(%Context{}, %SourceDocument{}), do: {:error, :forbidden}
end
