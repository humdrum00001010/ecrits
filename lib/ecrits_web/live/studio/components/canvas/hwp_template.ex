defmodule EcritsWeb.Live.Studio.Components.Canvas.HwpTemplate do
  @moduledoc """
  HWP/HWPX-backed standard contract canvas.

  Static metadata boundary for hosted HWP/HWPX templates.
  """
  use EcritsWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="relative h-full min-h-0 overflow-auto bg-white"
      data-component="canvas-hwp-template"
      data-contract-type-key={@spec.key}
      data-document-path={template_path(@spec)}
      data-document-name={template_name(@spec)}
      data-renderer="ehwp-svg"
      data-role={assigns[:role] || "standard-hwp-editor"}
      data-site-id={@site_id}
      data-document-id={@document_id}
      data-text-events={Jason.encode!(assigns[:text_events] || [])}
      data-snapshot-url={assigns[:snapshot][:url]}
      data-snapshot-revision={assigns[:snapshot][:revision]}
      data-snapshot-lamport={assigns[:snapshot][:lamport]}
      data-snapshot-candidates={Jason.encode!(assigns[:snapshot_candidates] || [])}
      data-snapshot-upload-event={assigns[:snapshot_upload_event]}
      data-local-document-id={assigns[:local_document_id]}
      data-local-document-format={assigns[:local_document_format]}
      data-local-document-revision={assigns[:local_document_revision]}
    >
      <p
        data-role="standard-hwp-status"
        class="absolute left-4 top-4 z-10 rounded-md bg-base-100/90 px-3 py-2 text-xs text-base-content/50 shadow-sm"
        hidden
      >
        표준계약서 원본을 준비하는 중입니다.
      </p>
      <div
        data-role="standard-hwp-svg"
        class="ehwp-document-stack"
      >
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
