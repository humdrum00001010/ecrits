defmodule ContractWeb.PacketLiveTest do
  use ContractWeb.ConnCase, async: false

  @moduletag :legacy_saas

  import Phoenix.LiveViewTest

  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.Packets
  alias Contract.Packets.PacketDocument
  alias Contract.Repo

  describe "auth gate" do
    test "redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/packets/#{Ecto.UUID.generate()}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "packet detail" do
    setup :register_and_log_in_user

    test "renders attached documents and compact document actions", %{conn: conn, scope: scope} do
      {:ok, packet} =
        Packets.create_packet(scope, %{
          "title" => "서비스 계약",
          "counterparty" => "Gamma Inc.",
          "status" => "active"
        })

      {:ok, document} = Documents.create(scope, %{title: "서비스계약서 원본"})
      {:ok, _packet_document} = Packets.attach_document(scope, packet.id, document.id)

      {:ok, lv, _html} = live(conn, ~p"/packets/#{packet.id}")

      assert has_element?(lv, "#packet-title-form")

      assert has_element?(
               lv,
               "#packet-title-form[phx-hook='ContractWeb.PacketLive.BlurPacketTitleOnSubmit']"
             )

      assert has_element?(lv, "#packet-title-input[value='서비스 계약']")
      assert has_element?(lv, "#packets-root header #packet-new-document", "새 문서")
      refute has_element?(lv, "#packets-root > header a[href='/storage']")
      assert has_element?(lv, "table.table tbody#packet-documents-table")
      assert has_element?(lv, "#attached-document-#{document.id}", "서비스계약서 원본")
      assert has_element?(lv, "#attached-document-#{document.id}.hover\\:bg-base-200\\/60")
      assert has_element?(lv, "#attached-document-#{document.id} td.cursor-pointer")
      assert has_element?(lv, "#attached-document-#{document.id} td[data-table-action]")
      assert has_element?(lv, "#document-settings-#{document.id}[aria-label=\"문서 설정\"]")
      refute has_element?(lv, "#attached-document-#{document.id}.cursor-pointer")

      refute has_element?(
               lv,
               ~s(#attached-document-#{document.id} a[href="/documents/#{document.id}"])
             )

      assert render(lv) =~ "/documents/#{document.id}"
      assert render(lv) =~ "/documents/#{document.id}?packet_id=#{packet.id}"
      refute has_element?(lv, "table.table th", "상태")
      refute has_element?(lv, "#packets-root table.table-zebra")
      refute has_element?(lv, "#packets-root header p")
      refute has_element?(lv, "#packets-root", "Gamma Inc.")
      refute has_element?(lv, "#packet-documents-panel h2")
      refute has_element?(lv, "#packets-root", "문서들")
      refute has_element?(lv, "#packet-documents-panel h2", "연결된 문서")
      refute has_element?(lv, "#packets-root", "상태 없음")
      refute has_element?(lv, "#packets-root", "진행 중")
      refute has_element?(lv, "#packet-attach-panel")
      refute has_element?(lv, "#packet-reference-form")
      refute has_element?(lv, "#reference_document_id")
      refute has_element?(lv, "#packet-reference-submit")
      refute has_element?(lv, "#detach-document-#{document.id}")
      refute has_element?(lv, "#document-edit-#{document.id}")
      refute has_element?(lv, "#document-delete-#{document.id}")
    end

    test "edits packet title directly in the header", %{conn: conn, scope: scope} do
      {:ok, packet} =
        Packets.create_packet(scope, %{
          "title" => "수정 전 패킷",
          "counterparty" => "Gamma Inc.",
          "status" => "active"
        })

      {:ok, lv, _html} = live(conn, ~p"/packets/#{packet.id}")

      lv
      |> form("#packet-title-form", packet: %{title: "수정된 패킷"})
      |> render_change()

      assert has_element?(lv, "#packet-title-input[value='수정된 패킷']")
      assert {:ok, loaded} = Packets.get_packet(scope, packet.id)
      assert loaded.title == "수정된 패킷"
    end

    test "document settings removes attached document after confirmation", %{
      conn: conn,
      scope: scope
    } do
      {:ok, packet} =
        Packets.create_packet(scope, %{
          "title" => "문서 설정 패킷",
          "counterparty" => "Gamma Inc.",
          "status" => "active"
        })

      {:ok, document} = Documents.create(scope, %{title: "삭제 대상 문서"})
      {:ok, _packet_document} = Packets.attach_document(scope, packet.id, document.id)

      {:ok, lv, _html} = live(conn, ~p"/packets/#{packet.id}")

      lv
      |> element("#document-settings-#{document.id}")
      |> render_click()

      assert has_element?(lv, "#document-settings-modal", "삭제 대상 문서")
      assert has_element?(lv, "#document-settings-modal", "다른 패킷에 연결되어 있지 않으면 문서가 삭제됩니다.")
      refute has_element?(lv, "#document-settings-modal", "보관 처리")
      assert has_element?(lv, "#document-delete-confirm")
      assert has_element?(lv, "#attached-document-#{document.id}")
      assert Repo.get_by(PacketDocument, packet_id: packet.id, document_id: document.id)

      lv
      |> element("#document-delete-confirm")
      |> render_click()

      refute has_element?(lv, "#document-settings-modal")
      refute has_element?(lv, "#attached-document-#{document.id}")
      assert Repo.get_by(PacketDocument, packet_id: packet.id, document_id: document.id) == nil
      assert Repo.get(Document, document.id) == nil
    end

    test "새 문서 opens Studio type picker with packet context and creates no document yet", %{
      conn: conn,
      scope: scope
    } do
      {:ok, packet} =
        Packets.create_packet(scope, %{
          "title" => "신규 문서 패킷",
          "counterparty" => "Delta Inc.",
          "status" => "active"
        })

      {:ok, lv, _html} = live(conn, ~p"/packets/#{packet.id}")

      lv
      |> element("#packet-new-document")
      |> render_click()

      {:ok, loaded} = Packets.get_packet(scope, packet.id)
      assert loaded.documents == []
      assert Documents.list_recent_for_scope(scope, 1) == []
      assert_redirect(lv, ~p"/studio?packet_id=#{packet.id}")
    end

    test "renders backend-attached reference document without reference picker", %{
      conn: conn,
      scope: scope
    } do
      {:ok, current_packet} =
        Packets.create_packet(scope, %{
          "title" => "현재 패킷",
          "counterparty" => "Current",
          "status" => "active"
        })

      {:ok, other_packet} =
        Packets.create_packet(scope, %{
          "title" => "다른 패킷",
          "counterparty" => "Other",
          "status" => "active"
        })

      {:ok, reference_doc} = Documents.create(scope, %{title: "다른 패킷 문서"})

      {:ok, _packet_document} =
        Packets.attach_document(scope, other_packet.id, reference_doc.id)

      {:ok, _packet_document} =
        Packets.attach_document(scope, current_packet.id, reference_doc.id, %{role: "reference"})

      {:ok, lv, _html} = live(conn, ~p"/packets/#{current_packet.id}")

      assert has_element?(lv, "#attached-document-#{reference_doc.id}", "다른 패킷 문서")
      assert render(lv) =~ "/documents/#{reference_doc.id}"
      assert render(lv) =~ "/documents/#{reference_doc.id}?packet_id=#{current_packet.id}"

      refute has_element?(
               lv,
               ~s(#attached-document-#{reference_doc.id} a[href="/documents/#{reference_doc.id}"])
             )

      {:ok, loaded} = Packets.get_packet(scope, current_packet.id)
      assert Enum.any?(loaded.documents, &(&1.id == reference_doc.id))

      packet_document =
        Contract.Repo.get_by!(Contract.Packets.PacketDocument,
          packet_id: current_packet.id,
          document_id: reference_doc.id
        )

      assert packet_document.role == "reference"
      refute has_element?(lv, "#packet-attach-panel")
      refute has_element?(lv, "#packet-reference-form")
      refute has_element?(lv, "#reference_document_id")
      refute has_element?(lv, "#packet-reference-submit")
    end

    test "does not open another user's packet", %{conn: conn} do
      other_user = Contract.AccountsFixtures.user_fixture()
      other_scope = Contract.Context.for_user(other_user)

      {:ok, packet} =
        Packets.create_packet(other_scope, %{
          "title" => "타인 패킷",
          "counterparty" => "Other",
          "status" => "active"
        })

      assert {:error, {:live_redirect, %{to: "/storage"}}} =
               live(conn, ~p"/packets/#{packet.id}")
    end
  end
end
