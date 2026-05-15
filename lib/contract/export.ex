defmodule Contract.Export do
  @moduledoc """
  Minimal export record returned by `Contract.IO.export/4`.

  Wave 4 will replace this with a full Oban job (`Contract.Export.Job`).
  For now it carries the four fields callers need post-upload: the export
  id, the R2 key, a presigned download URL, and the format atom.
  """

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          key: String.t(),
          url: String.t(),
          format: atom()
        }

  defstruct [:id, :key, :url, :format]
end

defmodule Contract.Export.Renderer do
  @moduledoc """
  Stub renderer. Wave 4 owns the real implementation for DOCX/PDF/HTML/MD.

  The `:hwpx` branch is live (`Contract.Export.HWPX`) — it dispatches to the
  hand-rolled OWPML writer when a caller has a `Contract.Runtime.State` to
  hand off. Callers without a state still get the stub body (the writer
  needs a projection; the 1-arg `render/1` shape only carries an id).

  Callers may pass `:render_fun` to `Contract.IO.R2.export/4` to override
  the renderer entirely (e.g. when the caller has a real projection in hand
  and wants to bypass the stub indirection).
  """

  @spec render(map()) :: {:ok, binary(), String.t()} | {:error, term()}
  def render(%{document_id: id, format: format}) do
    body = "EXPORT-STUB document=#{id} format=#{format}"
    content_type = content_type(format)
    {:ok, body, content_type}
  end

  @doc """
  Direct dispatch when a `Contract.Runtime.State` is in hand.

  This is the typed entry point — `Contract.IO.R2.export/4` accepts a
  `:render_fun` override that wraps this for the HWPX format.
  """
  @spec render(Contract.Runtime.State.t(), atom(), keyword()) ::
          {:ok, binary(), String.t()} | {:error, term()}
  def render(state, :hwpx, opts) do
    case Contract.Export.HWPX.render(state, opts) do
      {:ok, body} -> {:ok, body, content_type(:hwpx)}
      {:error, _} = err -> err
    end
  end

  def render(_state, format, _opts) do
    {:error, {:format_not_implemented, format}}
  end

  defp content_type(:pdf), do: "application/pdf"

  defp content_type(:docx),
    do: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  defp content_type(:html), do: "text/html"
  defp content_type(:md), do: "text/markdown"
  defp content_type(:markdown), do: "text/markdown"
  defp content_type(:hwpx), do: "application/hwp+zip"
  defp content_type(_), do: "application/octet-stream"
end
