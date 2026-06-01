defmodule ContractWeb.DocumentLiveMatchingTest do
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Contract.Accounts.User
  alias Contract.Context
  alias Contract.Studio.State
  alias ContractWeb.DocumentLive

  setup do
    user = %User{id: Ecto.UUID.generate(), email: "matching@example.com"}
    scope = %Context{Context.for_user(user) | perms: ~w(read write)a}
    %{scope: scope}
  end

  defmodule RenderLive do
    use ContractWeb, :live_view

    alias Phoenix.Component, as: PC

    @impl true
    def mount(_params, session, socket) do
      socket =
        socket
        |> PC.assign(:current_scope, session["current_scope"])
        |> PC.assign(:document_packet, nil)
        |> PC.assign(:other_documents, [])
        |> PC.assign(:document_picker_packet_id, nil)
        |> PC.assign(:current_document, nil)
        |> PC.assign(:projection, %{type_key: session["type_key"]})
        |> PC.assign(:studio_state, %State{selected_document_id: Ecto.UUID.generate()})
        |> PC.assign(:viewport, :desktop)
        |> PC.assign(:chat_rail_hidden?, true)
        |> PC.assign(:rhwp_matching_book, session["matching_book"] || %{})
        |> PC.assign(:rhwp_field_values, %{})
        |> PC.assign(:rhwp_text_events, [])
        |> PC.assign(:rhwp_snapshot, nil)
        |> PC.assign(:rhwp_snapshot_candidates, [])
        |> PC.assign(:agent_document_status, nil)
        |> PC.assign(:chat_thread, nil)
        |> PC.assign(:grill_marks, [])
        |> PC.assign(:grill_active?, false)
        |> stream_configure(:chat_messages, dom_id: &"chat-msg-#{&1.id}")
        |> stream(:chat_messages, [])
        |> stream_configure(:toasts, dom_id: &"toast-#{&1.id}")
        |> stream(:toasts, [])

      {:ok, socket}
    end

    @impl true
    def render(assigns), do: DocumentLive.render(assigns)
  end

  describe "RHWP matching sources" do
    test "unsupported NDA exposes no matching book or editable candidates", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _lv, html} =
        live_isolated(conn, RenderLive,
          session: %{"current_scope" => scope, "type_key" => "nda_v1"}
        )

      assert html =~ ~s(data-document-path="/assets/standard_contracts/nda_v1.hwp")
      assert html =~ ~s(data-matching-book="{}")
      assert html =~ ~s(data-editable-spec-candidates="[]")
      refute html =~ "legacy_nda"
      refute html =~ "employment_v1.editables.json"
      refute html =~ "service_agreement_v1.editables.json"
    end

    test "supported standards expose only current type editable candidate", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _lv, html} =
        live_isolated(conn, RenderLive,
          session: %{"current_scope" => scope, "type_key" => "service_agreement_v1"}
        )

      assert html =~ "service_agreement_v1.editables.json"
      refute html =~ "employment_v1.editables.json"
      refute html =~ "nda_v1.editables.json"
    end
  end

  describe "RHWP matching change handling after DB retirement" do
    test "ignores unsupported and cross-type matching book changes", %{scope: scope} do
      socket = matching_socket(scope, "nda_v1")
      matching_book = %{"itemsById" => %{"unexpected" => %{}}}

      assert {:noreply, ^socket} =
               DocumentLive.handle_event(
                 "rhwp.matching_book.changed",
                 %{"contract_type_key" => "nda_v1", "matching_book" => matching_book},
                 socket
               )

      socket = matching_socket(scope, "service_agreement_v1")

      assert {:noreply, ^socket} =
               DocumentLive.handle_event(
                 "rhwp.matching_book.changed",
                 %{"contract_type_key" => "employment_v1", "matching_book" => matching_book},
                 socket
               )
    end

    test "leaves current supported matching book unchanged when DB persistence is retired", %{
      scope: scope
    } do
      socket = matching_socket(scope, "service_agreement_v1")
      matching_book = %{"itemsById" => %{"service_scope" => %{"aboveIndex" => nil}}}

      assert {:noreply, ^socket} =
               DocumentLive.handle_event(
                 "rhwp.matching_book.changed",
                 %{
                   "contract_type_key" => "service_agreement_v1",
                   "matching_book" => matching_book
                 },
                 socket
               )
    end
  end

  defp matching_socket(scope, type_key) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_scope: scope,
        projection: %{type_key: type_key}
      }
    }
  end
end
