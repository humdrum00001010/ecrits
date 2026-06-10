# Expected projection derived from `real_contract.hwpx`.
#
# This file is loaded by `Ecrits.Export.HWPXRealContractTest` via
# `Code.eval_file/1`. It returns a `%Ecrits.Runtime.State{}` whose
# projection mirrors the structural skeleton of the source HWPX:
#
#   * Title  ("전력기술관리법 운영요령")
#   * Chapter headings  (제1장, 제2장, 제3장)  → kind: :heading level=1
#   * Clause headings   (제1조, 제2조, …)      → kind: :heading level=2
#   * Body paragraphs   (clause text + numbered sub-items)
#   * One 5×3 table copied verbatim from the source (paragraph index 394),
#     with column widths in source HWPX units.
#
# Paragraph IDs are deterministic ("p001", "p002", …) so two evals of this
# file produce byte-identical bytes after `Ecrits.Export.HWPX.render/1`.
#
# Source paragraph indices (in `Contents/section0.xml`):
#   p001 = index 9   (blank — drop, fold whitespace)
#   p002 = index 10  → :heading level=1
#   p003 = index 12  → :heading level=2  (제1조)
#   ...
#
# See `source_contract_notes.md` for the analysis that produced this slice.

alias Ecrits.Runtime.State

# ----- table data (source: section0.xml paragraph index 394, 5×3) ----------
# Column widths in HWP units (1/100 mm). Source widths: [6156, 10684, 27947].
table_id = "tbl_emp_alloc"
table_column_widths = [6156, 10684, 27947]
table_border_fill = "9"

# Cell texts in row-major order; rowspan 2 on first-column cells captured in
# attrs.row_span.
table_cells_data = [
  # row 0 (header)
  %{id: "tc_0_0", row: 0, col: 0, text: "구분", row_span: 1, col_span: 1},
  %{id: "tc_0_1", row: 0, col: 1, text: "규    모", row_span: 1, col_span: 1},
  %{id: "tc_0_2", row: 0, col: 2, text: "감리원배치 인원수", row_span: 1, col_span: 1},
  # row 1
  %{id: "tc_1_0", row: 1, col: 0, text: "가.공동주택", row_span: 2, col_span: 1},
  %{id: "tc_1_1", row: 1, col: 1, text: "300세대 이상800세대 미만", row_span: 1, col_span: 1},
  %{
    id: "tc_1_2",
    row: 1,
    col: 2,
    text: " 영 별표 3의 기준에 따른 책임감리원 1명을 포함한 감리원 1명 이상을 총 공사기간동안 배치",
    row_span: 1,
    col_span: 1
  },
  # row 2 (col 0 is spanned from row 1)
  %{id: "tc_2_1", row: 2, col: 1, text: "800세대 이상", row_span: 1, col_span: 1},
  %{
    id: "tc_2_2",
    row: 2,
    col: 2,
    text:
      " 영 별표 3의 기준에 따른 감리원을 다음과 같이 배치 - 책임감리원: 1명을 총 공사기간동안 배치 - 보조감리원: 1명 이상을 총 공사기간대비 50퍼센트 이상 배치. 다만, 400세대를 초과할 때마다 총 공사기간대비 50퍼센트 이상 추가배치",
    row_span: 1,
    col_span: 1
  },
  # row 3
  %{id: "tc_3_0", row: 3, col: 0, text: "나.건축물", row_span: 2, col_span: 1},
  %{
    id: "tc_3_1",
    row: 3,
    col: 1,
    text: " 연면적 10,000 제곱미터 이상 연면적 30,000 제곱미터 미만",
    row_span: 1,
    col_span: 1
  },
  %{
    id: "tc_3_2",
    row: 3,
    col: 2,
    text: " 영 별표 3의 기준에 따른 책임감리원 1명을 포함한 감리원 1명 이상을 총 공사기간동안 배치",
    row_span: 1,
    col_span: 1
  },
  # row 4
  %{id: "tc_4_1", row: 4, col: 1, text: " 연면적 30,000 제곱미터이상", row_span: 1, col_span: 1},
  %{
    id: "tc_4_2",
    row: 4,
    col: 2,
    text:
      " 영 별표 3의 기준에 따른 감리원을 다음과 같이 배치 - 책임감리원: 1명을 총 공사기간동안 배치 - 보조감리원: 1명 이상을 총 공사기간대비 50퍼센트 이상 배치. 다만, 20,000제곱미터를 초과할 때마다 총 공사기간대비 50퍼센트 이상 추가배치",
    row_span: 1,
    col_span: 1
  }
]

