defmodule EcritsWeb.WorkspaceEditPreviewController do
  @moduledoc """
  Renders the partial image represented by a durable chat-rail edit-preview
  descriptor. Workspace/document validation is identical to the raw-bytes
  controller, so this route cannot open an arbitrary filesystem path.
  """

  use EcritsWeb, :controller

  alias Ecrits.Doc.EditPreview
  alias Ecrits.Document

  @max_ref_bytes 16_384

  def show(conn, %{"path" => workspace_path, "document" => relative_path} = params)
      when is_binary(workspace_path) and is_binary(relative_path) do
    ref = Map.get(params, "ref")

    with true <- is_nil(ref) or (is_binary(ref) and byte_size(ref) <= @max_ref_bytes),
         {:ok, args} <- Document.open_args(workspace_path, relative_path),
         path = Keyword.fetch!(args, :path),
         format = Keyword.fetch!(args, :format),
         {:ok, png, metadata} <- EditPreview.render(path, format, ref) do
      conn
      |> put_resp_content_type("image/png")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-ecrits-preview-backend", preview_backend(format))
      |> put_resp_header("x-ecrits-preview-meta", encode_metadata(metadata))
      |> send_resp(200, png)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def show(conn, _params), do: send_resp(conn, 400, "")

  defp preview_backend(format) when format in ~w(hwp hwpx), do: "ehwp"
  defp preview_backend(_format), do: "libreofficex"

  defp encode_metadata(metadata) do
    metadata
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end
end
