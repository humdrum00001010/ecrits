defmodule ContractWeb.Live.Studio.Components.Canvas.HwpTemplateTest do
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ContractWeb.Live.Studio.Components.Canvas.HwpTemplate

  test "renders an existing snapshot as the visual document source" do
    html =
      render_component(HwpTemplate,
        id: "standard-hwp-template-canvas",
        spec: %{
          key: "service_agreement_v1",
          template_hwp_path: "/assets/standard_contracts/service_agreement_v1.hwp"
        },
        matching_book: %{},
        field_values: %{},
        site_id: "user:test",
        document_id: "doc-1",
        text_events: [],
        snapshot: %{
          url: "/documents/doc-1/rhwp-snapshots/217.hwpx",
          revision: 217,
          lamport: 9
        },
        snapshot_candidates: [
          %{url: "/documents/doc-1/rhwp-snapshots/217.hwpx", revision: 217, lamport: 9},
          %{url: "/documents/doc-1/rhwp-snapshots/216.hwpx", revision: 216, lamport: nil}
        ]
      )

    assert html =~ ~s(data-document-path="/assets/standard_contracts/service_agreement_v1.hwp")
    assert html =~ ~s(data-snapshot-url="/documents/doc-1/rhwp-snapshots/217.hwpx")
    assert html =~ ~s(data-snapshot-revision="217")
    assert html =~ ~s(data-snapshot-lamport="9")
    assert html =~ ~s(data-snapshot-candidates=)
    assert html =~ ~s(/documents/doc-1/rhwp-snapshots/216.hwpx)
  end
end
