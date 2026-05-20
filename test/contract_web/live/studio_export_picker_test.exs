defmodule ContractWeb.StudioExportPickerTest do
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Contract.Command
  alias Contract.Runtime

  setup :register_and_log_in_user

  test "standard HWP document export picker exposes only PDF and client-side HWPX", %{
    conn: conn,
    scope: scope
  } do
    document_id = Ecto.UUID.generate()

    action = %Command{
      kind: :create_document,
      document_id: document_id,
      actor_type: :user,
      actor_id: scope.user.id,
      base_revision: 0,
      idempotency_key: "create-studio-export-picker-#{document_id}",
      payload: %{"title" => "용역계약서", "type_key" => "service_agreement_v1"}
    }

    assert {:ok, %Contract.Change{}} = Runtime.apply(scope, action)

    {:ok, _lv, html} = live(conn, ~p"/documents/#{document_id}")

    assert html =~ ~s(data-role="export-picker")
    assert html =~ ~s(id="studio-export-picker")
    assert html =~ "CloseExportOnOutside"
    assert html =~ ~s(data-role="rhwp-export-pdf")
    assert html =~ ~s(data-role="rhwp-export-hwpx")
    assert html =~ "HWPX"

    refute html =~ ~s(phx-value-format="pdf")
    refute html =~ ~s(phx-value-format="hwpx")
    refute html =~ ~s(phx-value-format="docx")
    refute html =~ ~s(phx-value-format="markdown")
    refute html =~ ">DOCX<"
    refute html =~ ">Markdown<"
  end
end
