defmodule Contract.Blobs do
  @moduledoc """
  Object storage façade (SPEC.md v0.5 §19).

  `Contract.Blobs` is the **only** module that talks to R2/S3/MinIO/local
  for blob payloads — uploaded source files, parser snapshots, exported
  PDF/HWPX/DOCX/Markdown, and oversized law-evidence payloads. Every
  operation takes a `Contract.Context` so future per-tenant bucket
  routing and audit logging have a hook.

  ## Surface

      put/3            — put raw bytes at a caller-chosen object_key
      put_upload/3     — consume a Plug.Upload, insert a BlobRef row
      get/2            — fetch bytes by blob_ref (struct or `%{object_key:}`)
      signed_url/3     — presigned GET/PUT URL
      delete/2         — remove the object

  Internally delegates to `Contract.IO.R2` (the existing S3-compatible
  `ex_aws_s3` wrapper). The schema row written by `put_upload/3` is the
  v0.5/w1 `Contract.BlobRef` Ecto schema. See SPEC.md §21 for the
  upload→parse pipeline.
  """

  alias Contract.BlobRef
  alias Contract.Repo
  alias Contract.Types, as: T

  @typedoc "A blob reference: full struct, plain map with :object_key, or raw key string."
  @type blob_like ::
          BlobRef.t()
          | %{required(:object_key) => String.t()}
          | %{required(:key) => String.t()}
          | String.t()

  # ---------------------------------------------------------------------------
  # put/3 — raw bytes upload (no BlobRef row).
  # ---------------------------------------------------------------------------

  @doc """
  Uploads `body` to `key`. Returns `{:ok, %{key, etag}}` on success.

  This is the low-level entry — callers that need a persistable
  `%BlobRef{}` should use `put_upload/3` instead.

  Opts forwarded to the R2 driver:
    * `:content_type` — `Content-Type` header.
    * `:cache_control` — `Cache-Control` header.
    * `:bucket` — overrides the default R2 bucket.
  """
  @spec put(T.ctx() | nil, String.t(), binary(), keyword()) ::
          {:ok, %{key: String.t(), etag: String.t() | nil}} | {:error, term()}
  def put(ctx \\ nil, key, body, opts \\ [])

  def put(_ctx, key, body, opts) when is_binary(key) and is_binary(body) do
    r2_driver().put(key, body, opts)
  end

  # ---------------------------------------------------------------------------
  # put_upload/3 — consume an upload, insert a BlobRef row.
  # ---------------------------------------------------------------------------

  @doc """
  Consumes a `%Plug.Upload{}` (or compatible `%{path: ..., client_name:
  ..., client_type: ..., client_size: ...}` map / `Phoenix.LiveView`
  upload-info map), uploads the bytes to R2 under
  `uploads/<owner_id>/<blob_id>.<ext>`, **inserts a `Contract.BlobRef`
  row** (W1 schema), and returns the persisted struct.

  Opts:
    * `:key` — explicit storage `object_key` (overrides the default
      `uploads/<owner>/<id>.<ext>` layout).
    * `:bucket` — bucket override (defaults to the configured R2 bucket).
    * `:kind`  — BlobRef.kind discriminator (default `"source_upload"`).
    * `:metadata` — extra metadata map.

  Returns `{:error, ...}` on read/upload/insert failure.
  """
  @spec put_upload(T.ctx() | nil, Plug.Upload.t() | map(), keyword()) ::
          T.result(BlobRef.t())
  def put_upload(ctx, upload, opts \\ []) do
    with {:ok, info} <- read_upload(upload),
         {:ok, body} <- File.read(info.path) do
      owner_id = owner_id_from_ctx(ctx)
      blob_id = Ecto.UUID.generate()
      object_key = Keyword.get(opts, :key) || default_key(owner_id, blob_id, info)
      bucket = Keyword.get(opts, :bucket) || default_bucket()
      kind = Keyword.get(opts, :kind, "source_upload")
      sha256_hex = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      put_opts =
        opts
        |> Keyword.take([:bucket, :cache_control])
        |> Keyword.put_new(:content_type, info.mime_type)

      case r2_driver().put(object_key, body, put_opts) do
        {:ok, %{key: ^object_key}} ->
          insert_blob_ref(blob_id, %{
            owner_id: owner_id,
            bucket: bucket,
            object_key: object_key,
            mime_type: info.mime_type,
            size_bytes: info.byte_size,
            sha256: sha256_hex,
            kind: kind,
            metadata: Map.merge(%{"client_name" => info.title}, Keyword.get(opts, :metadata, %{}))
          })

        {:error, _} = err ->
          err
      end
    end
  end

  defp insert_blob_ref(blob_id, attrs) do
    %BlobRef{id: blob_id}
    |> BlobRef.changeset(attrs)
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # get/2 — fetch bytes.
  # ---------------------------------------------------------------------------

  @doc """
  Reads the blob body referenced by `blob_ref`.

  Accepts a `%BlobRef{}`, a `%{object_key: ...}` / `%{key: ...}` map, or
  a raw key string.
  """
  @spec get(T.ctx() | nil, blob_like(), keyword()) :: {:ok, binary()} | {:error, term()}
  def get(ctx \\ nil, blob_ref, opts \\ [])

  def get(_ctx, %BlobRef{object_key: key}, opts) when is_binary(key),
    do: r2_driver().get(key, opts)

  def get(_ctx, %{object_key: key}, opts) when is_binary(key), do: r2_driver().get(key, opts)
  def get(_ctx, %{"object_key" => key}, opts) when is_binary(key), do: r2_driver().get(key, opts)
  def get(_ctx, %{key: key}, opts) when is_binary(key), do: r2_driver().get(key, opts)
  def get(_ctx, %{"key" => key}, opts) when is_binary(key), do: r2_driver().get(key, opts)
  def get(_ctx, key, opts) when is_binary(key), do: r2_driver().get(key, opts)

  # ---------------------------------------------------------------------------
  # signed_url/3 — presigned URL.
  # ---------------------------------------------------------------------------

  @doc """
  Returns a presigned URL for the blob.

  Opts:
    * `:expires_in` — seconds (default 3600).
    * `:method` — `:get` (default) or `:put`.
  """
  @spec signed_url(T.ctx() | nil, blob_like(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def signed_url(ctx \\ nil, blob_ref, opts \\ [])

  def signed_url(_ctx, %BlobRef{object_key: key}, opts) when is_binary(key),
    do: r2_driver().presigned_url(key, opts)

  def signed_url(_ctx, %{object_key: key}, opts) when is_binary(key),
    do: r2_driver().presigned_url(key, opts)

  def signed_url(_ctx, %{"object_key" => key}, opts) when is_binary(key),
    do: r2_driver().presigned_url(key, opts)

  def signed_url(_ctx, %{key: key}, opts) when is_binary(key),
    do: r2_driver().presigned_url(key, opts)

  def signed_url(_ctx, %{"key" => key}, opts) when is_binary(key),
    do: r2_driver().presigned_url(key, opts)

  def signed_url(_ctx, key, opts) when is_binary(key),
    do: r2_driver().presigned_url(key, opts)

  # ---------------------------------------------------------------------------
  # direct upload — browser PUTs bytes to R2, server only records metadata.
  # ---------------------------------------------------------------------------

  @spec prepare_direct_upload(T.ctx() | nil, map(), keyword()) ::
          {:ok, %{object_key: String.t(), upload_url: String.t()}} | {:error, term()}
  def prepare_direct_upload(ctx, params, opts \\ []) when is_map(params) do
    owner_id = owner_id_from_ctx(ctx)
    blob_id = Ecto.UUID.generate()
    title = param(params, "file_name") || "upload.bin"
    byte_size = param(params, "byte_size") || 0
    max_size = Keyword.get(opts, :max_file_size, 50_000_000)

    cond do
      is_nil(owner_id) ->
        {:error, :forbidden}

      byte_size > max_size ->
        {:error, {:file_too_large, byte_size, max_size}}

      true ->
        info = %{title: title}
        object_key = Keyword.get(opts, :key) || default_key(owner_id, blob_id, info)

        with {:ok, upload_url} <- signed_url(ctx, object_key, method: :put, expires_in: 900) do
          {:ok, %{object_key: object_key, upload_url: upload_url}}
        end
    end
  end

  @spec complete_direct_upload(T.ctx() | nil, map(), keyword()) :: T.result(BlobRef.t())
  def complete_direct_upload(ctx, params, opts \\ []) when is_map(params) do
    owner_id = owner_id_from_ctx(ctx)
    object_key = param(params, "object_key")

    cond do
      not is_binary(owner_id) ->
        {:error, :forbidden}

      not valid_owner_key?(object_key, owner_id) ->
        {:error, :invalid_object_key}

      true ->
        blob_id = Ecto.UUID.generate()
        bucket = Keyword.get(opts, :bucket) || default_bucket()
        kind = Keyword.get(opts, :kind, "source_upload")

        insert_blob_ref(blob_id, %{
          owner_id: owner_id,
          bucket: bucket,
          object_key: object_key,
          mime_type: param(params, "mime_type") || "application/octet-stream",
          size_bytes: param(params, "byte_size"),
          sha256: param(params, "sha256"),
          kind: kind,
          metadata: %{"client_name" => param(params, "file_name")}
        })
    end
  end

  # ---------------------------------------------------------------------------
  # delete/2 — remove the object.
  # ---------------------------------------------------------------------------

  @spec delete(T.ctx() | nil, blob_like(), keyword()) :: :ok | {:error, term()}
  def delete(ctx \\ nil, blob_ref, opts \\ [])

  def delete(_ctx, %BlobRef{object_key: key}, opts) when is_binary(key),
    do: r2_driver().delete(key, opts)

  def delete(_ctx, %{object_key: key}, opts) when is_binary(key),
    do: r2_driver().delete(key, opts)

  def delete(_ctx, %{"object_key" => key}, opts) when is_binary(key),
    do: r2_driver().delete(key, opts)

  def delete(_ctx, %{key: key}, opts) when is_binary(key), do: r2_driver().delete(key, opts)
  def delete(_ctx, %{"key" => key}, opts) when is_binary(key), do: r2_driver().delete(key, opts)
  def delete(_ctx, key, opts) when is_binary(key), do: r2_driver().delete(key, opts)

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp r2_driver do
    Application.get_env(:contract, :io_drivers, [])
    |> Keyword.get(:r2, Contract.IO.R2)
  end

  defp read_upload(%Plug.Upload{path: path, filename: filename, content_type: ct}) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        {:ok,
         %{
           path: path,
           title: filename || Path.basename(path),
           mime_type: ct || "application/octet-stream",
           byte_size: size
         }}

      {:error, reason} ->
        {:error, {:upload_stat_failed, reason}}
    end
  end

  defp read_upload(%{path: path} = upload) do
    title = Map.get(upload, :client_name) || Map.get(upload, :title) || Path.basename(path)

    mime =
      Map.get(upload, :client_type) || Map.get(upload, :mime_type) || "application/octet-stream"

    declared = Map.get(upload, :client_size) || Map.get(upload, :byte_size)

    case File.stat(path) do
      {:ok, %{size: size}} ->
        {:ok, %{path: path, title: title, mime_type: mime, byte_size: declared || size}}

      {:error, reason} ->
        {:error, {:upload_stat_failed, reason}}
    end
  end

  defp read_upload(%{"path" => path} = upload) do
    title = Map.get(upload, "client_name") || Map.get(upload, "title") || Path.basename(path)

    mime =
      Map.get(upload, "client_type") || Map.get(upload, "mime_type") || "application/octet-stream"

    declared = Map.get(upload, "client_size") || Map.get(upload, "byte_size")

    case File.stat(path) do
      {:ok, %{size: size}} ->
        {:ok, %{path: path, title: title, mime_type: mime, byte_size: declared || size}}

      {:error, reason} ->
        {:error, {:upload_stat_failed, reason}}
    end
  end

  defp read_upload(other), do: {:error, {:invalid_upload, other}}

  defp default_key(owner_id, blob_id, info) do
    ext = info.title |> Path.extname() |> String.trim_leading(".") |> default_ext()
    "uploads/#{owner_id || "anon"}/#{blob_id}.#{ext}"
  end

  defp default_ext(""), do: "bin"
  defp default_ext(ext), do: String.downcase(ext)

  defp valid_owner_key?(key, owner_id) when is_binary(key) and is_binary(owner_id),
    do: String.starts_with?(key, "uploads/#{owner_id}/")

  defp valid_owner_key?(_key, _owner_id), do: false

  defp param(params, "byte_size"), do: Map.get(params, "byte_size") || Map.get(params, :byte_size)
  defp param(params, "file_name"), do: Map.get(params, "file_name") || Map.get(params, :file_name)
  defp param(params, "mime_type"), do: Map.get(params, "mime_type") || Map.get(params, :mime_type)

  defp param(params, "object_key"),
    do: Map.get(params, "object_key") || Map.get(params, :object_key)

  defp param(params, "sha256"), do: Map.get(params, "sha256") || Map.get(params, :sha256)
  defp param(_params, _key), do: nil

  defp default_bucket do
    case Application.get_env(:contract, :r2) do
      cfg when is_list(cfg) -> Keyword.get(cfg, :bucket) || "uploads"
      _ -> "uploads"
    end
  end

  defp owner_id_from_ctx(%Contract.Context{user: %{id: id}}) when not is_nil(id), do: id
  defp owner_id_from_ctx(_), do: nil
end
