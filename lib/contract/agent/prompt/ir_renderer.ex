defmodule Contract.Agent.Prompt.IRRenderer do
  @moduledoc """
  Storage IR(`snapshots.projection` jsonb) → token-efficient compact JSON.

  Positional 정보 손실 없음:
    - p body : [sec, para, text]
    - p table: [sec, para, "T", control_idx, rows, cols, [[row, col, cell_idx, cell_para_idx, text], ...]]
    - f      : [id, label, kind, pos, value]
                pos = [sec, para, parent_para, cell_path, off_start, off_end]
                cell_path = [[controlIndex, cellIndex, cellParaIndex], ...] or null

  `render/1` 은 dynamic 컨텐츠(JSON) 만 반환. schema(`schema_prompt/0`) 는 static —
  prompt cache 친화.
  """

  @schema_prompt """
  쪽 IR 인코딩:
    p (paragraphs):
      body  → [sec, para, text]
      table → [sec, para, "T", control_idx, rows, cols, cells]
              cells: [[row, col, cell_idx, cell_para_idx, text], ...]
    f (fields):
      [id, label, kind, pos, value]
      pos = [sec, para, parent_para, cell_path, off_start, off_end]
      cell_path = [[controlIndex, cellIndex, cellParaIndex], ...] or null
      parent_para / cell_path / off_* 은 사용 안 하면 null.

  응답 ops schema (JSON only):
    {"rationale": "<1-2문장>",
     "ops": [{"kind": <insert_text|delete_text|insert_paragraph|merge_paragraph|
                       table_row_insert|table_row_delete|
                       table_column_insert|table_column_delete|table_delete>,
              "sec": int, "para": int, "parent_para": int?,
              "cell_path": [{"controlIndex": int, "cellIndex": int, "cellParaIndex": int}, ...]?,
              "off": int,
              "text": str?, "count": int?, "len": int?,
              "at_row": int?, "at_col": int?, "control_index": int?}]}
  """

  @spec schema_prompt() :: String.t()
  def schema_prompt, do: @schema_prompt

  @spec render(map()) :: String.t()
  def render(ir) when is_map(ir), do: ir |> compact_map() |> Jason.encode!()

  @doc "Same compact shape as `render/1` but returned as a map (no JSON encode)."
  @spec compact_map(map()) :: map()
  def compact_map(ir) when is_map(ir) do
    %{
      "d" => ir["title"],
      "r" => ir["revision"],
      "t" => ir["contract_type"],
      "f" => Enum.map(ir["fields"] || [], &compact_field/1),
      "p" => compact_paragraphs(ir["sections"] || [])
    }
  end

  defp compact_field(f) do
    [f["id"], f["label"], f["kind"], compact_position(f["position"] || %{}), f["value"] || ""]
  end

  defp compact_position(pos) do
    cell_path =
      case pos["cell_path"] do
        [_ | _] = path ->
          Enum.map(path, fn step ->
            [step["controlIndex"], step["cellIndex"], step["cellParaIndex"]]
          end)

        _ ->
          nil
      end

    [pos["sec"], pos["para"], pos["parent_para"], cell_path, pos["off_start"], pos["off_end"]]
  end

  defp compact_paragraphs(sections) do
    for section <- sections,
        paragraph <- section["paragraphs"] || [] do
      compact_paragraph(section["idx"], paragraph)
    end
  end

  defp compact_paragraph(s, %{"idx" => p, "kind" => "table", "tables" => [t | _]}) do
    cells =
      for cell <- t["cells"] || [], cp <- cell["paragraphs"] || [] do
        [cell["row"], cell["col"], cell["cell_idx"], cp["idx"], cp["text"] || ""]
      end

    [s, p, "T", t["control_idx"], t["rows"], t["cols"], cells]
  end

  defp compact_paragraph(s, %{"idx" => p} = paragraph) do
    [s, p, paragraph["text"] || ""]
  end
end
