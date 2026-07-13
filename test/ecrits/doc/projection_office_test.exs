defmodule Ecrits.Doc.ProjectionOfficeTest do
  @moduledoc """
  Office (libre) FUSE projection + write-back.

  The office arm projects through `Libreofficex.LokBackend.Ir` (the engine's own
  IR policy in the dep): ref-addressed (no ref in the bytes), runs and runtime
  context dropped, identity carried by the nested `[section[paragraph[payload]]]`
  position. Calc cell value/formula fields stay in the payload because they are
  the spreadsheet edit surface. Write-back recovers the real ref — ordinal
  `p<idx>` OR stable name `tbl[..]/cell[B2]` — from the positionally-aligned live
  node.

  Self-skips green when the LibreOffice UNO arm is unavailable, exactly like
  `office_native_test.exs`, so the default suite stays toolchain-free.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Office
  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Projection

  @docx Path.expand("../../fixtures/office/table.docx", __DIR__)
  @pptx Path.expand("../../fixtures/office/slides.pptx", __DIR__)
  @image Path.expand("../../../priv/static/images/landing/hero.png", __DIR__)

  setup do
    {:ok, native: uno_available?()}
  end

  test "docx projects ref-addressed: no ref, no run, no synthetic fields", %{native: native} do
    skip_or(native, "office projection shape", fn ->
      tmp = copy(@docx)
      {:ok, bytes} = Projection.project_file(tmp)

      refute bytes =~ ~s("ref")
      refute bytes =~ ~s("run")
      refute bytes =~ ~s("context")
      refute bytes =~ ~s("row")
      refute bytes =~ ~s("col")

      # nested [section[paragraph[payload]]] — one section, each node its own paragraph
      [section] = Jason.decode!(bytes)
      types = Enum.map(section, fn [node] -> node["type"] end)
      assert "paragraph" in types
      assert "table" in types
      assert "cell" in types
      refute "run" in types

      # deterministic
      assert {:ok, ^bytes} = Projection.project_file(tmp)
      cleanup(tmp)
    end)
  end

  test "no-op write_back applies nothing", %{native: native} do
    skip_or(native, "office no-op write_back", fn ->
      tmp = copy(@docx)
      {:ok, bytes} = Projection.project_file(tmp)
      assert {:ok, %{applied: 0}} = Projection.write_back(tmp, bytes, root: Path.dirname(tmp))
      cleanup(tmp)
    end)
  end

  test "write_back persists a paragraph edit (positional ordinal ref recovered)", %{
    native: native
  } do
    skip_or(native, "office paragraph write_back", fn ->
      assert_persisted(@docx, "Intro paragraph before the table.", "INTRO ROUNDTRIP.")
    end)
  end

  test "write_back persists a cell edit (stable NAME ref recovered from live node)", %{
    native: native
  } do
    skip_or(native, "office cell write_back", fn ->
      assert_persisted(@docx, "North", "WESTROUNDTRIP")
    end)
  end

  test "write_back persists an Office column_def count edit", %{native: native} do
    skip_or(native, "office column_def write_back", fn ->
      tmp = copy(@docx)
      {:ok, handle} = Office.open(tmp, kind: :docx)

      assert {:ok, _} =
               Office.edit(handle, %{
                 "op" => "set_columns",
                 "from" => "p0",
                 "to" => "p1",
                 "count" => 2,
                 "gap" => 400,
                 "name" => "VfsColumns"
               })

      assert {:ok, _} = Office.save(handle, format: :docx, path: tmp)
      Office.close(handle)
      Pool.close_by_path(tmp)

      {:ok, bytes} = Projection.project_file(tmp)
      doc = Jason.decode!(bytes)
      {path, columns} = first_payload(doc, &(&1["type"] == "column_def"))

      refute Map.has_key?(columns, "ref")
      assert columns["count"] == 2
      assert_in_delta columns["gap"], 400, 4

      edited = %{columns | "count" => 3, "gap" => 600}

      assert {:ok, %{applied: 1}} =
               Projection.write_back(tmp, replace_payload(doc, path, edited),
                 root: Path.dirname(tmp)
               )

      Pool.close_by_path(tmp)
      {:ok, after_bytes} = Projection.project_file(tmp)
      after_doc = Jason.decode!(after_bytes)
      {_path, after_columns} = first_payload(after_doc, &(&1["type"] == "column_def"))

      assert after_columns["count"] == 3
      assert_in_delta after_columns["gap"], 600, 4

      cleanup(tmp)
    end)
  end

  test "xlsx projection keeps editable Calc cell fields", %{native: native} do
    skip_or(native, "xlsx projection shape", fn ->
      tmp = write_xlsx()
      {:ok, bytes} = Projection.project_file(tmp)
      doc = Jason.decode!(bytes)

      refute bytes =~ ~s("ref")
      refute bytes =~ ~s("context")

      {_path, b2} = first_payload(doc, &(&1["type"] == "cell" and &1["address"] == "B2"))
      assert b2["sheet"] == "Population & Households"
      assert b2["text"] == "123"
      assert b2["display"] == "123"
      assert b2["value"] == 123.0
      assert b2["value_type"] == "number"
      assert b2["row"] == 2
      assert b2["col"] == 2

      {_path, c2} = first_payload(doc, &(&1["type"] == "cell" and &1["address"] == "C2"))
      assert c2["value_type"] == "formula"
      assert String.starts_with?(c2["formula"], "=SUM(B2")

      cleanup(tmp)
    end)
  end

  test "write_back persists typed xlsx value and formula edits", %{native: native} do
    skip_or(native, "xlsx value/formula write_back", fn ->
      tmp = write_xlsx()
      {:ok, bytes} = Projection.project_file(tmp)
      doc = Jason.decode!(bytes)

      {b2_path, b2} = first_payload(doc, &(&1["type"] == "cell" and &1["address"] == "B2"))
      {c2_path, c2} = first_payload(doc, &(&1["type"] == "cell" and &1["address"] == "C2"))

      edited_doc =
        doc
        |> put_payload(b2_path, %{b2 | "text" => "321", "value" => 321.0})
        |> put_payload(c2_path, %{c2 | "formula" => "=SUM(B2:B2)+7", "text" => "328"})

      assert {:ok, %{applied: 2}} =
               Projection.write_back(tmp, Jason.encode!(edited_doc), root: Path.dirname(tmp))

      Pool.close_by_path(tmp)
      {:ok, after_bytes} = Projection.project_file(tmp)
      after_doc = Jason.decode!(after_bytes)

      {_path, b2_after} =
        first_payload(after_doc, &(&1["type"] == "cell" and &1["address"] == "B2"))

      assert b2_after["text"] == "321"
      assert b2_after["value"] == 321.0
      assert b2_after["value_type"] == "number"

      {_path, c2_after} =
        first_payload(after_doc, &(&1["type"] == "cell" and &1["address"] == "C2"))

      assert c2_after["value_type"] == "formula"
      assert String.starts_with?(c2_after["formula"], "=SUM(B2")
      assert String.ends_with?(c2_after["formula"], ")+7")

      cleanup(tmp)
    end)
  end

  test "write_back persists a reflected property edit", %{native: native} do
    skip_or(native, "office property write_back", fn ->
      tmp = copy(@docx)
      {:ok, bytes} = Projection.project_file(tmp)
      doc = Jason.decode!(bytes)
      {path, cell} = first_payload(doc, &(&1["type"] == "cell" and &1["text"] == "North"))

      edited =
        cell
        |> put_in(["props", "BackColor"], 16_776_960)

      assert {:ok, %{applied: 1}} =
               Projection.write_back(tmp, replace_payload(doc, path, edited),
                 root: Path.dirname(tmp)
               )

      Pool.close_by_path(tmp)
      {:ok, after_bytes} = Projection.project_file(tmp)
      after_doc = Jason.decode!(after_bytes)

      {_path, after_cell} =
        first_payload(after_doc, &(&1["type"] == "cell" and &1["text"] == "North"))

      assert get_in(after_cell, ["props", "BackColor"]) == 16_776_960
      cleanup(tmp)
    end)
  end

  test "write_back persists Writer metadata and tracked-change settings", %{native: native} do
    skip_or(native, "office document semantics write_back", fn ->
      tmp = copy(@docx)
      {:ok, bytes} = Projection.project_file(tmp)
      doc = Jason.decode!(bytes)
      {document_path, document} = first_payload(doc, &(&1["type"] == "document"))

      edited_document =
        put_in(document, ["metadata", "title"], "IR contract metadata")

      assert {:ok, %{applied: 1}} =
               Projection.write_back(tmp, replace_payload(doc, document_path, edited_document),
                 root: Path.dirname(tmp)
               )

      Pool.close_by_path(tmp)
      {:ok, metadata_bytes} = Projection.project_file(tmp)
      metadata_doc = Jason.decode!(metadata_bytes)
      {_path, metadata_after} = first_payload(metadata_doc, &(&1["type"] == "document"))
      assert get_in(metadata_after, ["metadata", "title"]) == "IR contract metadata"

      case first_payload(
             metadata_doc,
             &(&1["type"] == "document_protection" and
                 is_boolean(get_in(&1, ["props", "RecordChanges"])))
           ) do
        {settings_path, settings} ->
          current = get_in(settings, ["props", "RecordChanges"])
          edited_settings = put_in(settings, ["props", "RecordChanges"], not current)

          assert {:ok, %{applied: 1}} =
                   Projection.write_back(
                     tmp,
                     replace_payload(metadata_doc, settings_path, edited_settings),
                     root: Path.dirname(tmp)
                   )

          Pool.close_by_path(tmp)
          {:ok, settings_bytes} = Projection.project_file(tmp)
          settings_doc = Jason.decode!(settings_bytes)

          {_path, settings_after} =
            first_payload(settings_doc, &(&1["type"] == "document_protection"))

          assert get_in(settings_after, ["props", "RecordChanges"]) == not current
      end

      cleanup(tmp)
    end)
  end

  test "write_back rejects unknown and type-invalid reflected properties", %{native: native} do
    skip_or(native, "office property validation", fn ->
      tmp = copy(@docx)
      {:ok, bytes} = Projection.project_file(tmp)
      doc = Jason.decode!(bytes)
      {path, paragraph} = first_payload(doc, &(&1["type"] == "paragraph"))

      unknown = put_in(paragraph, ["props", "TypoStyle"], "Heading 1")

      assert {:error, {:invalid_property, "TypoStyle"}} =
               Projection.write_back(tmp, replace_payload(doc, path, unknown),
                 root: Path.dirname(tmp)
               )

      invalid_type = put_in(paragraph, ["props", "ParaStyleName"], 42)

      assert {:error, {:invalid_property_type, "ParaStyleName", _uno_type}} =
               Projection.write_back(tmp, replace_payload(doc, path, invalid_type),
                 root: Path.dirname(tmp)
               )

      cleanup(tmp)
    end)
  end

  test "write_back routes inserted table payloads through Office native table creation", %{
    native: native
  } do
    skip_or(native, "office table insert write_back", fn ->
      tmp = copy(@docx)
      {:ok, bytes} = Projection.project_file(tmp)
      doc = Jason.decode!(bytes)

      {anchor_path, _node} =
        first_payload(
          doc,
          &(&1["type"] == "paragraph" and String.contains?(&1["text"] || "", "Intro"))
        )

      table = %{
        "type" => "table",
        "cells" => [["OFFICE_VFS_H1", "OFFICE_VFS_H2"], ["OFFICE_VFS_A", "OFFICE_VFS_B"]],
        "header" => true
      }

      assert {:ok, %{applied: 1}} =
               Projection.write_back(tmp, insert_payload_after(doc, anchor_path, table),
                 root: Path.dirname(tmp)
               )

      Pool.close_by_path(tmp)
      {:ok, after_bytes} = Projection.project_file(tmp)

      for marker <- List.flatten(table["cells"]) do
        assert after_bytes =~ marker
      end

      cleanup(tmp)
    end)
  end

  test "write_back routes inserted picture payloads through Office native picture creation", %{
    native: native
  } do
    skip_or(native, "office picture insert write_back", fn ->
      tmp = copy(@docx)
      {:ok, bytes} = Projection.project_file(tmp)
      doc = Jason.decode!(bytes)
      original_count = picture_count(doc)

      {anchor_path, _node} =
        first_payload(
          doc,
          &(&1["type"] == "paragraph" and String.contains?(&1["text"] || "", "Intro"))
        )

      picture = %{
        "type" => "picture",
        "src" => @image,
        "width" => 1200,
        "height" => 900,
        "name" => "OfficeVfsPicture"
      }

      assert {:ok, %{applied: 1}} =
               Projection.write_back(tmp, insert_payload_after(doc, anchor_path, picture),
                 root: Path.dirname(tmp)
               )

      Pool.close_by_path(tmp)
      {:ok, after_bytes} = Projection.project_file(tmp)
      assert picture_count(Jason.decode!(after_bytes)) == original_count + 1
      cleanup(tmp)
    end)
  end

  test "pptx projects ref-addressed (slide + text_frame, run dropped)", %{native: native} do
    skip_or(native, "pptx projection shape", fn ->
      tmp = copy(@pptx)
      {:ok, bytes} = Projection.project_file(tmp)
      refute bytes =~ ~s("ref")
      refute bytes =~ ~s("run")
      [section] = Jason.decode!(bytes)
      types = Enum.map(section, fn [node] -> node["type"] end)
      assert "slide" in types
      cleanup(tmp)
    end)
  end

  test "pptx shape geometry edits route through set_geometry and persist", %{native: native} do
    skip_or(native, "pptx projection geometry", fn ->
      tmp = copy(@pptx)
      {:ok, bytes} = Projection.project_file(tmp)
      doc = Jason.decode!(bytes)
      {path, shape} = first_payload(doc, &(&1["type"] in ["shape", "text_frame"]))

      assert is_integer(shape["x"])
      assert is_integer(shape["width"]) and shape["width"] > 0

      edited =
        shape
        |> Map.update!("x", &(&1 + 250))
        |> Map.update!("width", &(&1 + 500))

      assert {:ok, %{applied: applied}} =
               Projection.write_back(tmp, replace_payload(doc, path, edited),
                 root: Path.dirname(tmp)
               )

      assert applied >= 1
      Pool.close_by_path(tmp)
      {:ok, after_bytes} = Projection.project_file(tmp)

      {_path, shape_after} =
        first_payload(Jason.decode!(after_bytes), &(&1["type"] == shape["type"]))

      assert shape_after["x"] == shape["x"] + 250
      assert_in_delta shape_after["width"], shape["width"] + 500, 1
      cleanup(tmp)
    end)
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp assert_persisted(fixture, from, to) do
    tmp = copy(fixture)
    {:ok, bytes} = Projection.project_file(tmp)
    edited = String.replace(bytes, ~s("text":"#{from}"), ~s("text":"#{to}"))
    assert edited != bytes, "the edit did not change the projection bytes"

    assert {:ok, %{applied: applied}} =
             Projection.write_back(tmp, edited, root: Path.dirname(tmp))

    assert applied >= 1

    # force a TRUE on-disk reload, not the live in-memory editor
    Pool.close_by_path(tmp)
    {:ok, disk} = Projection.project_file(tmp)
    assert disk =~ to, "edited text not persisted to disk"
    refute disk =~ from, "old text still present after edit"
    cleanup(tmp)
  end

  defp skip_or(true, _msg, fun), do: fun.()
  defp skip_or(false, msg, _fun), do: IO.puts("\n[skip] LibreOffice UNO arm unavailable; #{msg}")

  defp copy(fixture) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "proj_office_#{System.unique_integer([:positive])}#{Path.extname(fixture)}"
      )

    File.cp!(fixture, tmp)
    Pool.close_by_path(tmp)
    tmp
  end

  defp write_xlsx do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "proj_office_#{System.unique_integer([:positive])}.xlsx"
      )

    File.write!(tmp, xlsx_bytes())
    Pool.close_by_path(tmp)
    tmp
  end

  defp cleanup(tmp) do
    Pool.close_by_path(tmp)
    File.rm(tmp)
  end

  defp first_payload(doc, predicate) do
    doc
    |> Enum.with_index()
    |> Enum.reduce_while(nil, fn {section, section_index}, _acc ->
      section
      |> Enum.with_index()
      |> Enum.reduce_while(nil, fn {paragraph, paragraph_index}, _inner ->
        paragraph
        |> Enum.with_index()
        |> Enum.find(fn {node, _payload_index} -> predicate.(node) end)
        |> case do
          {node, payload_index} ->
            {:halt, {{section_index, paragraph_index, payload_index}, node}}

          nil ->
            {:cont, nil}
        end
      end)
      |> case do
        nil -> {:cont, nil}
        found -> {:halt, found}
      end
    end)
    |> case do
      nil -> flunk("payload not found")
      found -> found
    end
  end

  defp replace_payload(doc, path, node) do
    doc
    |> put_payload(path, node)
    |> Jason.encode!()
  end

  defp put_payload(doc, {section_index, paragraph_index, payload_index}, node) do
    section = Enum.at(doc, section_index)
    paragraph = Enum.at(section, paragraph_index)
    paragraph = List.replace_at(paragraph, payload_index, node)
    section = List.replace_at(section, paragraph_index, paragraph)

    List.replace_at(doc, section_index, section)
  end

  defp insert_payload_after(doc, {section_index, paragraph_index, _payload_index}, node) do
    section = Enum.at(doc, section_index)
    section = List.insert_at(section, paragraph_index + 1, [node])

    doc
    |> List.replace_at(section_index, section)
    |> Jason.encode!()
  end

  defp picture_count(doc) do
    doc
    |> List.flatten()
    |> Enum.count(&(&1["type"] == "picture"))
  end

  defp uno_available? do
    case Office.open(@docx, kind: :docx) do
      {:ok, handle} ->
        Office.close(handle)
        true

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp xlsx_bytes do
    files = [
      {~c"[Content_Types].xml",
       """
       <?xml version="1.0" encoding="UTF-8"?>
       <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
         <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
         <Default Extension="xml" ContentType="application/xml"/>
         <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
         <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
         <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
       </Types>
       """},
      {~c"_rels/.rels",
       """
       <?xml version="1.0" encoding="UTF-8"?>
       <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Id="rId1"
                       Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
                       Target="xl/workbook.xml"/>
       </Relationships>
       """},
      {~c"xl/workbook.xml",
       """
       <?xml version="1.0" encoding="UTF-8"?>
       <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
         <sheets>
           <sheet name="Population &amp; Households" sheetId="1" r:id="rId1"/>
         </sheets>
       </workbook>
       """},
      {~c"xl/_rels/workbook.xml.rels",
       """
       <?xml version="1.0" encoding="UTF-8"?>
       <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Id="rId1"
                       Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
                       Target="worksheets/sheet1.xml"/>
         <Relationship Id="rId2"
                       Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"
                       Target="sharedStrings.xml"/>
       </Relationships>
       """},
      {~c"xl/sharedStrings.xml",
       """
       <?xml version="1.0" encoding="UTF-8"?>
       <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">
         <si><t>Region &amp; Total</t></si>
         <si><t>Seoul</t></si>
       </sst>
       """},
      {~c"xl/worksheets/sheet1.xml",
       """
       <?xml version="1.0" encoding="UTF-8"?>
       <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
         <dimension ref="A1:C2"/>
         <sheetData>
           <row r="1">
             <c r="A1" t="s"><v>0</v></c>
             <c r="B1" t="inlineStr"><is><t>Population</t></is></c>
             <c r="C1" t="inlineStr"><is><t>Total</t></is></c>
           </row>
           <row r="2">
             <c r="A2" t="s"><v>1</v></c>
             <c r="B2"><v>123</v></c>
             <c r="C2"><f>SUM(B2:B2)</f><v>123</v></c>
           </row>
         </sheetData>
       </worksheet>
       """}
    ]

    {:ok, {_name, bytes}} = :zip.create(~c"test.xlsx", files, [:memory])
    bytes
  end
end
