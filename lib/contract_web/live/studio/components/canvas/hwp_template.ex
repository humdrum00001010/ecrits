defmodule ContractWeb.Live.Studio.Components.Canvas.HwpTemplate do
  @moduledoc """
  HWP/HWPX-backed standard contract canvas.

  This component owns the rhwp SVG preview boundary for government
  standard-contract originals. StudioLive only chooses the current
  template; this component owns the DOM that rhwp mutates.
  """
  use ContractWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="relative h-full min-h-0 overflow-auto bg-white"
      data-component="canvas-hwp-template"
      data-contract-type-key={@spec.key}
      phx-hook="Rhwp"
      phx-update="ignore"
      data-document-path={template_path(@spec)}
      data-document-name={template_name(@spec)}
      data-matching-book={Jason.encode!(assigns[:matching_book] || %{})}
      data-field-values={Jason.encode!(assigns[:field_values] || %{})}
      data-editable-spec-candidates={Jason.encode!(assigns[:editable_spec_candidates] || [])}
      data-renderer="svg"
      data-role="standard-hwp-editor"
      data-site-id={@site_id}
      data-document-id={@document_id}
      data-text-events={Jason.encode!(assigns[:text_events] || [])}
      data-snapshot-url={assigns[:snapshot][:url]}
      data-snapshot-revision={assigns[:snapshot][:revision]}
      data-snapshot-lamport={assigns[:snapshot][:lamport]}
      data-snapshot-candidates={Jason.encode!(assigns[:snapshot_candidates] || [])}
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
        class="flex min-h-full w-full flex-col bg-white"
      >
      </div>
    </div>
    """
  end

  defp template_path(%{template_hwp_path: path}) when is_binary(path) and path != "", do: path
  defp template_path(%{template_hwpx_path: path}) when is_binary(path) and path != "", do: path

  defp template_name(spec) do
    spec
    |> template_path()
    |> Path.basename()
  end
end
