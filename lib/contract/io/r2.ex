defmodule Contract.IO.R2 do
  @moduledoc """
  Cloudflare R2 (S3-compatible) wrapper over `ex_aws_s3`.

  Key conventions:
    * raw uploads → `matters/<matter_id>/sources/<artifact_id>.<ext>`
    * snapshots → `documents/<document_id>/snapshots/<revision>.json`
    * exports → `exports/<export_id>.<ext>`

  See SPEC.md §22, §23.
  """

  alias Contract.Types, as: T
  alias Contract.Export

  @doc """
  Uploads `body` to `key`. Returns `%{key, etag}` on success.

  Opts:
    * `:content_type` — sets the S3 `Content-Type` header.
    * `:cache_control` — sets the `Cache-Control` header.
    * `:ex_aws` — keyword overrides to pass to `ExAws.request/2`.
  """
  @spec put(String.t(), binary(), keyword()) ::
          {:ok, %{key: String.t(), etag: String.t() | nil}} | {:error, term()}
  def put(key, body, opts \\ []) when is_binary(key) and is_binary(body) do
    bucket = bucket!(opts)

    put_opts =
      []
      |> maybe_put(:content_type, Keyword.get(opts, :content_type))
      |> maybe_put(:cache_control, Keyword.get(opts, :cache_control))

    case ExAws.S3.put_object(bucket, key, body, put_opts)
         |> ExAws.request(ex_aws_config(opts)) do
      {:ok, %{headers: headers, status_code: status}} when status in 200..299 ->
        {:ok, %{key: key, etag: extract_header(headers, "etag")}}

      {:ok, response} ->
        {:error, {:r2_unexpected, response}}

      {:error, reason} ->
        {:error, {:r2_put_failed, reason}}
    end
  end

  @spec get(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def get(key, opts \\ []) do
    bucket = bucket!(opts)

    case ExAws.S3.get_object(bucket, key) |> ExAws.request(ex_aws_config(opts)) do
      {:ok, %{body: body, status_code: status}} when status in 200..299 ->
        {:ok, body}

      {:ok, response} ->
        {:error, {:r2_unexpected, response}}

      {:error, reason} ->
        {:error, {:r2_get_failed, reason}}
    end
  end

  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) do
    bucket = bucket!(opts)

    case ExAws.S3.delete_object(bucket, key) |> ExAws.request(ex_aws_config(opts)) do
      {:ok, %{status_code: status}} when status in 200..299 -> :ok
      {:ok, response} -> {:error, {:r2_unexpected, response}}
      {:error, reason} -> {:error, {:r2_delete_failed, reason}}
    end
  end

  @doc """
  Returns a presigned GET URL for `key`. Opts:
    * `:expires_in` — seconds (default 3600).
    * `:method` — `:get` (default) or `:put`.
  """
  @spec presigned_url(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def presigned_url(key, opts \\ []) do
    bucket = bucket!(opts)
    method = Keyword.get(opts, :method, :get)
    expires_in = Keyword.get(opts, :expires_in, 3600)

    config = ex_aws_config_struct(opts)

    ExAws.S3.presigned_url(config, method, bucket, key, expires_in: expires_in)
  end

  @doc """
  Orchestrates an export: invokes the render callback (Wave 4 owns the
  actual renderer) and uploads the rendered bytes to R2 under
  `exports/<export_id>.<ext>`.

  `render_fun` is an MFA or 1-arity fun receiving `%{document_id, format}`
  and returning `{:ok, binary, content_type}` or `{:ok, binary}`.
  """
  @spec export(T.ctx(), T.document_id(), atom(), keyword()) ::
          {:ok, Export.t()} | {:error, term()}
  def export(_ctx, document_id, format, opts \\ []) do
    render_fun = Keyword.get(opts, :render_fun) || (&Contract.Export.Renderer.render/1)
    export_id = Keyword.get(opts, :export_id) || Ecto.UUID.generate()

    with {:ok, body, content_type} <-
           invoke_render(render_fun, %{document_id: document_id, format: format}),
         ext = format_extension(format),
         key = "exports/#{export_id}.#{ext}",
         {:ok, _} <- put(key, body, content_type: content_type),
         {:ok, url} <- presigned_url(key) do
      {:ok, %Export{id: export_id, key: key, url: url, format: format}}
    end
  end

  # --- internals --------------------------------------------------------

  defp invoke_render(fun, payload) when is_function(fun, 1) do
    case fun.(payload) do
      {:ok, body, ct} when is_binary(body) -> {:ok, body, ct}
      {:ok, body} when is_binary(body) -> {:ok, body, "application/octet-stream"}
      {:error, _} = err -> err
      other -> {:error, {:bad_render_return, other}}
    end
  end

  defp invoke_render({m, f, a}, payload),
    do: invoke_render(fn p -> apply(m, f, [p | a]) end, payload)

  defp format_extension(:pdf), do: "pdf"
  defp format_extension(:docx), do: "docx"
  defp format_extension(:html), do: "html"
  defp format_extension(:md), do: "md"
  defp format_extension(:markdown), do: "md"
  defp format_extension(:hwpx), do: "hwpx"
  defp format_extension(other), do: to_string(other)

  defp bucket!(opts) do
    Keyword.get(opts, :bucket) ||
      Application.fetch_env!(:contract, :r2)[:bucket] ||
      env!("R2_BUCKET")
  end

  defp ex_aws_config(opts) do
    cfg = Application.fetch_env!(:contract, :r2)

    retries = Keyword.get(opts, :retries, max_attempts: 1, base_backoff_in_ms: 1)

    config = [
      access_key_id:
        Keyword.get(opts, :access_key_id) || cfg[:access_key_id] || "test-access-key",
      secret_access_key:
        Keyword.get(opts, :secret_access_key) || cfg[:secret_access_key] || "test-secret",
      region: Keyword.get(opts, :region, "auto"),
      retries: retries,
      json_codec: Jason
    ]

    case Keyword.get(opts, :endpoint) || cfg[:endpoint] do
      nil ->
        config

      endpoint when is_binary(endpoint) ->
        uri = URI.parse(endpoint)

        config
        |> Keyword.put(:host, uri.host)
        |> Keyword.put(:scheme, "#{uri.scheme}://")
        |> Keyword.put(:port, uri.port)
    end
  end

  defp ex_aws_config_struct(opts) do
    overrides = ex_aws_config(opts) |> Enum.into(%{})
    ExAws.Config.new(:s3, Map.to_list(overrides))
  end

  defp extract_header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} -> if String.downcase(to_string(k)) == name, do: v
      _ -> nil
    end)
  end

  defp extract_header(_, _), do: nil

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)

  defp env!(name) do
    case System.get_env(name) do
      val when is_binary(val) and val != "" -> val
      _ -> raise "missing required env var: #{name}"
    end
  end
end
