defmodule EcritsWeb.Live.Studio.Components.Canvas.HwpTemplateTest do
  use EcritsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EcritsWeb.Live.Studio.Components.Canvas.HwpTemplate

  test "renders an existing snapshot as the visual document source" do
    html =
      render_component(HwpTemplate,
        id: "standard-hwp-template-canvas",
        spec: %{
          key: "service_agreement_v1",
          template_hwp_path: "/assets/standard_contracts/service_agreement_v1.hwp"
        },
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
    assert html =~ ~s(data-renderer="ehwp-svg")
    assert html =~ ~s(data-snapshot-url="/documents/doc-1/rhwp-snapshots/217.hwpx")
    assert html =~ ~s(data-snapshot-revision="217")
    assert html =~ ~s(data-snapshot-lamport="9")
    assert html =~ ~s(data-snapshot-candidates=)
    assert html =~ ~s(/documents/doc-1/rhwp-snapshots/216.hwpx)
    refute html =~ "data-editable-spec-candidates"
    refute html =~ "data-matching-book"
    refute html =~ "data-field-values"
    refute html =~ ~s(phx-hook="Rhwp")
    refute html =~ ~s(phx-update="ignore")
  end

  test "renders optional local snapshot event attrs" do
    html =
      render_component(HwpTemplate,
        id: "local-hwp-template-canvas",
        spec: %{
          key: "custom_v1",
          template_hwpx_path: "/local/documents/local-doc-1/source.hwpx"
        },
        site_id: "local:test",
        document_id: "local-doc-1",
        local_document_id: "local-doc-1",
        local_document_format: "hwpx",
        local_document_revision: 3,
        snapshot_upload_event: "rhwp.local.snapshot.save",
        role: "local-rhwp-editor",
        text_events: [],
        snapshot: nil,
        snapshot_candidates: []
      )

    assert html =~ ~s(data-snapshot-upload-event="rhwp.local.snapshot.save")
    assert html =~ ~s(data-local-document-id="local-doc-1")
    assert html =~ ~s(data-local-document-format="hwpx")
    assert html =~ ~s(data-local-document-revision="3")
    assert html =~ ~s(data-role="local-rhwp-editor")
  end
end
