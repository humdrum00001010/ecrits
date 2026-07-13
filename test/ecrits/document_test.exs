defmodule Ecrits.DocumentTest do
  use ExUnit.Case, async: false

  alias Ecrits.Document
  alias Ecrits.Document.RhwpAdapter

  setup do
    ensure_local_runtime_started()

    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-local-document-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "opens a local hwpx fixture without metadata persistence", %{root: root} do
    source = File.read!("test/fixtures/hwpx/real_contract.hwpx")
    path = Path.join([root, "docs", "real_contract.hwpx"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)

    assert {:ok, %Document{} = document} = Document.open(root, "docs/real_contract.hwpx")
    assert document.format == "hwpx"
    assert document.byte_size == byte_size(source)
    assert document.sha256 == Document.sha256(source)
    assert document.id == Document.id_for(root, "docs/real_contract.hwpx")
    assert document.metadata_dir == nil
    assert Document.metadata_paths(document) == %{}
    assert is_pid(Document.whereis(document.id))
    assert {:ok, ^source} = Document.read(document)
    refute File.exists?(Path.join(root, ".ecrits"))

    assert :ok = Document.close(document)
  end

  test "detects supported formats by extension and magic" do
    hwp = synthetic_hwp_bytes()
    hwpx = hwpx_fixture()

    assert {:ok, "hwp"} = Document.detect_format("sample.hwp")
    assert {:ok, "hwpx"} = Document.detect_format("sample.hwpx")
    assert {:ok, "hwp"} = Document.detect_format("sample.hwp", hwp)
    assert {:ok, "hwpx"} = Document.detect_format("sample.hwpx", hwpx)
    assert {:ok, "hwp"} = Document.detect_format("sample.bin", hwp)
    assert {:ok, "hwpx"} = Document.detect_format("sample.bin", hwpx)
    assert {:error, :unsupported_format} = Document.detect_format("sample.hwp", "bytes")

    assert {:error, :unsupported_format} =
             Document.detect_format("sample.hwpx", <<"PK", 3, 4, 0>>)

    assert {:error, :unsupported_format} = Document.detect_format("sample.txt", "bytes")
  end

  test "detects Microsoft Office formats by extension" do
    assert {:ok, "doc"} = Document.detect_format("sample.doc", "bytes")
    assert {:ok, "docx"} = Document.detect_format("sample.docx", <<"PK", 3, 4, 0>>)
    assert {:ok, "xlsx"} = Document.detect_format("sample.xlsx", "bytes")
    assert {:ok, "pptx"} = Document.detect_format("sample.pptx", "bytes")
    assert {:ok, "rtf"} = Document.detect_format("sample.rtf", "bytes")
    assert Document.libreoffice_format?("docx")
    refute Document.libreoffice_format?("hwpx")
    assert Document.ehwp_format?("hwpx")
  end

  test "opens a local docx document without metadata persistence", %{root: root} do
    source = "docx fixture"
    path = Path.join(root, "contract.docx")
    File.write!(path, source)

    assert {:ok, %Document{} = document} = Document.open(root, "contract.docx")
    assert document.format == "docx"
    assert document.byte_size == byte_size(source)
    assert document.metadata_dir == nil
    assert Document.metadata_paths(document) == %{}
    refute File.exists?(Path.join(root, ".ecrits"))

    assert :ok = Document.close(document)
  end

  test "opens a local xlsx document without metadata persistence", %{root: root} do
    source = "xlsx fixture"
    path = Path.join(root, "ledger.xlsx")
    File.write!(path, source)

    assert {:ok, %Document{} = document} = Document.open(root, "ledger.xlsx")
    assert document.format == "xlsx"
    assert document.byte_size == byte_size(source)
    assert document.metadata_dir == nil
    assert Document.metadata_paths(document) == %{}
    refute File.exists?(Path.join(root, ".ecrits"))

    assert :ok = Document.close(document)
  end

  test "checkpoint writes local snapshot without replacing canonical file", %{root: root} do
    path = Path.join(root, "contract.hwp")
    original = synthetic_hwp_bytes()
    draft = synthetic_hwp_bytes()
    File.write!(path, original)

    assert {:ok, document} = Document.open(root, "contract.hwp")

    assert {:ok, checked_document, snapshot} =
             Document.checkpoint(document, draft, %{
               ir: %{"sections" => []},
               request_id: "req-1"
             })

    assert File.read!(path) == original
    assert {:ok, ^draft} = Document.read(checked_document)
    assert snapshot["path"] == nil
    refute snapshot["saved"]
    assert snapshot["request_id"] == "req-1"
    refute File.exists?(Path.join(root, ".ecrits"))

    assert :ok = Document.close(checked_document)
    assert {:ok, reopened} = Document.open(root, "contract.hwp")
    assert {:ok, ^original} = Document.read(reopened)
    assert :ok = Document.close(reopened)
  end

  test "save atomically replaces canonical file and reopens saved bytes", %{root: root} do
    path = Path.join(root, "contract.hwpx")
    original = hwpx_fixture()
    saved = hwpx_fixture()
    File.write!(path, original)

    assert {:ok, document} = Document.open(root, "contract.hwpx")
    assert {:ok, saved_document, snapshot} = Document.save(document, saved)

    assert snapshot["saved"]
    assert File.read!(path) == saved
    assert [] = Path.wildcard(path <> ".tmp-*")
    refute File.exists?(Path.join(root, ".ecrits"))

    assert :ok = Document.close(saved_document)
    assert {:ok, reopened} = Document.open(root, "contract.hwpx")
    assert {:ok, ^saved} = Document.read(reopened)
    assert :ok = Document.close(reopened)
  end

  test "rhwp adapter saves snapshot payload and emits PubSub event", %{root: root} do
    path = Path.join(root, "contract.hwpx")
    original = hwpx_fixture()
    saved = hwpx_fixture()
    File.write!(path, original)

    assert {:ok, %{document_id: document_id, bytes: ^original, format: "hwpx"}} =
             RhwpAdapter.open(root, "contract.hwpx")

    assert :ok = Document.subscribe(document_id)

    assert {:ok, response} =
             RhwpAdapter.save(document_id, %{
               "bytes_base64" => Base.encode64(saved),
               "format" => "hwpx",
               "ir" => %{"title" => "local"},
               "request_id" => "save-1"
             })

    assert response.ok
    assert response.local
    assert response.snapshot["saved"]
    assert File.read!(path) == saved

    assert_receive {:local_document_saved, %Document{id: ^document_id}, %{"saved" => true}}

    assert :ok = Document.close(document_id)
  end

  test "rhwp adapter saves snapshot payload from uploaded byte token", %{root: root} do
    path = Path.join(root, "contract.hwpx")
    original = hwpx_fixture()
    saved = hwpx_fixture()
    File.write!(path, original)

    assert {:ok, %{document_id: document_id, bytes: ^original, format: "hwpx"}} =
             RhwpAdapter.open(root, "contract.hwpx")

    assert {:ok, token, token_path} = Ecrits.Document.ByteSpool.reserve()
    File.write!(token_path, saved)

    assert {:ok, response} =
             RhwpAdapter.save(document_id, %{
               "bytes_token" => token,
               "format" => "hwpx",
               "request_id" => "save-token-1"
             })

    assert response.ok
    assert File.read!(path) == saved
    refute File.exists?(token_path)

    assert :ok = Document.close(document_id)
  end

  test "records local rhwp text mutation events without changing bytes", %{root: root} do
    source = hwpx_fixture()
    path = Path.join(root, "contract.hwpx")
    File.write!(path, source)

    assert {:ok, document} = Document.open(root, "contract.hwpx")

    envelope = %{
      "documentId" => document.id,
      "eventId" => "evt-1",
      "siteId" => "local",
      "lamport" => 7,
      "body" => %{
        "type" => "TextDeleted",
        "sectionIndex" => 0,
        "paragraphIndex" => 1,
        "charOffset" => 2,
        "count" => 1
      }
    }

    assert {:ok, mutation} = Document.record_mutation(document, envelope)
    assert mutation["event_id"] == "evt-1"
    assert mutation["site_id"] == "local"
    assert mutation["lamport"] == 7
    assert mutation["body"]["type"] == "TextDeleted"
    assert {:ok, ^source} = Document.read(document)
    refute File.exists?(Path.join(root, ".ecrits"))

    assert :ok = Document.close(document)
  end

  defp ensure_local_runtime_started do
    if is_nil(Process.whereis(Ecrits.PubSub)) do
      start_supervised!({Phoenix.PubSub, name: Ecrits.PubSub})
    end

    if is_nil(Process.whereis(Ecrits.Document.Registry)) do
      start_supervised!({Registry, keys: :unique, name: Ecrits.Document.Registry})
    end

    if is_nil(Process.whereis(Ecrits.Document.Supervisor)) do
      start_supervised!(Ecrits.Document.Supervisor)
    end
  end

  defp synthetic_hwp_bytes,
    do: <<0xD0, 0xCF, 0x11, 0xE0>> <> :binary.copy(<<0>>, 508)

  defp hwpx_fixture do
    File.read!("test/fixtures/hwpx/real_contract.hwpx")
  end
end
