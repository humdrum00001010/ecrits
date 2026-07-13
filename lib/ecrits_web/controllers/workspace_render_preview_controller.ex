defmodule EcritsWeb.WorkspaceRenderPreviewController do
  @moduledoc """
  Serves the PNG files `doc.render` writes to the canonical render scratch dir
  so the chat rail can show an inline preview on the render tool-call chips
  (the agent itself consumes the same files via its native image tool).

  Gating: only regular `.png` files INSIDE `System.tmp_dir!()/ecrits_render`
  are served — the requested path is expanded and prefix-checked against the
  canonical dir, so this route can never read arbitrary filesystem paths.
  """

  use EcritsWeb, :controller

  def show(conn, %{"file" => file}) when is_binary(file) do
    render_dir = Path.join(System.tmp_dir!(), "ecrits_render")
    expanded = Path.expand(file)

    with true <- String.starts_with?(expanded, render_dir <> "/"),
         true <- Path.extname(expanded) == ".png",
         true <- File.regular?(expanded),
         {:ok, bytes} <- File.read(expanded) do
      conn
      |> put_resp_content_type("image/png")
      # Renders overwrite the same path; never let the browser cache a stale one.
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def show(conn, _params), do: send_resp(conn, 400, "")
end
