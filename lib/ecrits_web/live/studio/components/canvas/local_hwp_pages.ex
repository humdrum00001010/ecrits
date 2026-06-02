defmodule EcritsWeb.Live.Studio.Components.Canvas.LocalHwpPages do
  @moduledoc """
  Local HWP/HWPX page stack rendered by server-side EHWP.
  """

  use EcritsWeb, :html

  attr :id, :string, required: true
  attr :pages, :any, required: true
  attr :page_count, :integer, default: 0
  attr :spec, :map, required: true
  attr :document_id, :string, required: true
  attr :local_document_format, :string, required: true
  attr :local_document_revision, :integer, required: true

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="relative h-full min-h-0 overflow-auto bg-white"
      data-component="canvas-local-hwp-pages"
      data-renderer="ehwp-svg"
      data-role="local-ehwp-editor"
      data-document-id={@document_id}
      data-document-path={template_path(@spec)}
      data-document-name={template_name(@spec)}
      data-contract-type-key={@spec.key}
      data-local-document-id={@document_id}
      data-local-document-format={@local_document_format}
      data-local-document-revision={@local_document_revision}
      data-ehwp-page-count={@page_count}
    >
      <div
        id={"#{@id}-pages"}
        data-role="local-ehwp-pages"
        class="ehwp-document-stack"
        phx-update="stream"
      >
        <section
          :for={{dom_id, page} <- @pages}
          id={dom_id}
          class="ehwp-svg-page"
          data-role="local-ehwp-page"
          data-page-index={page.index}
          data-page-number={page.number}
        >
          {Phoenix.HTML.raw(page.svg)}
        </section>
      </div>
    </div>
    """
  end

  defp template_path(%{template_hwp_path: path}) when is_binary(path) and path != "", do: path
  defp template_path(%{template_hwpx_path: path}) when is_binary(path) and path != "", do: path

  defp template_name(%{name: name}) when is_binary(name) and name != "", do: name

  defp template_name(spec) do
    spec
    |> template_path()
    |> Path.basename()
  end
end
