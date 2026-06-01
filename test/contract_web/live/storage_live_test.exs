defmodule ContractWeb.StorageLiveTest do
  use ContractWeb.ConnCase, async: false

  @moduletag :legacy_saas

  import Phoenix.LiveViewTest

  alias Contract.Documents
  alias Contract.Packets

  describe "auth gate" do
    test "redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/storage")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "packet library" do
    setup :register_and_log_in_user

    test "renders packet table and opens create modal", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/storage")

      assert has_element?(lv, "#storage-root")
      assert has_element?(lv, "#open-packet-create-modal", "생성")
      assert has_element?(lv, "table.table tbody#packets-table")
      assert has_element?(lv, "table.table th", "패킷")
      assert has_element?(lv, "#packets-empty")
      assert html =~ "보관함"

      refute has_element?(lv, "#packet-create-form")
      refute has_element?(lv, "#storage-root table.table-zebra")
      refute has_element?(lv, "[data-role='document-card']")
      refute has_element?(lv, "[data-role='packet-card']")
      refute has_element?(lv, "table.table th", "상대방")
      refute has_element?(lv, "table.table th", "수정일")
      refute has_element?(lv, "table.table th", "상태")

      lv
      |> element("#open-packet-create-modal")
      |> render_click()

      assert has_element?(lv, "#packet-create-modal")
      assert has_element?(lv, "#packet-create-form")
      assert has_element?(lv, ~s(#packet-create-form input[name="packet[title]"]))
      refute has_element?(lv, ~s(#packet-create-form input[name="packet[counterparty]"]))
      refute has_element?(lv, ~s(#packet-create-form select[name="packet[status]"]))
      refute has_element?(lv, "#packet-create-form", "계약서 업로드")
    end

    test "lists owned packets and row click navigates to packet detail", %{
      conn: conn,
      scope: scope
    } do
      {:ok, packet} =
        Packets.create_packet(scope, %{
          "title" => "공급계약 검토",
          "counterparty" => "Acme Korea",
          "status" => "active"
        })

      {:ok, lv, _html} = live(conn, ~p"/storage")

      html = render(lv)

      assert has_element?(lv, "table.table tbody#packets-table")
      assert has_element?(lv, "#packet-row-#{packet.id}", "공급계약 검토")
      assert has_element?(lv, "#packet-row-#{packet.id}.hover\\:bg-base-200\\/60")
      assert has_element?(lv, "#packet-row-#{packet.id} td.cursor-pointer")
      refute has_element?(lv, "#packet-row-#{packet.id}.cursor-pointer")
      refute has_element?(lv, ~s(#packet-row-#{packet.id} a[href="/packets/#{packet.id}"]))
      assert html =~ "/packets/#{packet.id}"
      assert has_element?(lv, "#packet-actions-#{packet.id}")
      assert has_element?(lv, ~s(#packet-settings-#{packet.id}[aria-label="패킷 설정"]))
      refute has_element?(lv, "#packet-edit-#{packet.id}")
      refute has_element?(lv, "#packet-delete-#{packet.id}")
      refute html =~ "Acme Korea"
      refute html =~ "진행 중"
      refute has_element?(lv, "table.table th", "상대방")
      refute has_element?(lv, "table.table th", "상태")
      refute has_element?(lv, "[data-role='packet-card']")
      refute has_element?(lv, "#packets-table .rounded-full")
      refute has_element?(lv, "#storage-root table.table-zebra")
    end

    test "creates a packet from the modal form", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/storage")

      lv
      |> element("#open-packet-create-modal")
      |> render_click()

      lv
      |> form("#packet-create-form",
        packet: %{
          title: "NDA 검토"
        }
      )
      |> render_submit()

      [packet] = Packets.list_packets_for_scope(scope)
      assert packet.title == "NDA 검토"
      assert_redirect(lv, ~p"/packets/#{packet.id}")
    end

    test "edits a packet title from the action column without row navigation", %{
      conn: conn,
      scope: scope
    } do
      {:ok, packet} = Packets.create_packet(scope, %{"title" => "Before"})
      {:ok, lv, _html} = live(conn, ~p"/storage")

      lv
      |> element("#packet-settings-#{packet.id}")
      |> render_click()

      :ok = refute_redirected(lv)
      assert has_element?(lv, "#packet-settings-modal")
      assert has_element?(lv, "#packet-edit-form")
      assert has_element?(lv, "#packet-settings-delete")

      lv
      |> form("#packet-edit-form", packet: %{title: "After"})
      |> render_submit()

      :ok = refute_redirected(lv)
      {:ok, updated} = Packets.get_packet(scope, packet.id)
      assert updated.title == "After"
      assert has_element?(lv, "#packet-row-#{packet.id}", "After")
      refute has_element?(lv, "#packet-settings-modal")
    end

    test "deletes a packet from the action column only after confirmation", %{
      conn: conn,
      scope: scope
    } do
      {:ok, packet} = Packets.create_packet(scope, %{"title" => "Delete me"})
      {:ok, document} = Documents.create(scope, %{title: "Keep me"})
      {:ok, _packet_document} = Packets.attach_document(scope, packet.id, document.id)
      {:ok, lv, _html} = live(conn, ~p"/storage")

      lv
      |> element("#packet-settings-#{packet.id}")
      |> render_click()

      :ok = refute_redirected(lv)
      assert has_element?(lv, "#packet-settings-modal")
      assert has_element?(lv, "#packet-settings-delete")
      assert has_element?(lv, "#packet-settings-modal", "다른 패킷이 참조하지 않는 문서는 함께 삭제됩니다.")
      refute has_element?(lv, "#packet-delete-modal")
      assert has_element?(lv, "#packet-row-#{packet.id}", "Delete me")
      assert {:ok, _packet} = Packets.get_packet(scope, packet.id)

      lv
      |> element("#packet-settings-delete")
      |> render_click()

      :ok = refute_redirected(lv)
      assert has_element?(lv, "#packet-delete-modal")
      assert has_element?(lv, "#packet-delete-modal", "다른 패킷이 참조하지 않는 문서는 함께 삭제됩니다.")
      refute has_element?(lv, "#packet-settings-modal")
      assert has_element?(lv, "#packet-row-#{packet.id}", "Delete me")

      lv
      |> element("#packet-delete-confirm")
      |> render_click()

      :ok = refute_redirected(lv)
      assert {:error, :not_found} = Packets.get_packet(scope, packet.id)
      assert {:error, :not_found} = Documents.get(scope, document.id)
      refute has_element?(lv, "#packet-row-#{packet.id}")
      refute has_element?(lv, "#packet-delete-modal")
    end
  end
end
