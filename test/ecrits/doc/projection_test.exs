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

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Projection

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
               {11, 2, "앞"},
               {11, 3, "쪽"},
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

    test "streams multi-node write-back as ordered grapheme edit tokens", %{ehwp: ehwp} do
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

        expected_total =
          length(String.graphemes("STREAMED_WRITEBACK_TOKEN_ONE")) +
            length(String.graphemes("STREAMED_WRITEBACK_TOKEN_TWO"))

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
        assert List.last(events).applied >= applied_total

        markers = MapSet.new(events, & &1.marker)
        assert MapSet.member?(markers, "STREAMED_WRITEBACK_TOKEN_ONE")
        assert MapSet.member?(markers, "STREAMED_WRITEBACK_TOKEN_TWO")

        refute_receive {:vfs_doc_edited, _info}
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

  defp decode_projection(bytes) do
    lines = bytes |> String.split("\n") |> Enum.reject(&(&1 == ""))
    {lines, Jason.decode!(List.first(lines))}
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
