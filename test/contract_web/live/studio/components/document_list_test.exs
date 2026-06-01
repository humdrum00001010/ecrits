defmodule ContractWeb.Live.Studio.Components.DocumentListTest do
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Contract.Accounts.User
  alias Contract.Context
  alias Contract.Documents.Document
  alias Contract.Studio.State
  alias ContractWeb.Live.Studio.Components.DocumentList

  setup do
    Gettext.put_locale(ContractWeb.Gettext, "en")
    user = %User{id: Ecto.UUID.generate(), email: "local@example.com"}
    scope = %Context{Context.for_user(user) | perms: ~w(read write)a}
    %{user: user, scope: scope}
  end

  test "renders document-first empty state with create controls for writers", %{scope: scope} do
    html =
      render_component(DocumentList,
        id: "doc-list",
        studio_state: %State{mode: :no_document, last_seen_revision: 0},
        current_scope: scope
      )

    assert html =~ ~s(data-role="document-list")
    assert html =~ "Documents"
    assert html =~ ~s(data-role="documents-empty")
    assert html =~ ~s(phx-value-modal="new_document")
    refute html =~ "Matter"
    refute html =~ "Workspace"
  end

  test "renders owner-scoped recent documents and selected row", %{scope: scope} do
    doc_a = document(scope, title: "Alpha", type_key: "nda_v1")
    doc_b = document(scope, title: "Beta", type_key: nil)
    stub_documents([doc_a, doc_b])

    html =
      render_component(DocumentList,
        id: "doc-list",
        studio_state: %State{
          selected_document_id: doc_a.id,
          mode: :editing,
          last_seen_revision: 0
        },
        current_scope: scope
      )

    assert html =~ "Alpha"
    assert html =~ "Beta"
    assert html =~ ~s(data-document-id="#{doc_a.id}")
    assert html =~ ~s(data-document-id="#{doc_b.id}")
    assert html =~ ~s(phx-click="document.open")
    assert html =~ ~s(phx-value-document_id="#{doc_a.id}")
    assert html =~ ~r/data-document-id="#{doc_a.id}"[^>]*data-selected="true"/s
  end

  test "renders every persisted document status in one document group", %{scope: scope} do
    documents =
      for status <- [:draft, :importing, :editing, :reviewing, :export_ready] do
        document(scope, title: "#{status} document", status: status)
      end

    stub_documents(documents)

    html =
      render_component(DocumentList,
        id: "doc-list",
        studio_state: %State{mode: :editing, last_seen_revision: 0},
        current_scope: scope
      )

    assert html =~ ~s(id="doc-list-documents")

    for status <- [:draft, :importing, :editing, :reviewing, :export_ready] do
      assert html =~ "#{status} document"
    end
  end

  test "viewer scope hides create controls", %{user: user} do
    scope = %Context{Context.for_user(user) | perms: ~w(read)a}

    html =
      render_component(DocumentList,
        id: "doc-list",
        studio_state: %State{mode: :no_document, last_seen_revision: 0},
        current_scope: scope
      )

    refute html =~ ~s(data-role="new-document-btn")
    refute html =~ ~s(data-role="new-document-empty-cta")
    refute html =~ ~s(phx-value-modal="new_document")
  end

  defp stub_documents(documents) do
    Process.put({Contract.Repo, :stub_return}, documents)
  end

  defp document(%Context{user: user}, attrs) do
    %Document{
      id: Keyword.get(attrs, :id, Ecto.UUID.generate()),
      owner_id: user.id,
      title: Keyword.fetch!(attrs, :title),
      type_key: Keyword.get(attrs, :type_key, "nda_v1"),
      status: Keyword.get(attrs, :status, :draft),
      latest_revision: Keyword.get(attrs, :latest_revision, 0),
      updated_at: Keyword.get(attrs, :updated_at, ~N[2026-01-01 00:00:00])
    }
  end
end
