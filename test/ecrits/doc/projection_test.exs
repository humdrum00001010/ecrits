defmodule Ecrits.Doc.ProjectionTest do
  @moduledoc """
  Unit tests for `Ecrits.Doc.Projection` — the exfuse doc-VFS JSONL projection.

  The pure surface (supported?/projected_name/source_basename/supported_exts) is
  toolchain-free. The end-to-end `project_file/2` + `fingerprint/1` tests run
  against the REAL doc layer through a private `Ecrits.Doc.Pool` and the ehwp NIF;
  they self-skip green when the NIF is unavailable, so the default suite stays
  free of native deps.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Editor
  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Projection
  alias Ecrits.Document
  alias Ecrits.Document.PreviewSnapshot
  alias Ecrits.Fuse.{DocFs, OpenDocs}
  alias Ecrits.Test.ExceptionalEditorBackend
  alias Ecrits.Workspace.TurnFinalizer

  @hwpx_fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)
  @png_1x1 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII="

  describe "supported?/1" do
    test "true for every supported extension, case-insensitive" do
      for ext <- ~w(.hwp .hwpx .docx .pptx .xlsx) do
        assert Projection.supported?("report" <> ext)
        assert Projection.supported?("REPORT" <> String.upcase(ext))
      end
    end

    test "false for unsupported extensions and non-binaries" do
      refute Projection.supported?("notes.txt")
      refute Projection.supported?("archive.zip")
      refute Projection.supported?("no_extension")
      refute Projection.supported?(nil)
      refute Projection.supported?(123)
    end

    test "matches the published supported_exts list" do
      assert Projection.supported_exts() == ~w(.hwp .hwpx .docx .pptx .xlsx)
    end
  end

  describe "projected_name/1 and source_basename/1 round-trip" do
    test "projected_name appends .jsonl" do
      assert Projection.projected_name("report.hwp") == "report.hwp.jsonl"
      assert Projection.projected_name("a/b/c.pptx") == "a/b/c.pptx.jsonl"
    end

    test "source_basename strips a trailing .jsonl" do
      assert Projection.source_basename("report.hwp.jsonl") == "report.hwp"
      assert Projection.source_basename("workbook.xlsx.jsonl") == "workbook.xlsx"
    end

    test "source_basename returns nil without a .jsonl suffix" do
      assert Projection.source_basename("notes.txt") == nil
      assert Projection.source_basename("report.hwp") == nil
      assert Projection.source_basename("report.hwp.md") == nil
      assert Projection.source_basename(nil) == nil
    end

    test "the two are inverse for supported names" do
      for ext <- Projection.supported_exts() do
        name = "doc" <> ext
        assert name |> Projection.projected_name() |> Projection.source_basename() == name
      end
    end
  end

  describe "project_file/2 error handling (no NIF required)" do
    test "unsupported extension is a clean error, never a raise" do
      assert {:error, {:unsupported, ".txt"}} =
               Projection.project_file("/tmp/whatever.txt")
    end

    test "non-binary path is rejected" do
      assert {:error, :invalid_path} = Projection.project_file(:not_a_path)
    end

    test "fingerprint propagates the same error" do
      assert {:error, {:unsupported, ".txt"}} = Projection.fingerprint("/tmp/whatever.txt")
      assert {:error, :invalid_path} = Projection.fingerprint(:not_a_path)
    end
  end

  describe "VFS edit highlight ranges" do
    test "browser playback follows document order instead of ehwp writeback order" do
      changes = [
        {:text,
         %{
           "op" => "insert_text",
           "ref" => %{"section" => 0, "paragraph" => 20, "offset" => 4},
           "text" => "뒤"
         }, "뒤"},
        {:text,
         %{
           "op" => "insert_text",
           "ref" => %{"section" => 0, "paragraph" => 11, "offset" => 2},
           "text" => "앞쪽"
         }, "앞쪽"}
      ]

      groups = Projection.__browser_preview_groups_for_test__(changes)

      assert Enum.map(groups, fn [{:text, op, _marker}] ->
               {op["ref"]["paragraph"], op["ref"]["offset"], op["text"]}
             end) == [
               {11, 2, "앞쪽"},
               {20, 4, "뒤"}
             ]
    end

    test "browser structural preview steps use the applied table control ref" do
      change =
        {:insert_table,
         %{
           "op" => "insert_table",
           "ref" => %{"section" => 0, "paragraph" => 8, "offset" => 0},
           "rows" => 1,
           "cols" => 2,
           "cells" => [["항목", "내용"]]
         }, "항목"}

      applied = %{"paraIdx" => 9, "controlIdx" => 2}

      assert [%{"highlights" => highlights}] =
               Projection.__browser_preview_steps_for_test__(
                 [[change]],
                 [change],
                 [applied]
               )

      assert Enum.map(highlights, & &1["ref"]["cell"]) == [
               %{
                 "parentParaIndex" => 9,
                 "controlIndex" => 2,
                 "cellIndex" => 0,
                 "cellParaIndex" => 0
               },
               %{
                 "parentParaIndex" => 9,
                 "controlIndex" => 2,
                 "cellIndex" => 1,
                 "cellParaIndex" => 0
               }
             ]
    end

    test "replacement preview keeps both raw ops and one final ranged highlight" do
      ref = %{"section" => 0, "paragraph" => 11, "offset" => 0}
      replacement = " ◇ 계약명  : 프리뷰 중복 추적"

      delete =
        {:text, %{"op" => "delete_range", "ref" => ref, "count" => 34}, replacement}

      insert =
        {:text, %{"op" => "insert_text", "ref" => ref, "text" => replacement}, replacement}

      changes = [delete, insert]
      assert [^changes] = Projection.__browser_preview_groups_for_test__(changes)

      assert [%{"ops" => ops, "highlights" => [highlight]}] =
               Projection.__browser_preview_steps_for_test__(
                 [changes],
                 changes,
                 [%{}, %{}]
               )

      assert Enum.map(ops, & &1["op"]) == ["delete_range", "insert_text"]

      assert highlight == %{
               "kind" => "text",
               "op" => "insert_text",
               "ref" => ref,
               "offset" => 0,
               "length" => String.length(replacement),
               "text" => replacement
             }
    end

    test "browser picture preview keeps placement coupled to its insertion" do
      change =
        {:insert_picture,
         %{
           "op" => "insert_picture",
           "ref" => %{"section" => 0, "paragraph" => 8, "offset" => 0},
           "src" => "/tmp/signature.png"
         }, "signature.png", %{"treatAsChar" => false, "horzOffset" => 120, "vertOffset" => 80}}

      assert [%{"ops" => [op], "sets" => []}] =
               Projection.__browser_preview_steps_for_test__(
                 [[change]],
                 [change],
                 [%{"paraIdx" => 8, "controlIdx" => 2}]
               )

      assert op["post_insert_props"] == %{
               "kind" => "picture",
               "treatAsChar" => false,
               "horzOffset" => 120,
               "vertOffset" => 80
             }
    end

    test "browser property sets translate IR paragraph kind to the editor vocabulary" do
      ref = %{"section" => 0, "paragraph" => 73}
      change = {:set, ref, "paragraph", %{"alignment" => "justify"}}

      assert [
               %{
                 "ref" => ^ref,
                 "props" => %{"kind" => "para", "alignment" => "justify"}
               }
             ] = Projection.__browser_sets_for_test__([change])
    end

    test "replace_text highlights only the changed replacement span" do
      title = "범용(용역[지식ㆍ정보성과물]업 분야) 표준하도급계약서 "
      marker = "CHATRAIL_FSKIT_HWP_OK"

      op = %{
        "op" => "replace_text",
        "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
        "query" => title,
        "replacement" => title <> marker
      }

      assert %{
               "kind" => "text",
               "op" => "replace_text",
               "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
               "offset" => offset,
               "length" => length,
               "text" => ^marker
             } = Projection.__text_highlight_for_test__(op, title <> marker)

      assert offset == String.length(title)
      assert length == String.length(marker)
    end

    # 2026-07-19 field feedback ("highlight only changes not a whole para"):
    # a whole-paragraph rewrite arrives as delete_range + insert_text whose
    # insert carries the ENTIRE new text; the collapsed pair highlight must
    # narrow to the range that differs from the deleted old text.
    test "a delete+insert replacement pair highlights only the changed span" do
      old = "◇ 화학업종 관련 제조위탁명  : ecrits"
      new = "◇ 화학업종 관련 제조위탁명 (test)  : ecrits"

      insert = %{
        "op" => "insert_text",
        "ref" => %{"section" => 0, "paragraph" => 11, "offset" => 0},
        "text" => new
      }

      assert %{
               "kind" => "text",
               "offset" => offset,
               "length" => length,
               "text" => changed
             } = Projection.__replacement_pair_highlight_for_test__(insert, new, old)

      assert changed =~ "(test)"
      refute changed =~ "화학업종"
      assert offset == String.length("◇ 화학업종 관련 제조위탁명 ")
      assert length == String.length(changed)
      assert length < String.length(new)
    end

    test "set_cell highlights the new cell text" do
      ref = %{
        "section" => 0,
        "paragraph" => 16,
        "offset" => 0,
        "cell" => %{
          "parentParaIndex" => 16,
          "controlIndex" => 0,
          "cellIndex" => 1,
          "cellParaIndex" => 0
        }
      }

      op = %{"op" => "set_cell", "ref" => ref, "text" => "성과물"}

      assert %{
               "kind" => "text",
               "op" => "set_cell",
               "ref" => ^ref,
               "offset" => 0,
               "length" => 3,
               "text" => "성과물"
             } = Projection.__text_highlight_for_test__(op, "성과물")
    end

    test "persisted highlights follow paragraphs shifted by structural inserts" do
      table_ref = %{"section" => 0, "paragraph" => 16}
      picture_ref = %{"section" => 0, "paragraph" => 75}

      changes = [
        {:insert_table, %{"op" => "insert_table", "ref" => table_ref}, "단계"},
        {:insert_picture, %{"op" => "insert_picture", "ref" => picture_ref}, "brand", %{}}
      ]

      cell_ref = %{
        "section" => 0,
        "paragraph" => 76,
        "cell" => %{"parentParaIndex" => 76, "controlIndex" => 0, "cellIndex" => 2}
      }

      highlights = [
        %{"op" => "insert_text", "ref" => %{"section" => 0, "paragraph" => 630}},
        %{"op" => "insert_text", "ref" => %{"section" => 0, "paragraph" => 74}},
        %{"op" => "set_cell", "ref" => cell_ref},
        %{"op" => "insert_picture", "ref" => picture_ref}
      ]

      assert [jurisdiction, date, signature, picture] =
               Projection.__remap_persisted_highlights_for_test__(highlights, changes)

      assert jurisdiction["ref"]["paragraph"] == 632
      assert date["ref"]["paragraph"] == 76
      assert signature["ref"]["paragraph"] == 78
      assert signature["ref"]["cell"]["parentParaIndex"] == 78
      assert picture["ref"] == picture_ref
    end

    test "persisted highlight remapping applies later insertion coordinates sequentially" do
      changes = [
        {:insert_picture,
         %{"op" => "insert_picture", "ref" => %{"section" => 0, "paragraph" => 859}}, "brand",
         %{}},
        {:insert_table, %{"op" => "insert_table", "ref" => %{"section" => 0, "paragraph" => 16}},
         "단계"}
      ]

      highlights = [
        %{
          "op" => "insert_text",
          "ref" => %{"section" => 0, "paragraph" => 858},
          "offset" => 0,
          "length" => 12,
          "text" => "2026년 7월 15일"
        }
      ]

      assert [%{"ref" => %{"paragraph" => 860}}] =
               Projection.__remap_persisted_highlights_for_test__(highlights, changes)
    end
  end

  describe "browser-authority write transaction" do
    @tag :edit_failure
    test "commit timeout restores the exact source and rolls the browser back without publishing" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_rollback_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      source_preimage = <<0, 1, 2, 3, 255, 254, 253, 10, 0>>
      browser_export = <<9, 8, 7, 6, 5, 4, 3, 2, 1>>
      mounted_name = Path.basename(path)
      edit_id = "browser-commit-timeout"

      File.mkdir_p!(root)
      File.write!(path, source_preimage)

      on_exit(fn ->
        OpenDocs.unstage(root, mounted_name)
        OpenDocs.uncache_committed(root, mounted_name)
        File.rm_rf(root)
      end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      owner = self()

      viewer =
        start_supervised!(
          {Task,
           fn ->
             browser_transaction_loop(
               owner,
               path,
               browser_export,
               :timeout
             )
           end}
        )

      changes = [
        {:text,
         %{
           "op" => "insert_text",
           "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
           "text" => "edited"
         }, "edited"}
      ]

      assert {:error, {:browser_timeout, "viewer did not reply in time"}} =
               Projection.__apply_browser_changes_for_test__(
                 viewer,
                 path,
                 :hwp,
                 changes,
                 root: root,
                 edit_id: edit_id,
                 browser_commit_timeout: 20
               )

      assert_receive {:browser_transaction, :vfs_write, ^edit_id, ^source_preimage}
      assert_receive {:browser_transaction, :vfs_commit, ^edit_id, ^browser_export}
      assert_receive {:browser_transaction, :vfs_rollback, ^edit_id, ^source_preimage}

      assert File.read!(path) == source_preimage
      assert :error = OpenDocs.staged(root, mounted_name)
      assert :error = OpenDocs.committed(root, mounted_name)
      refute_receive {:vfs_doc_edited, _info}
    end

    test "coordinator survives request-owner death after source replace and completes browser commit" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_owner_death_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      source_preimage = <<0, 1, 2, 3>>
      browser_export = <<9, 8, 7, 6>>
      edit_id = "browser-owner-death-gap"
      File.mkdir_p!(root)
      File.write!(path, source_preimage)

      on_exit(fn -> File.rm_rf(root) end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      owner = self()

      viewer =
        start_test_task(fn ->
          browser_transaction_loop(
            owner,
            path,
            browser_export,
            {:ok, %{"committed" => true}}
          )
        end)

      checkpoint = fn
        :source_written ->
          send(owner, {:browser_source_written, self()})

          receive do
            :continue_browser_commit -> :ok
          end
      end

      request_owner =
        start_test_task(fn ->
          result =
            Projection.__apply_browser_changes_for_test__(
              viewer,
              path,
              :hwp,
              browser_text_change("survives"),
              root: root,
              edit_id: edit_id,
              browser_transaction_checkpoint_fun: checkpoint
            )

          send(owner, {:request_owner_result, result})
        end)

      assert_receive {:browser_transaction, :vfs_write, ^edit_id, ^source_preimage}
      assert_receive {:browser_transaction_owner, :vfs_write, ^edit_id, write_owner}
      assert_receive {:browser_source_written, coordinator}
      assert coordinator != request_owner
      assert coordinator == write_owner
      assert {:ok, ^browser_export} = Ecrits.FS.raw_read(path)

      request_owner_ref = Process.monitor(request_owner)
      Process.exit(request_owner, :kill)

      assert_receive {:DOWN, ^request_owner_ref, :process, ^request_owner, :killed}
      refute_receive {:browser_transaction, :vfs_commit, ^edit_id, _bytes}
      refute_receive {:browser_transaction, :vfs_rollback, ^edit_id, _bytes}

      coordinator_ref = Process.monitor(coordinator)
      send(coordinator, :continue_browser_commit)

      assert_receive {:browser_transaction, :vfs_commit, ^edit_id, ^browser_export}
      assert_receive {:browser_transaction_owner, :vfs_commit, ^edit_id, ^coordinator}
      assert_receive {:vfs_doc_edited, %{edit_id: ^edit_id, browser_authority: true}}, 1_000
      assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :normal}

      assert {:ok, ^browser_export} = Ecrits.FS.raw_read(path)
      refute_receive {:browser_transaction, :vfs_rollback, ^edit_id, _bytes}
      refute_receive {:request_owner_result, _result}
    end

    @tag :edit_failure
    test "invalidated and aborted commit fences roll browser playback back before source commit" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_cancel_fence_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      source_preimage = <<0, 1, 2, 3>>
      browser_export = <<9, 8, 7, 6>>
      edit_id = "browser-cancel-fence"
      File.mkdir_p!(root)
      File.write!(path, source_preimage)
      on_exit(fn -> File.rm_rf(root) end)

      owner = self()

      viewer =
        start_test_task(fn ->
          browser_transaction_loop(owner, path, browser_export, {:ok, %{"committed" => true}})
        end)

      dead_session = spawn(fn -> :ok end)
      dead_ref = Process.monitor(dead_session)
      assert_receive {:DOWN, ^dead_ref, :process, ^dead_session, :normal}

      assert {:error, :turn_invalidated} =
               Projection.__apply_browser_changes_for_test__(
                 viewer,
                 path,
                 :hwp,
                 browser_text_change("cancelled"),
                 root: root,
                 edit_id: edit_id,
                 agent_session: dead_session,
                 agent_id: "agent-a",
                 instance_id: "instance-a",
                 turn_id: "turn-a"
               )

      assert_receive {:browser_transaction, :vfs_write, ^edit_id, ^source_preimage}
      assert_receive {:browser_transaction, :vfs_rollback, ^edit_id, ^source_preimage}
      refute_receive {:browser_transaction, :vfs_commit, ^edit_id, _bytes}
      assert File.read!(path) == source_preimage
      refute_receive {:vfs_doc_edited, %{edit_id: ^edit_id}}

      aborted_edit_id = "browser-aborted-fence"

      assert {:error, {:browser_writeback_failed, :hwp, :aborted}} =
               Projection.__apply_browser_changes_for_test__(
                 viewer,
                 path,
                 :hwp,
                 browser_text_change("aborted"),
                 root: root,
                 edit_id: aborted_edit_id,
                 turn_commit_fun: fn _identity, _commit -> :aborted end
               )

      assert_receive {:browser_transaction, :vfs_write, ^aborted_edit_id, ^source_preimage}
      assert_receive {:browser_transaction, :vfs_rollback, ^aborted_edit_id, ^source_preimage}
      refute_receive {:browser_transaction, :vfs_commit, ^aborted_edit_id, _bytes}
      assert File.read!(path) == source_preimage
    end

    test "OpenDocs agent session metadata reaches Projection commit options" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_owner_propagation_#{System.unique_integer([:positive])}"
        )

      name = "contract.hwp"
      path = Path.join(root, name)
      File.mkdir_p!(root)
      File.write!(path, <<0, 1, 2, 3>>)

      OpenDocs.open(root, name,
        source_path: path,
        agent_session: self(),
        agent_id: "agent-a",
        instance_id: "instance-a",
        turn_id: "turn-a"
      )

      on_exit(fn ->
        OpenDocs.close(root, name)
        File.rm_rf(root)
      end)

      opts = DocFs.__owner_identity_opts_for_test__(root, name, path)
      assert opts[:agent_session] == self()
      owner = self()
      viewer = start_test_task(fn -> browser_commit_loop(<<9, 8, 7, 6>>) end)

      turn_commit = fn identity, _commit ->
        send(owner, {:projection_commit_identity, identity})
        :aborted
      end

      assert {:error, {:browser_writeback_failed, :hwp, :aborted}} =
               Projection.__apply_browser_changes_for_test__(
                 viewer,
                 path,
                 :hwp,
                 browser_text_change("propagated"),
                 opts ++
                   [
                     root: root,
                     edit_id: "owner-propagation-edit",
                     turn_commit_fun: turn_commit
                   ]
               )

      assert_receive {:projection_commit_identity,
                      %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}}
    end

    test "routed document identity is preserved across write, commit, and rollback payloads" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_document_fence_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      File.mkdir_p!(root)
      File.write!(path, <<0, 1, 2, 3>>)
      on_exit(fn -> File.rm_rf(root) end)

      owner = self()
      expected_document_id = "routed-document-id"

      viewer =
        start_test_task(fn ->
          browser_payload_loop(owner, <<9, 8, 7, 6>>, {:error, "document switched"})
        end)

      turn_commit = fn _identity, commit ->
        result = commit.()
        send(owner, {:commit_lock_returned, Ecrits.FS.raw_read(path)})
        result
      end

      assert {:error, {:browser_writeback_rejected, "document switched"}} =
               Projection.__apply_browser_changes_for_test__(
                 viewer,
                 path,
                 :hwp,
                 browser_text_change("fenced"),
                 root: root,
                 edit_id: "document-fence-edit",
                 expected_document_id: expected_document_id,
                 agent_id: "agent-a",
                 instance_id: "instance-a",
                 turn_id: "turn-a",
                 turn_commit_fun: turn_commit
               )

      for verb <- [:vfs_write, :vfs_commit, :vfs_rollback] do
        assert_receive {:browser_payload, ^verb,
                        %{
                          edit_id: "document-fence-edit",
                          expected_document_id: ^expected_document_id,
                          agent_id: "agent-a",
                          instance_id: "instance-a",
                          turn_id: "turn-a"
                        }}
      end

      assert_receive {:commit_lock_returned, {:ok, <<0, 1, 2, 3>>}}
    end

    test "postcommit returns while file_server is suspended and publishes the carried export later" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_postcommit_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      source_preimage = <<0, 1, 2, 3>>
      browser_export = <<9, 8, 7, 6, 5, 4, 3, 2, 1>>
      edit_id = "browser-postcommit-with-file-server-suspended"

      File.mkdir_p!(root)
      File.write!(path, source_preimage)

      on_exit(fn -> File.rm_rf(root) end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      viewer = start_test_task(fn -> browser_commit_loop(browser_export) end)
      owner = self()
      file_server = Process.whereis(:file_server_2)
      :ok = :sys.suspend(file_server)
      on_exit(fn -> :sys.resume(file_server) end)

      _worker =
        start_test_task(fn ->
          result =
            Projection.__apply_browser_changes_for_test__(
              viewer,
              path,
              :hwp,
              browser_text_change("edited"),
              root: root,
              edit_id: edit_id
            )

          send(owner, {:postcommit_result, result})
        end)

      assert_receive {:postcommit_result, {:ok, %{applied: 1}}}, 1_000
      refute_receive {:vfs_doc_edited, %{edit_id: ^edit_id}}, 20

      :ok = :sys.resume(file_server)

      assert_receive {:vfs_doc_edited,
                      %{
                        edit_id: ^edit_id,
                        preview_snapshot: %{sha256: snapshot_sha256}
                      }},
                     1_000

      assert snapshot_sha256 == Document.sha256(browser_export)
      assert File.read!(path) == browser_export
    end

    test "a blocked older snapshot cannot publish after a newer edit" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_preview_order_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      File.mkdir_p!(root)
      File.write!(path, <<0>>)
      on_exit(fn -> File.rm_rf(root) end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      owner = self()
      old_bytes = <<1, 1, 1>>
      new_bytes = <<2, 2, 2>>
      old_viewer = start_test_task(fn -> browser_commit_loop(old_bytes) end)
      new_viewer = start_test_task(fn -> browser_commit_loop(new_bytes) end)

      blocking_snapshot = fn document_id, bytes ->
        send(owner, {:old_snapshot_started, self(), document_id, bytes})

        receive do
          :release_old_snapshot ->
            id = Document.sha256(bytes)
            {:ok, %{id: id, document_id: document_id, byte_size: byte_size(bytes), sha256: id}}
        end
      end

      assert {:ok, %{applied: 1}} =
               Projection.__apply_browser_changes_for_test__(
                 old_viewer,
                 path,
                 :hwp,
                 browser_text_change("old"),
                 root: root,
                 edit_id: "older-edit",
                 preview_snapshot_fun: blocking_snapshot
               )

      assert_receive {:old_snapshot_started, old_task, _document_id, ^old_bytes}

      :ok =
        Projection.__broadcast_edit_for_test__(
          path,
          browser_text_change("new"),
          [%{}],
          root: root,
          edit_id: "newer-edit",
          preview_only: true,
          progress_index: 0,
          progress_total: 1
        )

      assert_receive {:vfs_doc_edited, %{edit_id: "newer-edit", preview_only: true}}
      send(old_task, :release_old_snapshot)
      refute_receive {:vfs_doc_edited, %{edit_id: "older-edit"}}, 100

      immediate_snapshot = fn document_id, bytes ->
        id = Document.sha256(bytes)
        {:ok, %{id: id, document_id: document_id, byte_size: byte_size(bytes), sha256: id}}
      end

      assert {:ok, %{applied: 1}} =
               Projection.__apply_browser_changes_for_test__(
                 new_viewer,
                 path,
                 :hwp,
                 browser_text_change("new"),
                 root: root,
                 edit_id: "newer-edit",
                 preview_snapshot_fun: immediate_snapshot
               )

      assert_receive {:vfs_doc_edited,
                      %{edit_id: "newer-edit", preview_snapshot: %{sha256: new_sha}}},
                     1_000

      assert new_sha == Document.sha256(new_bytes)
    end

    test "snapshot persistence failure still publishes the terminal edit event" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_preview_error_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      File.mkdir_p!(root)
      File.write!(path, <<0>>)
      on_exit(fn -> File.rm_rf(root) end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      viewer = start_supervised!({Task, fn -> browser_commit_loop(<<3, 3, 3>>) end})

      assert {:ok, %{applied: 1}} =
               Projection.__apply_browser_changes_for_test__(
                 viewer,
                 path,
                 :hwp,
                 browser_text_change("error"),
                 root: root,
                 edit_id: "snapshot-error-edit",
                 preview_snapshot_fun: fn _document_id, _bytes -> {:error, :disk_full} end
               )

      assert_receive {:vfs_doc_edited,
                      %{
                        edit_id: "snapshot-error-edit",
                        preview_snapshot_error: "disk_full"
                      }},
                     1_000
    end

    test "deferred server preview snapshots use captured post-save bytes, not a later reread" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_server_snapshot_capture_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      captured_bytes = <<1, 2, 3, 4>>
      later_bytes = <<9, 9, 9, 9>>
      File.mkdir_p!(root)
      File.write!(path, captured_bytes)
      on_exit(fn -> File.rm_rf(root) end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      owner = self()

      blocking_snapshot = fn document_id, bytes ->
        send(owner, {:server_snapshot_started, self(), document_id, bytes})

        receive do
          :release_server_snapshot ->
            id = Document.sha256(bytes)
            {:ok, %{id: id, document_id: document_id, byte_size: byte_size(bytes), sha256: id}}
        end
      end

      :ok =
        Projection.__broadcast_edit_for_test__(
          path,
          browser_text_change("server"),
          [%{}],
          root: root,
          edit_id: "server-captured-snapshot",
          preview_snapshot_bytes_result: {:ok, captured_bytes},
          preview_snapshot_fun: blocking_snapshot
        )

      assert_receive {:server_snapshot_started, snapshot_task, _document_id, ^captured_bytes}
      File.write!(path, later_bytes)
      send(snapshot_task, :release_server_snapshot)

      assert_receive {:vfs_doc_edited,
                      %{
                        edit_id: "server-captured-snapshot",
                        preview_snapshot: %{sha256: snapshot_sha}
                      }},
                     1_000

      assert snapshot_sha == Document.sha256(captured_bytes)
      assert File.read!(path) == later_bytes
    end

    test "a final preview publication token is consumed exactly once" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_preview_once_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      token = OpenDocs.begin_preview_publication(root, path, "once-edit")
      info = %{path: path, edit_id: "once-edit"}

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      assert :ok = OpenDocs.publish_preview_if_current(root, path, token, info)
      assert :stale = OpenDocs.publish_preview_if_current(root, path, token, info)
      assert_receive {:vfs_doc_edited, ^info}
      refute_receive {:vfs_doc_edited, ^info}, 50
    end
  end

  describe "server-authority turn commit fence" do
    test "Projection passes the full identity and the Editor process owns the fence" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "projection-server-turn-fence-#{System.unique_integer([:positive])}"
        )

      path = Path.join(dir, "contract.hwp")
      initial = "SOURCE_PREIMAGE"
      File.mkdir_p!(dir)
      File.write!(path, initial)
      on_exit(fn -> File.rm_rf(dir) end)

      editor =
        start_supervised!(
          Supervisor.child_spec(
            {Editor,
             document_id: "server_fence_#{System.unique_integer([:positive])}",
             kind: :hwp,
             backend: ExceptionalEditorBackend,
             path: path,
             open_opts: []},
            id: make_ref()
          )
        )

      owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}
      test_pid = self()

      turn_commit = fn identity, _commit ->
        send(test_pid, {:server_projection_fence, self(), identity})
        :aborted
      end

      assert {:error, {:turn_commit_failed, :aborted}} =
               Projection.__apply_server_changes_for_test__(
                 editor,
                 path,
                 :hwp,
                 browser_text_change("MUST_NOT_COMMIT"),
                 agent_id: owner.agent_id,
                 instance_id: owner.instance_id,
                 turn_id: owner.turn_id,
                 turn_commit_fun: turn_commit
               )

      assert_receive {:server_projection_fence, ^editor, ^owner}
      assert File.read!(path) == initial
      assert {:ok, %{text: ^initial}} = Editor.read(editor, [])
      assert Editor.dirty_snapshot(editor) == %{dirty?: false, revision: 0, owner: nil}
      assert Editor.history(editor) == []
    end

    test "the committed preview survives death of the Projection request owner" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "projection-server-preview-owner-death-#{System.unique_integer([:positive])}"
        )

      path = Path.join(dir, "contract.hwp")
      initial = "SOURCE_PREIMAGE"
      marker = "COMMITTED_PREVIEW_AFTER_CALLER_DEATH"
      edit_id = "server-preview-owner-death"
      File.mkdir_p!(dir)
      File.write!(path, initial)
      on_exit(fn -> File.rm_rf(dir) end)

      editor =
        start_supervised!(
          Supervisor.child_spec(
            {Editor,
             document_id: "server_preview_#{System.unique_integer([:positive])}",
             kind: :hwp,
             backend: ExceptionalEditorBackend,
             path: path,
             open_opts: []},
            id: make_ref()
          )
        )

      owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}
      test_pid = self()

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(dir)
      )

      turn_commit = fn identity, commit ->
        send(test_pid, {:server_preview_fence_acquired, self(), identity})

        receive do
          :release_server_preview_commit -> commit.()
        end
      end

      caller =
        start_test_task(fn ->
          result =
            Projection.__apply_server_changes_for_test__(
              editor,
              path,
              :hwp,
              browser_text_change(marker),
              root: dir,
              edit_id: edit_id,
              agent_id: owner.agent_id,
              instance_id: owner.instance_id,
              turn_id: owner.turn_id,
              turn_commit_fun: turn_commit
            )

          send(test_pid, {:unexpected_server_preview_caller_result, result})
        end)

      assert_receive {:server_preview_fence_acquired, ^editor, ^owner}, 2_000

      caller_ref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 2_000

      send(editor, :release_server_preview_commit)
      _ = :sys.get_state(editor)

      expected = initial <> marker
      assert File.read!(path) == expected

      assert_receive {:vfs_doc_edited,
                      %{
                        edit_id: ^edit_id,
                        marker: ^marker,
                        preview_snapshot: %{sha256: snapshot_sha256}
                      }},
                     2_000

      assert snapshot_sha256 == Document.sha256(expected)
      refute_receive {:vfs_doc_edited, %{edit_id: ^edit_id}}, 100
      refute_receive {:unexpected_server_preview_caller_result, _result}
    end
  end

  describe "write_back/3 over HWPX JSONL IR" do
    setup do
      {:ok, ehwp: ehwp_available?(@hwpx_fixture)}
    end

    test "routes edited text nodes back into the live document model", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping Projection write_back HWPX text e2e")
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_writeback_text", ".hwpx")
        on_exit(fn -> cleanup_tmp(path) end)

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        {node_path, node} = first_text_paragraph(doc)
        new_text = "JSONL_WRITEBACK_TEXT_OK"

        new_bytes =
          doc
          |> replace_payload_node(node_path, Map.put(node, "text", new_text))
          |> encode_projection()

        assert {:ok, %{applied: 2, doc: doc}} = Projection.write_back(path, new_bytes)
        assert doc == Path.basename(path)

        assert {:ok, after_bytes} = Projection.project_file(path)
        assert after_bytes =~ new_text
      end
    end

    test "streams multi-node write-back as ordered semantic edit ranges", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping Projection streaming write_back e2e")
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_writeback_stream", ".hwpx")
        root = Path.dirname(path)
        on_exit(fn -> cleanup_tmp(path) end)

        Phoenix.PubSub.subscribe(
          Ecrits.PubSub,
          "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
        )

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        {first_path, first_node} = first_text_paragraph(doc)
        {_section, first_paragraph, _payload} = first_path
        {second_path, second_node} = text_paragraph_after(doc, first_paragraph + 1)

        new_bytes =
          doc
          |> replace_payload_node(
            first_path,
            Map.put(first_node, "text", "STREAMED_WRITEBACK_TOKEN_ONE")
          )
          |> replace_payload_node(
            second_path,
            Map.put(second_node, "text", "STREAMED_WRITEBACK_TOKEN_TWO")
          )
          |> encode_projection()

        assert {:ok, %{applied: applied_total}} =
                 Projection.write_back(path, new_bytes, root: root)

        assert_receive {:vfs_doc_edited, first}

        expected_total = 2

        assert first.progress_total == expected_total

        events =
          Enum.reduce(2..expected_total, [first], fn _index, acc ->
            assert_receive {:vfs_doc_edited, event}
            [event | acc]
          end)
          |> Enum.reverse()

        assert events |> Enum.map(& &1.edit_id) |> Enum.uniq() == [first.edit_id]
        assert Enum.map(events, & &1.progress_index) == Enum.to_list(1..expected_total)
        assert Enum.all?(events, &(&1.progress_total == expected_total))
        assert List.last(events).applied == applied_total

        assert Enum.all?(Enum.drop(events, -1), &is_nil(Map.get(&1, :preview_snapshot)))

        assert %{
                 id: snapshot_id,
                 document_id: snapshot_document_id,
                 sha256: snapshot_sha256
               } = List.last(events).preview_snapshot

        expected_document_id = Document.id_for(root, Path.basename(path))
        assert snapshot_document_id == expected_document_id
        assert snapshot_id == snapshot_sha256
        assert snapshot_sha256 == Document.sha256(File.read!(path))
        assert {:ok, snapshot_bytes} = PreviewSnapshot.fetch(expected_document_id, snapshot_id)
        assert snapshot_bytes == File.read!(path)

        on_exit(fn ->
          snapshot_path = PreviewSnapshot.path(expected_document_id, snapshot_id)
          File.rm_rf(Path.dirname(snapshot_path))
        end)

        markers = MapSet.new(events, & &1.marker)
        assert MapSet.member?(markers, "STREAMED_WRITEBACK_TOKEN_ONE")
        assert MapSet.member?(markers, "STREAMED_WRITEBACK_TOKEN_TWO")

        refute_receive {:vfs_doc_edited, _info}
      end
    end

    test "rejects an already-streamed multi-group preview when final save fails", %{
      ehwp: ehwp
    } do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping Projection save rejection e2e")
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_writeback_save_rejection", ".hwpx")
        root = Path.dirname(path)
        owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}

        on_exit(fn ->
          _ = File.chmod(root, 0o700)
          _ = File.chmod(path, 0o600)
          cleanup_tmp(path)
        end)

        Phoenix.PubSub.subscribe(
          Ecrits.PubSub,
          "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
        )

        source_preimage = File.read!(path)
        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        {first_path, first_node} = first_text_paragraph(doc)
        {_section, first_paragraph, _payload} = first_path
        {second_path, second_node} = text_paragraph_after(doc, first_paragraph + 1)

        new_bytes =
          doc
          |> replace_payload_node(
            first_path,
            Map.put(first_node, "text", "SAVE_REJECTION_TOKEN_ONE")
          )
          |> replace_payload_node(
            second_path,
            Map.put(second_node, "text", "SAVE_REJECTION_TOKEN_TWO")
          )
          |> encode_projection()

        {:ok, %{id: document_id}} = Pool.info_by_path(path)
        assert {:server, editor} = Pool.route(document_id)
        editor_preimage = Editor.dirty_snapshot(editor)
        history_preimage = Editor.history(editor)
        edit_id = "save-rejection-#{System.unique_integer([:positive])}"

        identity_opts = [
          root: root,
          edit_id: edit_id,
          agent_id: owner.agent_id,
          instance_id: owner.instance_id,
          turn_id: owner.turn_id
        ]

        assert {:ok, %{previewed: previewed}} =
                 Projection.preview_write_back(path, new_bytes, identity_opts)

        assert previewed > 0

        assert_receive {:vfs_doc_edited,
                        %{
                          progress_index: 0,
                          edit_id: ^edit_id,
                          preview_only: true
                        } = preview}

        assert Map.take(preview, [:agent_id, :instance_id, :turn_id]) == owner

        File.chmod!(path, 0o400)
        File.chmod!(root, 0o500)

        assert {:error, _reason} =
                 Projection.write_back(
                   path,
                   new_bytes,
                   identity_opts ++ [preview_continuation: true]
                 )

        refute_receive {:vfs_doc_edit_rejected, _rejected}
        refute_receive {:vfs_doc_edited, %{progress_index: 1}}
        refute_receive {:vfs_doc_edited, %{progress_index: 2}}

        assert File.read!(path) == source_preimage
        assert {:ok, ^bytes} = Projection.project_file(path)
        assert Editor.dirty_snapshot(editor) == editor_preimage
        assert Editor.history(editor) == history_preimage

        File.chmod!(root, 0o700)
        File.chmod!(path, 0o600)

        finalizer =
          TurnFinalizer.run(root,
            agent_id: owner.agent_id,
            instance_id: owner.instance_id,
            turn_id: owner.turn_id
          )

        assert finalizer.saved == []
        assert finalizer.failed == []
        assert File.read!(path) == source_preimage
        assert {:ok, ^bytes} = Projection.project_file(path)
        assert Editor.dirty_snapshot(editor) == editor_preimage
        assert Editor.history(editor) == history_preimage
      end
    end

    test "rolls back an earlier group when the next group fails to apply", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping Projection apply rollback e2e")
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_writeback_apply_rollback", ".hwpx")
        root = Path.dirname(path)
        owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}

        on_exit(fn ->
          cleanup_tmp(path)
        end)

        Phoenix.PubSub.subscribe(
          Ecrits.PubSub,
          "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
        )

        source_preimage = File.read!(path)
        {:ok, projection_preimage} = Projection.project_file(path)
        {_lines, doc} = decode_projection(projection_preimage)
        {first_path, first_node} = first_text_paragraph(doc)
        {_section, first_paragraph, _payload} = first_path
        {second_path, second_node} = text_paragraph_after(doc, first_paragraph + 1)

        new_bytes =
          doc
          |> replace_payload_node(
            first_path,
            Map.put(first_node, "text", "APPLY_ROLLBACK_TOKEN_ONE")
          )
          |> replace_payload_node(
            second_path,
            Map.put(second_node, "text", "APPLY_ROLLBACK_TOKEN_TWO")
          )
          |> encode_projection()

        {:ok, %{id: document_id}} = Pool.info_by_path(path)
        assert {:server, editor} = Pool.route(document_id)
        editor_preimage = Editor.dirty_snapshot(editor)
        history_preimage = Editor.history(editor)
        edit_id = "apply-rollback-#{System.unique_integer([:positive])}"

        identity_opts = [
          root: root,
          edit_id: edit_id,
          agent_id: owner.agent_id,
          instance_id: owner.instance_id,
          turn_id: owner.turn_id
        ]

        assert {:ok, %{previewed: previewed}} =
                 Projection.preview_write_back(path, new_bytes, identity_opts)

        assert previewed > 0

        assert_receive {:vfs_doc_edited,
                        %{
                          edit_id: ^edit_id,
                          preview_only: true,
                          preview_steps: [first_step, _second_step]
                        }}

        first_group_command_count =
          length(Map.fetch!(first_step, "ops")) + length(Map.fetch!(first_step, "sets"))

        assert first_group_command_count > 0
        assert %{handle: %{ehwp: %Ehwp.Handle{id: ehwp_handle_id}}} = :sys.get_state(editor)
        assert [{ehwp_session, _value}] = Registry.lookup(Ehwp.Registry, ehwp_handle_id)

        :ok =
          Ecrits.Test.FailingAfterEditEhwpRuntime.reset(first_group_command_count + 1)

        :sys.replace_state(ehwp_session, fn state ->
          %{state | runtime: Ecrits.Test.FailingAfterEditEhwpRuntime}
        end)

        on_exit(fn ->
          if Process.alive?(ehwp_session) do
            :sys.replace_state(ehwp_session, &%{&1 | runtime: Ehwp.Runtime})
          end
        end)

        assert {:error, _reason} =
                 Projection.write_back(
                   path,
                   new_bytes,
                   identity_opts ++ [preview_continuation: true]
                 )

        refute_receive {:vfs_doc_edit_rejected, _rejected}
        refute_receive {:vfs_doc_edited, %{progress_index: 1}}
        refute_receive {:vfs_doc_edited, %{progress_index: 2}}

        assert File.read!(path) == source_preimage
        assert {:ok, ^projection_preimage} = Projection.project_file(path)
        assert Editor.dirty_snapshot(editor) == editor_preimage
        assert Editor.history(editor) == history_preimage

        finalizer =
          TurnFinalizer.run(root,
            agent_id: owner.agent_id,
            instance_id: owner.instance_id,
            turn_id: owner.turn_id
          )

        assert finalizer.saved == []
        assert finalizer.failed == []
        assert File.read!(path) == source_preimage
        assert {:ok, ^projection_preimage} = Projection.project_file(path)
        assert Editor.dirty_snapshot(editor) == editor_preimage
        assert Editor.history(editor) == history_preimage
      end
    end

    test "accepts pretty-printed nested JSON from mounted file rewrites", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping Projection pretty JSON write_back e2e")
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_writeback_pretty_json", ".hwpx")
        on_exit(fn -> cleanup_tmp(path) end)

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        {node_path, node} = first_text_paragraph(doc)
        new_text = "JSONL_WRITEBACK_PRETTY_OK"

        pretty_bytes =
          doc
          |> replace_payload_node(node_path, Map.put(node, "text", new_text))
          |> Jason.encode!(pretty: true)

        assert {:ok, %{applied: 2}} = Projection.write_back(path, pretty_bytes)

        assert {:ok, after_bytes} = Projection.project_file(path)
        assert after_bytes =~ new_text
      end
    end

    test "omits positional HWPX refs from payload JSON", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping Projection HWPX ref elision e2e")
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_refless_positions", ".hwpx")
        on_exit(fn -> cleanup_tmp(path) end)

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)

        {_path, paragraph} = first_text_paragraph(doc)
        refute Map.has_key?(paragraph, "ref")

        section_def = first_payload_node(doc, &(&1["type"] == "section_def"))
        refute Map.has_key?(section_def, "ref")

        {_path, cell_paragraph} = first_text_cell_paragraph(doc)
        refute Map.has_key?(cell_paragraph, "ref")

        refute Enum.any?(payload_nodes(doc), &match?(%{"ref" => ref} when is_list(ref), &1))
      end
    end

    test "routes non-text IR fields through the native property setter", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping Projection write_back HWPX props e2e")
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_writeback_props", ".hwpx")
        on_exit(fn -> cleanup_tmp(path) end)

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        {node_path, node} = first_text_paragraph(doc)

        new_bytes =
          doc
          |> replace_payload_node(node_path, Map.put(node, "Alignment", "Center"))
          |> encode_projection()

        assert {:ok, %{applied: 1}} = Projection.write_back(path, new_bytes)
        assert paragraph_context(path, node_path)["alignment"] == "center"
      end
    end

    test "routes native HWPX cell payload edits through write-back", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping Projection write_back HWPX cell e2e")
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_writeback_cell", ".hwpx")
        on_exit(fn -> cleanup_tmp(path) end)

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        {node_path, node} = first_text_cell_paragraph(doc)
        new_text = "JSONL_WRITEBACK_CELL_OK"

        new_bytes =
          doc
          |> replace_payload_node(node_path, Map.put(node, "text", new_text))
          |> encode_projection()

        assert {:ok, %{applied: 1}} = Projection.write_back(path, new_bytes)
        assert {:ok, after_bytes} = Projection.project_file(path)
        assert after_bytes =~ new_text
      end
    end

    test "routes inserted table payloads to native HWPX table creation", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts(
          "\n[skip] ehwp NIF unavailable; skipping Projection write_back HWPX table insert e2e"
        )
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_insert_table", ".hwpx")
        on_exit(fn -> cleanup_tmp(path) end)

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        {anchor_path, _node} = first_text_paragraph(doc)

        table =
          %{
            "type" => "table",
            "cells" => [
              ["JSONL_NEW_TABLE_H1", "JSONL_NEW_TABLE_H2"],
              ["JSONL_NEW_TABLE_A", "JSONL_NEW_TABLE_B"]
            ],
            "header" => true
          }

        new_bytes =
          doc
          |> insert_payload_node(insert_after(anchor_path), table)
          |> encode_projection()
          |> String.replace(":0.0", ":0")

        assert {:ok, %{applied: 1}} = Projection.write_back(path, new_bytes)
        assert {:ok, after_bytes} = Projection.project_file(path)

        for marker <- List.flatten(table["cells"]) do
          assert after_bytes =~ marker
        end

        {_lines, after_doc} = decode_projection(after_bytes)

        inserted_cells =
          after_doc
          |> payload_nodes()
          |> Enum.filter(
            &(&1["type"] == "paragraph" and &1["text"] in List.flatten(table["cells"]))
          )
          |> Enum.map(& &1["text"])

        assert inserted_cells == List.flatten(table["cells"])

        # The accepted compact transport is no longer a valid semantic diff
        # against the engine-expanded table. Replaying it directly must fail
        # without duplicating anything; DocFs handles this exact-byte replay as
        # a transport no-op before it reaches Projection again.
        assert {:error, {:structural_change, detail}} = Projection.write_back(path, new_bytes)
        assert is_binary(detail) and detail != ""
        assert {:ok, ^after_bytes} = Projection.project_file(path)
      end
    end

    test "agent JSONL picture insertion is rejected before preview or mutation", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping agent JSONL picture boundary e2e")
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_agent_picture_boundary", ".hwpx")
        root = Path.dirname(path)
        edit_id = "agent-picture-boundary-#{System.unique_integer([:positive])}"

        on_exit(fn -> cleanup_tmp(path) end)

        Phoenix.PubSub.subscribe(
          Ecrits.PubSub,
          "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
        )

        source_preimage = File.read!(path)
        {:ok, projection_preimage} = Projection.project_file(path)
        {_lines, doc} = decode_projection(projection_preimage)
        {anchor_path, _node} = first_text_paragraph(doc)

        picture = %{
          "type" => "picture",
          "src" => image_fixture(),
          "description" => "AGENT_JSONL_PICTURE_MUST_NOT_APPEAR"
        }

        edited_bytes =
          doc
          |> insert_payload_node(insert_after(anchor_path), picture)
          |> encode_projection()

        opts = [
          root: root,
          edit_id: edit_id,
          agent_id: "agent-a",
          instance_id: "instance-a",
          turn_id: "turn-a"
        ]

        {:ok, %{id: document_id}} = Pool.info_by_path(path)
        assert {:server, editor} = Pool.route(document_id)
        editor_preimage = Editor.dirty_snapshot(editor)
        history_preimage = Editor.history(editor)

        expected_error =
          {:error,
           {:agent_picture_insertion_requires_doc_edit,
            "insert_picture changes from agent JSONL edits are not allowed; use doc.edit for image insertion"}}

        assert ^expected_error = Projection.preview_write_back(path, edited_bytes, opts)
        refute_receive {:vfs_doc_edited, %{edit_id: ^edit_id}}

        assert ^expected_error = Projection.write_back(path, edited_bytes, opts)
        refute_receive {:vfs_doc_edited, %{edit_id: ^edit_id}}

        assert File.read!(path) == source_preimage
        assert {:ok, ^projection_preimage} = Projection.project_file(path)
        assert Editor.dirty_snapshot(editor) == editor_preimage
        assert Editor.history(editor) == history_preimage
      end
    end

    test "agent JSONL text and table changes remain allowed", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping agent JSONL text and table e2e")
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_agent_text_table", ".hwpx")
        root = Path.dirname(path)
        edit_id = "agent-text-table-#{System.unique_integer([:positive])}"

        on_exit(fn -> cleanup_tmp(path) end)

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        {anchor_path, anchor} = first_text_paragraph(doc)
        text_marker = "AGENT_JSONL_TEXT_ALLOWED"

        table = %{
          "type" => "table",
          "cells" => [
            ["AGENT_JSONL_TABLE_H1", "AGENT_JSONL_TABLE_H2"],
            ["AGENT_JSONL_TABLE_A", "AGENT_JSONL_TABLE_B"]
          ]
        }

        edited_bytes =
          doc
          |> replace_payload_node(anchor_path, Map.put(anchor, "text", text_marker))
          |> insert_payload_node(insert_after(anchor_path), table)
          |> encode_projection()

        opts = [
          root: root,
          edit_id: edit_id,
          agent_id: "agent-a",
          instance_id: "instance-a",
          turn_id: "turn-a"
        ]

        assert {:ok, %{previewed: previewed}} =
                 Projection.preview_write_back(path, edited_bytes, opts)

        assert previewed > 0
        assert {:ok, %{applied: applied}} = Projection.write_back(path, edited_bytes, opts)
        assert applied > 0

        assert {:ok, after_bytes} = Projection.project_file(path)
        assert after_bytes =~ text_marker

        for marker <- List.flatten(table["cells"]) do
          assert after_bytes =~ marker
        end
      end
    end

    test "routes picture inserts near structural payloads through a safe native anchor", %{
      ehwp: ehwp
    } do
      if not ehwp do
        IO.puts(
          "\n[skip] ehwp NIF unavailable; skipping Projection write_back HWPX structural picture insert e2e"
        )
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_picture_structural_anchor", ".hwpx")
        on_exit(fn -> cleanup_tmp(path) end)

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        original_count = picture_count(doc)
        {anchor_path, _node} = first_text_paragraph(doc)

        picture = %{
          "type" => "picture",
          "src" => image_fixture(),
          "width" => 3200,
          "height" => 2400,
          "description" => "JSONL_STRUCTURAL_ANCHOR_PICTURE"
        }

        new_bytes =
          doc
          |> insert_payload_node(insert_after(anchor_path), picture)
          |> encode_projection()

        assert {:ok, %{applied: 1}} = Projection.write_back(path, new_bytes)
        assert {:ok, after_bytes} = Projection.project_file(path)
        {_lines, after_doc} = decode_projection(after_bytes)
        assert picture_count(after_doc) == original_count + 1
        assert after_bytes =~ "JSONL_STRUCTURAL_ANCHOR_PICTURE"
      end
    end

    test "routes picture inserts after a table cell through a cell native anchor", %{
      ehwp: ehwp
    } do
      if not ehwp do
        IO.puts(
          "\n[skip] ehwp NIF unavailable; skipping Projection write_back HWPX cell picture insert e2e"
        )
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_picture_cell_anchor", ".hwpx")
        on_exit(fn -> cleanup_tmp(path) end)

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        original_count = picture_count(doc)
        {cell_path, _cell} = first_cell(doc)

        picture = %{
          "type" => "picture",
          "src" => image_fixture(),
          "width" => 3200,
          "height" => 2400,
          "description" => "JSONL_CELL_ANCHOR_PICTURE"
        }

        new_bytes =
          doc
          |> insert_payload_node(insert_after(cell_path), picture)
          |> encode_projection()

        assert {:ok, %{applied: 1}} = Projection.write_back(path, new_bytes)
        assert {:ok, after_bytes} = Projection.project_file(path)
        {_lines, after_doc} = decode_projection(after_bytes)
        assert picture_count(after_doc) == original_count + 1

        {picture_path, picture} =
          first_payload(after_doc, fn node ->
            node["type"] == "picture" and node["description"] == "JSONL_CELL_ANCHOR_PICTURE"
          end)

        assert picture["description"] == "JSONL_CELL_ANCHOR_PICTURE"
        assert previous_payload_of_type(after_doc, picture_path, "cell")["type"] == "cell"
      end
    end

    test "routes picture inserts at the start of the first paragraph list safely", %{
      ehwp: ehwp
    } do
      if not ehwp do
        IO.puts(
          "\n[skip] ehwp NIF unavailable; skipping Projection write_back HWPX leading picture insert e2e"
        )
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_picture_leading_anchor", ".hwpx")
        on_exit(fn -> cleanup_tmp(path) end)

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        original_count = picture_count(doc)

        picture = %{
          "type" => "picture",
          "src" => image_fixture(),
          "width" => 5200,
          "height" => 3000,
          "description" => "JSONL_LEADING_PICTURE_INSERT"
        }

        new_bytes =
          doc
          |> insert_payload_node({0, 0, 0}, picture)
          |> encode_projection()

        assert {:ok, %{applied: 1}} = Projection.write_back(path, new_bytes)
        assert {:ok, after_bytes} = Projection.project_file(path)
        {_lines, after_doc} = decode_projection(after_bytes)
        assert picture_count(after_doc) == original_count + 1
        assert after_bytes =~ "JSONL_LEADING_PICTURE_INSERT"
      end
    end

    test "inserts a picture while unchanged existing picture payloads have no exposed refs", %{
      ehwp: ehwp
    } do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping Projection second picture insert e2e")
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_second_picture_insert", ".hwpx")
        on_exit(fn -> cleanup_tmp(path) end)

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        {anchor_path, _node} = first_text_paragraph(doc)

        first_picture = %{
          "type" => "picture",
          "src" => image_fixture(),
          "description" => "JSONL_EXISTING_PICTURE"
        }

        first_bytes =
          doc
          |> insert_payload_node(insert_after(anchor_path), first_picture)
          |> encode_projection()

        assert {:ok, %{applied: 1}} = Projection.write_back(path, first_bytes)

        {:ok, after_first_bytes} = Projection.project_file(path)
        {_lines, after_first_doc} = decode_projection(after_first_bytes)
        {table_path, _table} = first_payload(after_first_doc, &(&1["type"] == "table"))

        second_picture = %{
          "type" => "picture",
          "src" => image_fixture(),
          "description" => "JSONL_SECOND_PICTURE"
        }

        second_bytes =
          after_first_doc
          |> insert_payload_node(insert_after(table_path), second_picture)
          |> Jason.encode!(pretty: true)

        assert {:ok, %{applied: 1}} = Projection.write_back(path, second_bytes)
        assert {:ok, after_second_bytes} = Projection.project_file(path)
        assert after_second_bytes =~ "JSONL_EXISTING_PICTURE"
        assert after_second_bytes =~ "JSONL_SECOND_PICTURE"
      end
    end

    test "does not misread adjacent existing pictures as delete and insert during earlier insert" do
      old_nodes = [
        %{
          "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
          "text" => "",
          "type" => "paragraph"
        },
        %{
          "ref" => %{"section" => 0, "paragraph" => 0, "control" => 0, "type" => "table"},
          "text" => "AUTH_TBL",
          "type" => "table"
        },
        %{
          "col" => 0,
          "ref" => %{
            "section" => 0,
            "paragraph" => 0,
            "offset" => 0,
            "cell" => %{
              "parentParaIndex" => 0,
              "controlIndex" => 0,
              "cellIndex" => 0,
              "cellParaIndex" => 0
            }
          },
          "row" => 0,
          "text" => "AUTH_TBL",
          "type" => "cell"
        },
        %{
          "ref" => %{
            "section" => 0,
            "paragraph" => 0,
            "offset" => 0,
            "cell" => %{
              "parentParaIndex" => 0,
              "controlIndex" => 0,
              "cellIndex" => 0,
              "cellParaIndex" => 0
            }
          },
          "text" => "AUTH_TBL",
          "type" => "paragraph"
        },
        %{
          "description" => "AGENT_APPEND_RED",
          "height" => 22_000,
          "ref" => %{"section" => 2, "paragraph" => 10, "control" => 0, "type" => "picture"},
          "text" => "",
          "treatAsChar" => true,
          "type" => "picture",
          "width" => 22_000
        },
        %{
          "description" => "AGENT_APPEND_BLUE",
          "height" => 22_000,
          "ref" => %{"section" => 2, "paragraph" => 10, "control" => 1, "type" => "picture"},
          "text" => "",
          "treatAsChar" => true,
          "type" => "picture",
          "width" => 22_000
        }
      ]

      new_nodes = [
        %{"text" => "", "type" => "paragraph"},
        %{"type" => "table"},
        %{
          "description" => "DBG_BIRD_INSERT",
          "src" => "/tmp/ecrits-fuse-hwpx-tidewave/bird_song_sparrow.jpg",
          "type" => "picture"
        },
        %{"col" => 0, "row" => 0, "type" => "cell"},
        %{"text" => "AUTH_TBL", "type" => "paragraph"},
        %{
          "description" => "AGENT_APPEND_RED",
          "height" => 22_000,
          "text" => "",
          "treatAsChar" => true,
          "type" => "picture",
          "width" => 22_000
        },
        %{
          "description" => "AGENT_APPEND_BLUE",
          "height" => 22_000,
          "text" => "",
          "treatAsChar" => true,
          "type" => "picture",
          "width" => 22_000
        }
      ]

      assert [
               {:insert_picture, %{"description" => "DBG_BIRD_INSERT"}, "DBG_BIRD_INSERT", %{}}
             ] = Projection.__compute_ir_changes_for_test__(old_nodes, new_nodes)
    end

    test "anchors a picture inserted after a table cell to that cell" do
      cell_ref = %{
        "section" => 0,
        "paragraph" => 4,
        "offset" => 0,
        "cell" => %{
          "parentParaIndex" => 4,
          "controlIndex" => 1,
          "cellIndex" => 2,
          "cellParaIndex" => 0
        }
      }

      old_nodes = [
        %{
          "ref" => %{"section" => 0, "paragraph" => 4, "offset" => 0},
          "text" => "",
          "type" => "paragraph"
        },
        %{
          "ref" => %{"section" => 0, "paragraph" => 4, "control" => 1, "type" => "table"},
          "text" => "AUTH_TBL",
          "type" => "table"
        },
        %{
          "col" => 2,
          "ref" => cell_ref,
          "row" => 0,
          "text" => "AUTH_TBL_R1C3",
          "type" => "cell"
        },
        %{
          "ref" => cell_ref,
          "text" => "AUTH_TBL_R1C3",
          "type" => "paragraph"
        }
      ]

      new_nodes = [
        %{"text" => "", "type" => "paragraph"},
        %{"type" => "table"},
        %{"col" => 2, "row" => 0, "type" => "cell"},
        %{
          "description" => "JSONL_CELL_IMAGE",
          "src" => "/tmp/ecrits-fuse-hwpx-tidewave/bird_song_sparrow.jpg",
          "type" => "picture"
        },
        %{"text" => "AUTH_TBL_R1C3", "type" => "paragraph"}
      ]

      assert [
               {:insert_picture, %{"ref" => ref, "inline_in_cell" => true}, "JSONL_CELL_IMAGE",
                %{}}
             ] = Projection.__compute_ir_changes_for_test__(old_nodes, new_nodes)

      assert ref == %{
               "section" => 0,
               "paragraph" => 4,
               "offset" => 0,
               "cell" => %{
                 "parentParaIndex" => 4,
                 "controlIndex" => 1,
                 "cellIndex" => 2,
                 "cellParaIndex" => 0
               }
             }
    end

    test "uses the source basename as a fallback picture description" do
      old_nodes = [
        %{
          "ref" => %{"section" => 0, "paragraph" => 1, "offset" => 0},
          "text" => "before",
          "type" => "paragraph"
        }
      ]

      new_nodes = [
        %{"text" => "before", "type" => "paragraph"},
        %{
          "src" => "/tmp/ecrits-fuse-hwpx-tidewave/bird_song_sparrow.jpg",
          "type" => "picture"
        }
      ]

      assert [
               {:insert_picture,
                %{
                  "description" => "bird_song_sparrow.jpg",
                  "src" => "/tmp/ecrits-fuse-hwpx-tidewave/bird_song_sparrow.jpg"
                }, "/tmp/ecrits-fuse-hwpx-tidewave/bird_song_sparrow.jpg", %{}}
             ] = Projection.__compute_ir_changes_for_test__(old_nodes, new_nodes)
    end

    test "still allows deleting one picture while editing the next picture by identity" do
      old_nodes = [
        %{
          "description" => "AGENT_APPEND_RED",
          "height" => 22_000,
          "ref" => %{"section" => 2, "paragraph" => 10, "control" => 0, "type" => "picture"},
          "text" => "",
          "treatAsChar" => true,
          "type" => "picture",
          "width" => 22_000
        },
        %{
          "description" => "AGENT_APPEND_BLUE",
          "height" => 22_000,
          "ref" => %{"section" => 2, "paragraph" => 10, "control" => 1, "type" => "picture"},
          "text" => "",
          "treatAsChar" => true,
          "type" => "picture",
          "width" => 22_000
        }
      ]

      new_nodes = [
        %{
          "description" => "AGENT_APPEND_BLUE",
          "height" => 24_000,
          "text" => "",
          "treatAsChar" => true,
          "type" => "picture",
          "width" => 24_000
        }
      ]

      assert [
               {:delete_node, %{"op" => "delete_node"}, "AGENT_APPEND_RED"},
               {:set, %{"control" => 1, "paragraph" => 10, "section" => 2, "type" => "picture"},
                "picture", %{"height" => 24_000, "width" => 24_000}}
             ] = Projection.__compute_ir_changes_for_test__(old_nodes, new_nodes)
    end

    test "routes picture insert, move and delete through native HWPX write-back", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping Projection write_back HWPX picture e2e")
      else
        path = copy_to_tmp(@hwpx_fixture, "projection_picture_lifecycle", ".hwpx")
        on_exit(fn -> cleanup_tmp(path) end)

        {:ok, bytes} = Projection.project_file(path)
        {_lines, doc} = decode_projection(bytes)
        original_count = picture_count(doc)
        {anchor_path, _node} = text_paragraph_after(doc, 10)

        picture =
          %{
            "type" => "picture",
            "src" => image_fixture(),
            "width" => 5200,
            "height" => 3600,
            "x" => 12_000,
            "y" => 16_000,
            "description" => "JSONL_PICTURE_LIFECYCLE"
          }

        inserted_bytes =
          doc
          |> insert_payload_node(insert_after(anchor_path), picture)
          |> encode_projection()

        assert {:ok, %{applied: 1}} = Projection.write_back(path, inserted_bytes)
        assert {:ok, after_insert_bytes} = Projection.project_file(path)
        {_lines, after_insert_doc} = decode_projection(after_insert_bytes)
        assert picture_count(after_insert_doc) == original_count + 1

        refute Enum.any?(picture_props(path), fn props ->
                 props["horzOffset"] == 12_000 and props["vertOffset"] == 16_000 and
                   props["treatAsChar"] == false
               end)

        {picture_path, picture_node} = first_picture_payload(after_insert_doc)

        for key <-
              ~w(rotationAngle horzFlip vertFlip cropLeft cropTop cropRight cropBottom
                 brightness contrast effect transparency borderColor borderWidth
                 paddingLeft paddingTop paddingRight paddingBottom
                 outerMarginLeft outerMarginTop outerMarginRight outerMarginBottom
                 hasCaption captionDirection captionVertAlign captionWidth captionSpacing
                 captionMaxWidth captionIncludeMargin restrictInPage allowOverlap sizeProtect) do
          assert Map.has_key?(picture_node, key), "projected picture payload missing #{key}"
        end

        moved_bytes =
          after_insert_doc
          |> replace_payload_node(
            picture_path,
            Map.merge(picture_node, %{
              "x" => 12_000,
              "y" => 16_000,
              "width" => 6400,
              "height" => 4200,
              "treatAsChar" => false
            })
          )
          |> encode_projection()

        assert {:ok, %{applied: 1}} = Projection.write_back(path, moved_bytes)

        assert Enum.any?(picture_props(path), fn props ->
                 props["horzOffset"] == 12_000 and props["vertOffset"] == 16_000 and
                   props["width"] == 6400 and props["height"] == 4200 and
                   props["treatAsChar"] == false
               end)

        assert {:ok, after_move_bytes} = Projection.project_file(path)
        {_lines, after_move_doc} = decode_projection(after_move_bytes)

        deleted_bytes =
          after_move_doc
          |> delete_payload_node(picture_path)
          |> encode_projection()

        assert {:ok, %{applied: 1}} = Projection.write_back(path, deleted_bytes)
        assert {:ok, after_delete_bytes} = Projection.project_file(path)
        {_lines, after_delete_doc} = decode_projection(after_delete_bytes)
        assert picture_count(after_delete_doc) == original_count
      end
    end
  end

  # --- helpers --------------------------------------------------------------

  defp image_fixture do
    path = Path.join(System.tmp_dir!(), "ecrits-projection-pixel.png")
    File.write!(path, Base.decode64!(@png_1x1))
    path
  end

  defp copy_to_tmp(src, tag, ext) do
    dir = Path.join(System.tmp_dir!(), "ecrits-#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dest = Path.join(dir, "doc" <> ext)
    File.cp!(src, dest)
    dest
  end

  defp cleanup_tmp(path) do
    _ = Pool.close_by_path(path)
    File.rm_rf(Path.dirname(path))
  end

  # One JSON value, one paragraph group per line (#460): decode the whole
  # binary; `lines` stays available for layout assertions.
  defp decode_projection(bytes) do
    lines = bytes |> String.split("\n") |> Enum.reject(&(&1 == ""))
    {lines, Jason.decode!(bytes)}
  end

  defp encode_projection(doc) do
    Jason.encode!(doc) <> "\n"
  end

  defp payload_nodes(doc) do
    for section <- doc,
        paragraph <- section,
        node <- paragraph do
      node
    end
  end

  defp first_text_paragraph(doc) do
    first_payload(doc, fn node ->
      node["type"] == "paragraph" and is_binary(node["text"]) and node["text"] != ""
    end)
  end

  defp text_paragraph_after(doc, min_paragraph_index) do
    doc
    |> Enum.with_index()
    |> Enum.reduce_while(nil, fn {section, section_index}, _acc ->
      found =
        section
        |> Enum.with_index()
        |> Enum.find_value(fn {paragraph, paragraph_index} ->
          if paragraph_index >= min_paragraph_index do
            paragraph
            |> Enum.with_index()
            |> Enum.find_value(fn {node, payload_index} ->
              if node["type"] == "paragraph" and is_binary(node["text"]) and node["text"] != "" do
                {{section_index, paragraph_index, payload_index}, node}
              end
            end)
          end
        end)

      case found do
        nil -> {:cont, nil}
        found -> {:halt, found}
      end
    end)
  end

  defp first_cell(doc) do
    first_payload(doc, &(&1["type"] == "cell"))
  end

  defp first_text_cell_paragraph(doc) do
    doc
    |> Enum.with_index()
    |> Enum.reduce_while(nil, fn {section, section_index}, _acc ->
      found =
        section
        |> Enum.with_index()
        |> Enum.find_value(fn {paragraph, paragraph_index} ->
          paragraph
          |> Enum.with_index()
          |> Enum.reduce_while(false, fn {node, payload_index}, cell_seen? ->
            cond do
              node["type"] == "cell" ->
                {:cont, true}

              cell_seen? and node["type"] == "paragraph" and is_binary(node["text"]) and
                  node["text"] != "" ->
                {:halt, {{section_index, paragraph_index, payload_index}, node}}

              true ->
                {:cont, cell_seen?}
            end
          end)
          |> case do
            {{_, _, _}, %{}} = found -> found
            _not_found -> nil
          end
        end)

      case found do
        nil -> {:cont, nil}
        found -> {:halt, found}
      end
    end)
  end

  defp first_picture_payload(doc) do
    first_payload(doc, fn node -> node["type"] == "picture" end)
  end

  defp picture_count(doc) do
    Enum.count(payload_nodes(doc), &(&1["type"] == "picture"))
  end

  defp first_payload_node(doc, predicate) do
    {_path, node} = first_payload(doc, predicate)
    node
  end

  defp first_payload(doc, predicate) do
    doc
    |> Enum.with_index()
    |> Enum.reduce_while(nil, fn {section, section_index}, _acc ->
      case first_payload_in_section(section, section_index, predicate) do
        nil -> {:cont, nil}
        found -> {:halt, found}
      end
    end)
  end

  defp first_payload_in_section(section, section_index, predicate) do
    section
    |> Enum.with_index()
    |> Enum.reduce_while(nil, fn {paragraph, paragraph_index}, _acc ->
      case first_payload_in_paragraph(paragraph, section_index, paragraph_index, predicate) do
        nil -> {:cont, nil}
        found -> {:halt, found}
      end
    end)
  end

  defp first_payload_in_paragraph(paragraph, section_index, paragraph_index, predicate) do
    paragraph
    |> Enum.with_index()
    |> Enum.find_value(fn {node, payload_index} ->
      if predicate.(node), do: {{section_index, paragraph_index, payload_index}, node}
    end)
  end

  defp replace_payload_node(doc, {section_index, paragraph_index, payload_index}, node) do
    section = Enum.at(doc, section_index)
    paragraph = Enum.at(section, paragraph_index)
    paragraph = List.replace_at(paragraph, payload_index, node)
    section = List.replace_at(section, paragraph_index, paragraph)
    List.replace_at(doc, section_index, section)
  end

  defp insert_after({section_index, paragraph_index, payload_index}),
    do: {section_index, paragraph_index, payload_index + 1}

  defp previous_payload_of_type(doc, {section_index, paragraph_index, payload_index}, type) do
    doc
    |> Enum.at(section_index)
    |> Enum.at(paragraph_index)
    |> Enum.take(payload_index)
    |> Enum.reverse()
    |> Enum.find(fn node -> node["type"] == type end)
    |> case do
      nil -> raise "no previous payload of type #{inspect(type)}"
      node -> node
    end
  end

  defp insert_payload_node(doc, {section_index, paragraph_index, payload_index}, node) do
    section = Enum.at(doc, section_index)
    paragraph = Enum.at(section, paragraph_index)
    paragraph = List.insert_at(paragraph, payload_index, node)
    section = List.replace_at(section, paragraph_index, paragraph)
    List.replace_at(doc, section_index, section)
  end

  defp delete_payload_node(doc, {section_index, paragraph_index, payload_index}) do
    section = Enum.at(doc, section_index)
    paragraph = Enum.at(section, paragraph_index)
    paragraph = List.delete_at(paragraph, payload_index)
    section = List.replace_at(section, paragraph_index, paragraph)
    List.replace_at(doc, section_index, section)
  end

  defp paragraph_context(path, {section, paragraph, _payload}) do
    {:ok, handle, _metadata} = Ehwp.open(path, [])

    try do
      {:ok, json} =
        Ehwp.query(handle, %{q: "context", section: section, paragraph: paragraph, offset: 0})

      json |> Jason.decode!() |> Map.fetch!("paragraph")
    after
      Ehwp.close(handle)
    end
  end

  defp paragraph_context(path, %{"ref" => [section, paragraph, _offset]}) do
    paragraph_context(path, %{"ref" => %{"section" => section, "paragraph" => paragraph}})
  end

  defp picture_props(path) do
    {:ok, document_id} = Pool.open(path, kind: :hwpx)
    {:server, editor} = Pool.route(Pool, document_id)
    {:ok, elements} = Ecrits.Doc.Editor.elements(editor)

    elements
    |> Enum.filter(&(&1["type"] == "picture"))
    |> Enum.map(fn node ->
      {:ok, props} =
        Ecrits.Doc.Editor.get(editor, node["ref"], [
          "width",
          "height",
          "horzOffset",
          "vertOffset",
          "treatAsChar"
        ])

      props
    end)
  end

  defp browser_transaction_loop(owner, path, exported_bytes, commit_reply) do
    receive do
      {:doc_browser_request, from, ref, verb, %{edit_id: edit_id}} ->
        handle_browser_transaction_request(
          owner,
          path,
          exported_bytes,
          commit_reply,
          from,
          ref,
          verb,
          edit_id
        )

      {:doc_browser_request, from, ref, verb, %{edit_id: edit_id}, _expected_document_id} ->
        handle_browser_transaction_request(
          owner,
          path,
          exported_bytes,
          commit_reply,
          from,
          ref,
          verb,
          edit_id
        )
    end
  end

  defp handle_browser_transaction_request(
         owner,
         path,
         exported_bytes,
         commit_reply,
         from,
         ref,
         verb,
         edit_id
       ) do
    send(owner, {:browser_transaction, verb, edit_id, File.read!(path)})
    send(owner, {:browser_transaction_owner, verb, edit_id, from})

    reply =
      case verb do
        :vfs_write -> {:ok, %{"bytes" => exported_bytes}}
        :vfs_commit when commit_reply == :timeout -> :no_reply
        :vfs_commit -> commit_reply
        :vfs_rollback -> {:ok, %{"rolled_back" => true}}
      end

    reply_and_ack_browser_request(from, ref, reply)
    browser_transaction_loop(owner, path, exported_bytes, commit_reply)
  end

  defp browser_commit_loop(exported_bytes) do
    receive do
      {:doc_browser_request, from, ref, verb, _payload} ->
        handle_browser_commit_request(exported_bytes, from, ref, verb)

      {:doc_browser_request, from, ref, verb, _payload, _expected_document_id} ->
        handle_browser_commit_request(exported_bytes, from, ref, verb)
    end
  end

  defp handle_browser_commit_request(exported_bytes, from, ref, verb) do
    reply =
      case verb do
        :vfs_write -> {:ok, %{"bytes" => exported_bytes}}
        :vfs_commit -> {:ok, %{"committed" => true}}
        :vfs_rollback -> {:ok, %{"rolled_back" => true}}
      end

    reply_and_ack_browser_request(from, ref, reply)
    browser_commit_loop(exported_bytes)
  end

  defp browser_payload_loop(owner, exported_bytes, commit_reply) do
    receive do
      {:doc_browser_request, from, ref, verb, payload} ->
        handle_browser_payload(owner, exported_bytes, commit_reply, from, ref, verb, payload)

      {:doc_browser_request, from, ref, verb, payload, _expected_document_id} ->
        handle_browser_payload(owner, exported_bytes, commit_reply, from, ref, verb, payload)
    end
  end

  defp handle_browser_payload(owner, exported_bytes, commit_reply, from, ref, verb, payload) do
    send(owner, {:browser_payload, verb, payload})

    reply =
      case verb do
        :vfs_write -> {:ok, %{"bytes" => exported_bytes}}
        :vfs_commit -> commit_reply
        :vfs_rollback -> {:ok, %{"rolled_back" => true}}
      end

    reply_and_ack_browser_request(from, ref, reply)
    browser_payload_loop(owner, exported_bytes, commit_reply)
  end

  defp reply_and_ack_browser_request(_from, _ref, :no_reply), do: :ok

  defp reply_and_ack_browser_request(from, ref, reply) do
    send(from, {:doc_browser_reply, ref, reply})

    receive do
      {:doc_browser_request_completed, ^from, ^ref, ack_ref} ->
        send(from, {:doc_browser_request_completion_ack, ack_ref, :ok})
    end
  end

  defp browser_text_change(marker) do
    [
      {:text,
       %{
         "op" => "insert_text",
         "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
         "text" => marker
       }, marker}
    ]
  end

  defp start_test_task(fun) when is_function(fun, 0) do
    child_spec = Supervisor.child_spec({Task, fun}, id: make_ref())
    start_supervised!(child_spec)
  end

  # The ehwp NIF is present iff Ehwp.open succeeds on the fixture. Mirrors the
  # office tests' self-skip so the default suite never requires the native arm.
  defp ehwp_available?(path) do
    Code.ensure_loaded?(Ehwp) and
      match?({:ok, _h, _m}, safe_ehwp_open(path))
  end

  defp safe_ehwp_open(path) do
    Ehwp.open(path, [])
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