table_cell_nodes =
  Enum.map(table_cells_data, fn c ->
    %{
      id: c.id,
      kind: :cell,
      content: c.text,
      attrs: %{
        row: c.row,
        col: c.col,
        row_span: c.row_span,
        col_span: c.col_span,
        vertical_alignment: :center
      }
    }
  end)

table_node = %{
  id: table_id,
  kind: :table,
  children: Enum.map(table_cells_data, & &1.id),
  attrs: %{
    rows: 5,
    cols: 3,
    column_widths: table_column_widths,
    border_fill_id: table_border_fill,
    header_row_count: 1
  }
}

# ----- paragraph + heading nodes -------------------------------------------

para_specs = [
  # {id, kind, level, content}
  {"p001", :heading, 1, "전력기술관리법 운영요령"},
  {"p002", :heading, 1, "제1장 총  칙"},
  {"p003", :heading, 2,
   "제1조(목적) 이 요령은 전력기술관리법(이하 \"법\"이라 한다), 같은 법 시행령(이하 \"영\"이라 한다) 및 같은 법 시행규칙(이하 \"규칙\"이라 한다)에서 산업통상자원부장관이 정하도록 한 사항(규칙 별표 1의3 및 별표 1의4의 각 비고 1에서 산업통상자원부장관이 고시하도록 한 세부평가기준은 제외한다)을 효율적으로 운영하기 위하여 필요한 세부사항을 정함을 목적으로 한다."},
  {"p004", :heading, 2, "제2조(정의) 이 요령에서 사용하는 용어의 뜻은 다음 각 호와 같다."},
  {"p005", :paragraph, nil, "  1. \"전력기술인\"이란 영 제3조 별표 1에 따른 사람을 말한다."},
  {"p006", :paragraph, nil, "  2. \"설계사\"란 영 제17조에 따른 사람을 말한다."},
  {"p007", :paragraph, nil, "  3. \"감리원\"이란 영 제21조 별표 2에 따른 사람을 말한다."},
  {"p008", :paragraph, nil,
   "  4. \"설계\"란 법 제2조제3호에 따른 설계로서 영 제2조제5호 및 제6호에 따른 기본설계 및 실시설계를 말한다."},
  {"p009", :paragraph, nil, "  5. \"감리\"란 법 제2조제4호에 규정한 공사감리를 말한다."},
  {"p010", :paragraph, nil, "  6. \"발주자\"란 전력시설물의 설치·보수공사를 발주하는 자를 말한다."},
  {"p011", :paragraph, nil,
   "  7. \"공사비 비율에 의한 방식\"이란 공사비에 일정비율을 곱하여 산출한 금액에 추가업무비용과 부가가치세를 합산하여 대가를 산출하는 방식을 말한다."},
  {"p012", :paragraph, nil,
   "  8. \"정액적산방식\"이란 직접인건비, 직접경비, 제경비와 기술료, 추가업무비용의 합계금액에 부가가치세를 합산하여 대가를 산출하는 방식을 말한다."},
  {"p013", :paragraph, nil, "  9. “직접인건비”란 당해 용역업무에 직접 종사하는 기술자의 인건비를 말한다."},
  {"p014", :paragraph, nil,
   "  10. “감리원수”란 당해 감리용역 직접인건비 산정의 기준이 되는 것으로, 감리기간 동안 투입되는 감리원의 인원 및 배치일수를 말한다."},
  {"p015", :paragraph, nil,
   "  11. \"일급방식\"이란 과외업무 및 특별업무에 대하여 일당으로 지급하는 방식으로 직접인건비에 제경비와 기술료 및 직접경비를 포함하여 지급하는 것을 말한다."},
  {"p016", :paragraph, nil, "  12. \"직선보간법\"이란 공사비가 요율표의 각 단위 중간에 있을 때의 요율을 산출하는 방식을 말한다."},
  {"p017", :paragraph, nil,
   "  13. \"공사비\"란 발주자의 전력시설물공사 총 예정금액(지급자재대 및 지입자재대 포함) 중 용지비, 보상비, 법률수속비 및 부가가치세를 제외한 일체의 공사비를 말한다. 다만, 발주자가 가격을 명시하지 아니한 재료를 제공하는 경우에는 그 재료의 시가환산액을 포함한다."},
  {"p018", :paragraph, nil,
   "  14. \"통합감리\"란 영 제20조제3항에 따라 여러 개의 전력시설물공사 현장이 인접하여 이를 하나의 공사현장으로 보고 공사감리를 할 수 있는 경우에는 통합하여 감리를 발주하거나 공사감리를 수행하게 하는 것을 말한다."},
  {"p019", :paragraph, nil, "  15. \"제3자\"란 보험 또는 공제에 가입한 설계업·감리업자와 해당 업자의 근로자를 제외한 모든 자를 말한다."},
  {"p020", :paragraph, nil,
   "  16. \"실비정액가산방식\"이란 감리원 배치계획에 따라 산출된 감리원의 등급별 인원수에 직접인건비, 직접경비, 제경비와 기술료의 합계금액에 부가가치세를 합산하여 대가를 산출하는 방식을 말한다."},
  {"p021", :heading, 2,
   "제3조(전력기술인단체) 영 제28조제2항에 따라 산업통상자원부장관이 고시하는 전력기술인단체는 한국전기기술인협회(이하 \"협회\"라 한다)를 말한다."},
  {"p022", :heading, 1, "제2장 신기술의 평가기준 및 평가절차 등에 관한 규정"},
  {"p023", :heading, 2, "제4조∼제14조 ＜삭  제＞(’17.2.9.)"},
  {"p024", :heading, 1, "제3장 전력기술용역대가 및 공사감리원 배치기준"},
  {"p025", :heading, 2,
   "제15조(대가 등의 조정) 다음 각 호의 어느 하나에 해당하는 경우 발주자는 설계업자·설계감리자 또는 감리업자와 협의하여 대가 및 업무수행기간(감리원 배치기간을 포함한다)을 조정할 수 있다."},
  {"p026", :paragraph, nil, "  1. 계약체결 후 90일 이상 경과하고 노임 및 물가변동으로 인하여 계약금액의 100분의 3 이상 증감된 경우"},
  {"p027", :paragraph, nil,
   "  2. 해당 공사의 설계변경으로 공사계약금액(자재대를 포함한다)의 조정이 10퍼센트 이상 증감된 경우. 다만, 물가변동으로 인하여 공사계약금액이 조정된 경우는 제외한다."},
  {"p028", :paragraph, nil, "  3. 해당 공사기간의 변경으로 공사감리기간이 연장된 경우"},
  {"p029", :paragraph, nil, "  4. 발주자의 요구에 의한 업무변경이 있는 경우"},
  {"p030", :paragraph, nil, "  5. 계약에 의하여 특별히 정한 경우"},
  {"p031", :paragraph, nil, "  6. 발주자 또는 시행사의 귀책사유로 공사가 중단 또는 지연되어 감리원이 추가 배치되는 경우"}
]

para_nodes =
  Enum.map(para_specs, fn
    {id, :heading, level, content} ->
      %{id: id, kind: :heading, content: content, attrs: %{level: level}}

    {id, :paragraph, _level, content} ->
      %{id: id, kind: :paragraph, content: content}
  end)

all_nodes = para_nodes ++ [table_node | table_cell_nodes]
node_order = Enum.map(para_specs, fn {id, _, _, _} -> id end) ++ [table_id]

nodes_map = Map.new(all_nodes, fn n -> {n.id, n} end)

%State{
  document_id: "doc-fixture-real-contract",
  version: 0,
  projection: %{
    State.empty_projection()
    | title: "전력기술관리법 운영요령",
      nodes: nodes_map,
      node_order: node_order,
      metadata: %{
        source_file: "real_contract.hwpx",
        source_url:
          "https://github.com/jc-kim/hwp2md/blob/main/examples/elec_tech_manger_mke_20200608.hwpx"
      }
  }
}
