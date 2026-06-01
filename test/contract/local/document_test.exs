defmodule Contract.Local.DocumentTest do
  use ExUnit.Case, async: false

  alias Contract.Local.Document
  alias Contract.Local.Document.RhwpAdapter

  setup do
    ensure_local_runtime_started()

    root =
      Path.join(
        System.tmp_dir!(),
        "contract-local-document-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "opens a local hwpx fixture and creates metadata", %{root: root} do
    source = File.read!("test/fixtures/hwpx/real_contract.hwpx")
    path = Path.join([root, "docs", "real_contract.hwpx"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)

    assert {:ok, %Document{} = document} = Document.open(root, "docs/real_contract.hwpx")
    assert document.format == "hwpx"
    assert document.revision == 0
    assert document.byte_size == byte_size(source)
    assert document.sha256 == Document.sha256(source)
    assert document.id == Document.id_for(root, "docs/real_contract.hwpx")
    assert is_pid(Document.whereis(document.id))
    assert {:ok, ^source} = Document.read(document)

    paths = Document.metadata_paths(document)
    assert File.exists?(paths.document)
    assert File.exists?(paths.index)
    assert File.exists?(paths.context)

    registry = decode_json!(paths.document)
    index = decode_json!(paths.index)
    assert registry["id"] == document.id
    assert registry["path"] == "docs/real_contract.hwpx"
    assert index["doc_id"] == document.id
    assert index["format"] == "hwpx"
    assert index["canonical"]["sha256"] == Document.sha256(source)

    assert :ok = Document.close(document)
  end

  test "detects supported formats by extension and magic" do
    hwp = hwp_fixture()
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

  test "checkpoint writes local snapshot without replacing canonical file", %{root: root} do
    path = Path.join(root, "contract.hwp")
    original = hwp_fixture()
    draft = hwp_fixture()
    File.write!(path, original)

    assert {:ok, document} = Document.open(root, "contract.hwp")

    assert {:ok, checked_document, snapshot} =
             Document.checkpoint(document, draft, %{
               ir: %{"sections" => []},
               request_id: "req-1"
             })

    assert checked_document.revision == 1
    assert File.read!(path) == original
    assert File.read!(Path.join(root, snapshot["path"])) == draft
    refute snapshot["saved"]
    assert snapshot["request_id"] == "req-1"

    paths = Document.metadata_paths(checked_document)
    index = decode_json!(paths.index)
    context = decode_json!(paths.context)

    assert index["latest_revision"] == 1
    assert index["saved_revision"] == 0
    assert [%{"revision" => 1, "saved" => false}] = index["snapshots"]
    assert context["context"] == %{"sections" => []}

    assert :ok = Document.close(checked_document)
    assert {:ok, reopened} = Document.open(root, "contract.hwp")
    assert reopened.revision == 0
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

    assert saved_document.revision == 1
    assert snapshot["saved"]
    assert File.read!(path) == saved
    assert [] = Path.wildcard(path <> ".tmp-*")

    paths = Document.metadata_paths(saved_document)
    index = decode_json!(paths.index)

    assert index["latest_revision"] == 1
    assert index["saved_revision"] == 1
    assert index["canonical"]["sha256"] == Document.sha256(saved)

    assert :ok = Document.close(saved_document)
    assert {:ok, reopened} = Document.open(root, "contract.hwpx")
    assert reopened.revision == 1
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
    assert response.revision == 1
    assert response.snapshot["saved"]
    assert File.read!(path) == saved

    assert_receive {:local_document_saved, %Document{id: ^document_id}, %{"revision" => 1}}

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

    records =
      document
      |> Document.metadata_paths()
      |> Map.fetch!(:mutations)
      |> read_jsonl!()

    assert [%{"event_id" => "evt-1", "body" => %{"type" => "TextDeleted"}}] = records

    assert :ok = Document.close(document)
  end

  defp ensure_local_runtime_started do
    if is_nil(Process.whereis(Contract.PubSub)) do
      start_supervised!({Phoenix.PubSub, name: Contract.PubSub})
    end

    if is_nil(Process.whereis(Contract.Local.Document.Registry)) do
      start_supervised!({Registry, keys: :unique, name: Contract.Local.Document.Registry})
    end

    if is_nil(Process.whereis(Contract.Local.Document.Supervisor)) do
      start_supervised!(Contract.Local.Document.Supervisor)
    end
  end

  defp decode_json!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp read_jsonl!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp hwp_fixture do
    File.read!("priv/static/assets/standard_contracts/service_agreement_v1.hwp")
  end

  defp hwpx_fixture do
    File.read!("test/fixtures/hwpx/real_contract.hwpx")
  end
end
