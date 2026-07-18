defmodule Ecrits.Workspace.SessionDocumentStateTest do
  use ExUnit.Case, async: false

  alias Ecrits.Workspace.Session
  alias Ecrits.Workspace.Session.Document

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "ecrits-session-document-state-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)

    {:ok, ws} =
      Session.attach(path,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "ok"}]
        ],
        workspace_root: path
      )

    on_exit(fn ->
      if pid = Session.whereis(path), do: GenServer.stop(pid, :normal, 1_000)
      File.rm_rf(path)
    end)

    {:ok, ws: ws}
  end

  test "stores opened documents, active document, and scroll by workspace-relative path", %{
    ws: ws
  } do
    assert %{
             documents: [],
             active_document_path: nil,
             document_element_picker_enabled?: false
           } = Session.document_snapshot(ws)

    assert {:ok,
            %Document{
              path: "drafts/reference.docx",
              id: "doc-id",
              pool_document_id: "pool-doc-id",
              scroll_top: 0,
              scroll_left: 0
            }} =
             Session.open_document(ws, %{
               path: "drafts/reference.docx",
               id: "doc-id",
               pool_document_id: "pool-doc-id"
             })

    assert :ok = Session.update_document_scroll(ws, "drafts/reference.docx", %{top: 321, left: 7})

    assert %{
             documents: [
               %Document{
                 path: "drafts/reference.docx",
                 id: "doc-id",
                 pool_document_id: "pool-doc-id",
                 scroll_top: 321,
                 scroll_left: 7
               }
             ],
             active_document_path: "drafts/reference.docx"
           } = Session.document_snapshot(ws)

    assert {:ok, %Document{path: "template.hwp"}} =
             Session.open_document(ws, path: "template.hwp", active?: false)

    assert %{
             documents: [
               %Document{path: "drafts/reference.docx"},
               %Document{path: "template.hwp"}
             ],
             active_document_path: "drafts/reference.docx"
           } = Session.document_snapshot(ws)

    assert :ok = Session.activate_document(ws, "template.hwp")

    assert %{active_document_path: "template.hwp"} = Session.document_snapshot(ws)

    assert :ok = Session.close_document(ws, "template.hwp")

    assert %{
             documents: [%Document{path: "drafts/reference.docx"}],
             active_document_path: "drafts/reference.docx"
           } = Session.document_snapshot(ws)
  end

  test "stores document element picker mode in the workspace session", %{ws: ws} do
    assert %{document_element_picker_enabled?: false} = Session.document_snapshot(ws)

    assert :ok = Session.set_document_element_picker_enabled(ws, true)
    assert %{document_element_picker_enabled?: true} = Session.document_snapshot(ws)

    assert :ok = Session.set_document_element_picker_enabled(ws, false)
    assert %{document_element_picker_enabled?: false} = Session.document_snapshot(ws)
  end

  test "rejects absolute and parent-relative document paths", %{ws: ws} do
    assert {:error, :invalid_path} = Session.open_document(ws, %{path: "/tmp/outside.docx"})
    assert {:error, :invalid_path} = Session.update_document_scroll(ws, "../outside.docx", top: 1)
  end

  test "canonicalizes the macOS /tmp alias the same way as the VFS mount" do
    assert Session.canonical_path("/tmp/ecrits-session-alias") ==
             Ecrits.Fuse.DocMount.canonical_root("/tmp/ecrits-session-alias")

    assert Session.canonical_path("/tmp/ecrits-session-alias") ==
             Session.canonical_path("/private/tmp/ecrits-session-alias")
  end
end
