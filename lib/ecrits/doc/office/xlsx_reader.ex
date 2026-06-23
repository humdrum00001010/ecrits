defmodule Ecrits.Doc.Office.XlsxReader do
  @moduledoc false

  @type element :: map()

  @spec elements(String.t()) :: {:ok, [element()]} | {:error, term()}
  def elements(path) when is_binary(path) do
    with {:ok, files} <- unzip(path),
         {:ok, sheets} <- workbook_sheets(files) do
      shared_strings = shared_strings(files)

      nodes =
        sheets
        |> Enum.flat_map(&sheet_elements(files, &1, shared_strings))
        |> Enum.sort_by(&{&1["sheet_index"], &1["row"] || 0, &1["col"] || 0})
        |> Enum.map(&Map.delete(&1, "sheet_index"))

      if nodes == [], do: {:error, :no_xlsx_cells}, else: {:ok, nodes}
    end
  end

  def elements(_path), do: {:error, :invalid_path}

  defp unzip(path) do
    case :zip.unzip(String.to_charlist(path), [:memory]) do
      {:ok, entries} ->
        {:ok, Map.new(entries, fn {name, bytes} -> {to_string(name), bytes} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workbook_sheets(files) do
    with {:ok, workbook} <- fetch_part(files, "xl/workbook.xml") do
      relationships =
        files
        |> Map.get("xl/_rels/workbook.xml.rels", "")
        |> relationships()

      sheets =
        ~r/<sheet\b([^>]*)\/?>/us
        |> Regex.scan(workbook)
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {[_, attrs], index} ->
          name = attr(attrs, "name") || "Sheet#{index}"
          rid = attr(attrs, "r:id") || attr(attrs, "id")
          target = Map.get(relationships, rid) || "xl/worksheets/sheet#{index}.xml"

          if Map.has_key?(files, target) do
            [%{index: index, name: name, path: target}]
          else
            []
          end
        end)

      if sheets == [], do: {:error, :no_xlsx_sheets}, else: {:ok, sheets}
    end
  end

  defp relationships(xml) do
    ~r/<Relationship\b([^>]*)\/?>/us
    |> Regex.scan(to_string(xml))
    |> Enum.flat_map(fn [_, attrs] ->
      with id when is_binary(id) <- attr(attrs, "Id"),
           target when is_binary(target) <- attr(attrs, "Target") do
        [{id, normalize_part_path(target)}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp normalize_part_path("/" <> target), do: String.trim_leading(target, "/")
  defp normalize_part_path("xl/" <> _ = target), do: target
  defp normalize_part_path(target), do: Path.join("xl", target)

  defp shared_strings(files) do
    files
    |> Map.get("xl/sharedStrings.xml", "")
    |> to_string()
    |> then(fn xml ->
      ~r/<si\b[^>]*>(.*?)<\/si>/us
      |> Regex.scan(xml)
      |> Enum.map(fn [_, si] ->
        texts =
          ~r/<t\b[^>]*>(.*?)<\/t>/us
          |> Regex.scan(si)
          |> Enum.map(fn [_, text] -> text |> strip_tags() |> decode_xml() end)

        Enum.join(texts)
      end)
    end)
  end

  defp sheet_elements(files, %{index: sheet_index, name: sheet_name, path: path}, shared_strings) do
    case Map.fetch(files, path) do
      {:ok, xml} ->
        xml
        |> to_string()
        |> parse_cells(sheet_index, sheet_name, shared_strings)

      :error ->
        []
    end
  end

  defp parse_cells(xml, sheet_index, sheet_name, shared_strings) do
    ~r/<c\b([^>]*)>(.*?)<\/c>/us
    |> Regex.scan(xml)
    |> Enum.flat_map(fn [_, attrs, body] ->
      with address when is_binary(address) <- attr(attrs, "r"),
           {:ok, row, col} <- cell_position(address) do
        value_type = attr(attrs, "t")
        formula = cell_formula(body)
        text = cell_text(body, value_type, shared_strings)
        {value, normalized_type} = typed_value(text, value_type)

        [
          %{
            "ref" => "sheet[#{sheet_name}]/cell[#{address}]",
            "text" => text,
            "type" => "cell",
            "context" => sheet_name,
            "sheet" => sheet_name,
            "address" => address,
            "display" => text,
            "value" => value,
            "value_type" => normalized_type,
            "row" => row,
            "col" => col,
            "sheet_index" => sheet_index
          }
          |> maybe_put("formula", formula)
        ]
      else
        _ -> []
      end
    end)
  end

  defp cell_text(body, "s", shared_strings) do
    body
    |> tag_text("v")
    |> parse_shared_string_index()
    |> then(&Enum.at(shared_strings, &1, ""))
  end

  defp cell_text(body, "inlineStr", _shared_strings), do: inline_string(body)

  defp cell_text(body, "b", _shared_strings) do
    case tag_text(body, "v") do
      "1" -> "TRUE"
      "0" -> "FALSE"
      other -> other
    end
  end

  defp cell_text(body, _type, _shared_strings), do: tag_text(body, "v")

  defp inline_string(body) do
    texts =
      ~r/<t\b[^>]*>(.*?)<\/t>/us
      |> Regex.scan(body)
      |> Enum.map(fn [_, text] -> text |> strip_tags() |> decode_xml() end)

    Enum.join(texts)
  end

  defp cell_formula(body) do
    case tag_text(body, "f") do
      "" -> nil
      "=" <> _ = formula -> formula
      formula -> "=" <> formula
    end
  end

  defp tag_text(body, tag) do
    pattern = Regex.compile!("<" <> tag <> "\\b[^>]*>(.*?)</" <> tag <> ">", "us")

    case Regex.run(pattern, body) do
      [_, text] -> text |> strip_tags() |> decode_xml()
      _ -> ""
    end
  end

  defp parse_shared_string_index(value) do
    case Integer.parse(to_string(value)) do
      {index, _rest} when index >= 0 -> index
      _ -> -1
    end
  end

  defp typed_value(text, type) when type in ["s", "str", "inlineStr"], do: {text, "string"}

  defp typed_value(text, "b"), do: {text == "TRUE", "boolean"}

  defp typed_value(text, _type) do
    case Float.parse(text) do
      {number, ""} -> {number, "number"}
      _ -> {text, "string"}
    end
  end

  defp cell_position(address) do
    case Regex.run(~r/^([A-Z]+)([1-9][0-9]*)$/i, String.upcase(address)) do
      [_, letters, row] -> {:ok, String.to_integer(row), column_index(letters)}
      _ -> {:error, :invalid_cell_ref}
    end
  end

  defp column_index(letters) do
    letters
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, acc -> acc * 26 + (char - ?A + 1) end)
  end

  defp fetch_part(files, path) do
    case Map.fetch(files, path) do
      {:ok, bytes} -> {:ok, to_string(bytes)}
      :error -> {:error, {:missing_part, path}}
    end
  end

  defp attr(attrs, name) do
    double = Regex.compile!("(?:^|\\s)" <> Regex.escape(name) <> "=\"([^\"]*)\"")
    single = Regex.compile!("(?:^|\\s)" <> Regex.escape(name) <> "='([^']*)'")

    cond do
      match = Regex.run(double, attrs) ->
        match |> Enum.at(1) |> decode_xml()

      match = Regex.run(single, attrs) ->
        match |> Enum.at(1) |> decode_xml()

      true ->
        nil
    end
  end

  defp strip_tags(value), do: Regex.replace(~r/<[^>]+>/u, value, "")

  defp decode_xml(value) do
    Regex.replace(~r/&(amp|lt|gt|quot|apos|#\d+|#x[0-9A-Fa-f]+);/u, value, fn _all, entity ->
      decode_entity(entity)
    end)
  end

  defp decode_entity("amp"), do: "&"
  defp decode_entity("lt"), do: "<"
  defp decode_entity("gt"), do: ">"
  defp decode_entity("quot"), do: "\""
  defp decode_entity("apos"), do: "'"

  defp decode_entity("#x" <> hex) do
    case Integer.parse(hex, 16) do
      {codepoint, ""} -> <<codepoint::utf8>>
      _ -> "&#x#{hex};"
    end
  end

  defp decode_entity("#" <> decimal) do
    case Integer.parse(decimal) do
      {codepoint, ""} -> <<codepoint::utf8>>
      _ -> "&#{decimal};"
    end
  end

  defp decode_entity(entity), do: "&#{entity};"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
