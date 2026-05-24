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
  쪽 IR 인코딩 (doc.find / doc.read / doc.get):
    doc.get → {revision, d (title), t (type_key), counts: {sec, para}, outline, f (fields)}
              outline: [[sec, para, level, text], ...]  (heading 만)
              level: 0=title row (para=-1), 1=장/절, 2=조, 3=항

    doc.find → {revision, total, hits}
              hits: [[sec, para, off, len, before, match, after, kind], ...]

    doc.read → {revision, paragraphs, next_para?}
              paragraphs: [[sec, para, kind, text], ...]  body 그대로

    f (fields):
      [id, label, kind, value]
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
