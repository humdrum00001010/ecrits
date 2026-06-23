defmodule Ecrits.Doc.Office.XlsxReaderTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.Office.XlsxReader

  test "extracts workbook cells as sheet refs with coordinates and metadata" do
    path =
      Path.join(
        System.tmp_dir!(),
        "ecrits_xlsx_reader_test_#{System.unique_integer([:positive])}.xlsx"
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, workbook_bytes())

    assert {:ok, cells} = XlsxReader.elements(path)

    by_ref = Map.new(cells, &{&1["ref"], &1})

    assert by_ref["sheet[Population & Households]/cell[A1]"] == %{
             "ref" => "sheet[Population & Households]/cell[A1]",
             "text" => "Region & Total",
             "type" => "cell",
             "context" => "Population & Households",
             "sheet" => "Population & Households",
             "address" => "A1",
             "display" => "Region & Total",
             "value" => "Region & Total",
             "value_type" => "string",
             "row" => 1,
             "col" => 1
           }

    assert by_ref["sheet[Population & Households]/cell[B2]"]["text"] == "123"
    assert by_ref["sheet[Population & Households]/cell[B2]"]["value"] == 123.0
    assert by_ref["sheet[Population & Households]/cell[B2]"]["value_type"] == "number"

    assert by_ref["sheet[Population & Households]/cell[C2]"]["formula"] == "=SUM(B2:B3)"
    assert by_ref["sheet[Population & Households]/cell[C2]"]["text"] == "579"
    assert by_ref["sheet[Population & Households]/cell[C2]"]["row"] == 2
    assert by_ref["sheet[Population & Households]/cell[C2]"]["col"] == 3
  end

  defp workbook_bytes do
    files = [
      {~c"[Content_Types].xml",
       """
       <?xml version="1.0" encoding="UTF-8"?>
       <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
         <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
         <Default Extension="xml" ContentType="application/xml"/>
       </Types>
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
       </Relationships>
       """},
      {~c"xl/sharedStrings.xml",
       """
       <?xml version="1.0" encoding="UTF-8"?>
       <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">
         <si><t>Region &amp; Total</t></si>
         <si><t>Seoul</t></si>
         <si><r><t>House</t></r><r><t>holds</t></r></si>
       </sst>
       """},
      {~c"xl/worksheets/sheet1.xml",
       """
       <?xml version="1.0" encoding="UTF-8"?>
       <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
         <sheetData>
           <row r="1">
             <c r="A1" t="s"><v>0</v></c>
             <c r="B1" t="inlineStr"><is><t>Population</t></is></c>
             <c r="C1" t="s"><v>2</v></c>
           </row>
           <row r="2">
             <c r="A2" t="s"><v>1</v></c>
             <c r="B2"><v>123</v></c>
             <c r="C2"><f>SUM(B2:B3)</f><v>579</v></c>
           </row>
         </sheetData>
       </worksheet>
       """}
    ]

    {:ok, {_name, bytes}} = :zip.create(~c"test.xlsx", files, [:memory])
    bytes
  end
end
