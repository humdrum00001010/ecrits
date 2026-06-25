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

  # A committed real HWP the ehwp NIF can open (used only by the guarded e2e block).
  @hwp_fixture Path.expand(
                 "../../../priv/static/assets/standard_contracts/employment_v1.hwp",
                 __DIR__
               )
  @hwpx_fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)
  @image_fixture Path.expand("../../../priv/static/images/landing/hero.png", __DIR__)

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

  describe "project_file/2 + fingerprint/1 over the real doc layer" do
    setup do
      {:ok, ehwp: ehwp_available?(@hwp_fixture)}
    end

    test "projects a real HWP to deterministic, grep-able bytes", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping Projection e2e over a real HWP")
      else
        # Use a PRIVATE pool so the test is isolated; project_file/2 talks to the
        # default-named Pool, so name this one __MODULE__ via a start_supervised
        # is not possible (project_file uses @default_name). Instead exercise the
        # default pool the app already supervises.
        path = copy_to_tmp(@hwp_fixture, "projection_e2e", ".hwp")

        assert {:ok, bytes} = Projection.project_file(path)
        assert is_binary(bytes)
        assert byte_size(bytes) > 0
        assert String.valid?(bytes)
        # The projection IS the document IR, nested for compact editability:
        # sections -> paragraphs -> payload nodes.
        {lines, doc} = decode_projection(bytes)
        assert length(lines) == 1
        assert nested_projection?(doc)
        assert Enum.any?(payload_nodes(doc), &match?(%{"type" => _}, &1))
        refute Enum.any?(payload_nodes(doc), &match?(%{"ref" => ref} when is_list(ref), &1))

        # Deterministic: a second projection of the same content is byte-identical.
        assert {:ok, bytes2} = Projection.project_file(path)
        assert bytes == bytes2

        # Fingerprint is stable and equals phash2 of the bytes.
        assert {:ok, fp} = Projection.fingerprint(path)
        assert fp == :erlang.phash2(bytes)
        assert {:ok, ^fp} = Projection.fingerprint(path)

        _ = Pool.close_by_path(path)
        File.rm_rf(Path.dirname(path))
      end
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

        assert {:ok, %{applied: 1, doc: doc}} = Projection.write_back(path, new_bytes)
        assert doc == Path.basename(path)

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

        {_path, cell} = first_text_cell(doc)
        refute Map.has_key?(cell, "ref")

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
        {node_path, node} = first_text_cell(doc)
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
          |> Enum.filter(&(&1["type"] == "cell" and &1["text"] in List.flatten(table["cells"])))
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
          "src" => @image_fixture,
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
          "src" => @image_fixture,
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
            "src" => @image_fixture,
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

  defp nested_projection?(doc) when is_list(doc) do
    Enum.all?(doc, fn section ->
      is_list(section) and
        Enum.all?(section, fn paragraph ->
          is_list(paragraph) and
            Enum.all?(paragraph, &match?(%{"type" => _}, &1))
        end)
    end)
  end

  defp nested_projection?(_doc), do: false

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

  defp first_text_cell(doc) do
    first_payload(doc, fn node ->
      node["type"] == "cell" and is_binary(node["text"]) and node["text"] != ""
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
