defmodule Ecrits.Doc.ProjectionAuditTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.{Pool, Projection, ProjectionAudit, Rhwp}

  @work_items [
    "웹 서비스 접근성 진단과 우선순위 개선 목록 작성",
    "핵심 화면 개선 가이드와 재검수 결과 보고서 작성",
    "운영 담당자용 접근성 유지관리 가이드 제공"
  ]

  @intro "주식회사 블루버드 디자인랩(이하 ‘원사업자’)와 주식회사 에크리츠(이하 ‘수급사업자’)는(은) 신의에 따라 성실히 계약상의 권리를 행사하고, 의무를 이행할 것을 확약하며, 그 증거로써 이 계약서를 작성하여 당사자가 기명날인한 후 각각 1부씩 보관한다."

  @jurisdiction "제51조(재판관할) 이 계약과 관련된 소는 서울중앙지방법원에 제기한다."
  @body_text Enum.join([@jurisdiction | @work_items], "\n")
  @pristine_intro "---------------(이하 ‘원사업자’)와 ------------(이하 ‘수급사업자’)는(은) 신의에 따라 성실히 계약상의 권리를 행사하고, 의무를 이행할 것을 확약하며, 그 증거로써 이 계약서를 작성하여 당사자가 기명날인한 후 각각 1부씩 보관한다."
  @pristine_jurisdiction "제51조(재판관할) 이 계약과 관련된 소는 원사업자 또는 수급사업자의 주된 사무소를 관할하는 지방법원에 제기한다."
  @marker_geometry %{
    page_index: 3,
    left: 567.2,
    right: 588.9,
    top: 468.7,
    bottom: 482.0
  }
  @hwpx_fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)

  @required_front_matter_texts [
    {"contract_name", "◇ 계약명 : 웹 서비스 접근성 개선 용역"},
    {"contract_period", "◇ 계약기간 : 2026년 7월 20일부터 2026년 10월 31일까지"},
    {"contract_amount", "◇ 계약 금액 : 금 팔천팔백만원정(￦88,000,000원)(부가가치세 포함)"},
    {"party_intro", @intro},
    {"supply_date", "◇ 원재료의 공급일 : 미기재"},
    {"supply_place", "◇ 원재료의 공급장소 : 미기재"},
    {"instruction_date", "◇ 교부일 : 미기재"},
    {"instruction_lead", "◇ 성과물의 작성 개시예정일로부터 최소 (미기재)일 이전까지 교부"},
    {"delivery_date", "◇ 납품일자 : 미기재"},
    {"delivery_place", "◇ 납품장소 : 미기재"},
    {"performance_bond", "사. 계약이행보증금요율 : 계약금액의 (미기재)%"},
    {"payment_bond", "아. 대금지급보증금요율 : 계약금액의 (미기재)%"},
    {"late_interest", "◇ 지연이자요율(대금 지급 지연) : 연 (미기재)%"},
    {"other_interest", "◇ 기타 지연이자요율 : 연 (미기재)%"},
    {"delay_penalty", "차. 지체상금요율 : 지체일당 계약금액의 (미기재)/1,000"},
    {"defect_period", "카. 하자담보책임기간 : 성과물을 납품한 날로부터 (미기재)년"},
    {"indexation_none", "◇ 연동제 적용대상 없음 (미기재)"},
    {"indexation_all", "◇ 적용함 : (미기재) 【하도급대금 연동 계약서】"},
    {"indexation_partial", "◇ 일부 적용함 : (미기재) 【하도급대금 연동 계약서】 및 【하도급대금 미연동 계약서】"},
    {"indexation_excluded", "◇ 전부 적용하지 않음 : (미기재) 【하도급대금 미연동 계약서】"},
    {"renewal_deadline", "하. 계약갱신 여부에 대한 최고기한 : 미기재"},
    {"withholding_count", "거. 이행거절을 위한 기성금 등의 미지급 횟수 : 미기재 회 미지급"}
  ]

  test "brief inventory passes without relying on document indices" do
    projection = complete_projection()
    assert :ok = validate_projection(projection)

    shifted =
      update_in(projection, [Access.at(0)], fn paragraphs ->
        [paragraph("arbitrary paragraph inserted before every target") | paragraphs]
      end)

    assert :ok = validate_projection(shifted)

    with_unrelated_party_annex =
      update_in(projection, [Access.at(0)], fn paragraphs ->
        paragraphs ++
          [
            expanded_table([
              ["원사업자", "수급사업자"],
              ["상호 또는 명칭 :", "상호 또는 명칭 :"]
            ])
          ]
      end)

    assert {:error, issues} = validate_projection(with_unrelated_party_annex)
    assert Enum.any?(issues, &(&1.id == "party_table"))
  end

  test "current brief requires its contract name, signing date, and five complete party tables" do
    assert :ok = validate_projection(complete_projection())

    assert ProjectionAudit.exact_paragraph_count(
             complete_projection(),
             "2026년 7월 20일"
           ) == 6

    wrong_name =
      replace_text(
        complete_projection(),
        "◇ 계약명 : 웹 서비스 접근성 개선 용역",
        "◇ 계약명 : 이전 계약명"
      )

    assert {:error, name_issues} = validate_projection(wrong_name)
    assert Enum.any?(name_issues, &(&1.id == "contract_name"))

    wrong_date = replace_signing_date(complete_projection(), "미기재")
    assert {:error, date_issues} = validate_projection(wrong_date)
    assert Enum.any?(date_issues, &(&1.id == "signing_date"))

    missing_attachment_date =
      replace_text(complete_projection(), "2026년 7월 20일", "년 월 일", occurrence: 6)

    assert {:error, attachment_date_issues} = validate_projection(missing_attachment_date)
    assert Enum.any?(attachment_date_issues, &(&1.id == "signing_date"))

    omitted = drop_party_table_occurrence(complete_projection(), 5)
    assert {:error, omitted_issues} = validate_projection(omitted)
    assert Enum.any?(omitted_issues, &(&1.id == "party_table"))

    incomplete =
      replace_text(
        complete_projection(),
        "상호 또는 명칭 : 주식회사 에크리츠",
        "상호 또는 명칭 :",
        occurrence: 5
      )

    assert {:error, incomplete_issues} = validate_projection(incomplete)
    assert Enum.any?(incomplete_issues, &(&1.id == "party_table"))
  end

  test "table matrices read an authored cell aggregate when the cell has no paragraph" do
    projection = [
      [
        [
          %{"type" => "table"},
          %{"type" => "cell", "row" => 0, "col" => 0, "text" => "중재인 또는 중재기관"},
          %{"type" => "cell", "row" => 0, "col" => 1, "text" => "미기재"}
        ]
      ]
    ]

    assert ProjectionAudit.table_matrices(projection) == [
             [["중재인 또는 중재기관", "미기재"]]
           ]
  end

  test "each required front-matter value is independently enforced" do
    Enum.each(@required_front_matter_texts, fn {id, exact} ->
      damaged = replace_text(complete_projection(), exact, exact <> " 손상")

      assert {:error, issues} = validate_projection(damaged)
      issue = Enum.find(issues, &(&1.id == id))
      assert issue, "missing independent check for #{id}"
      assert issue.detail.expected == exact
    end)

    signing_date_damaged = replace_signing_date(complete_projection(), "년 월 일")

    assert {:error, signing_issues} = validate_projection(signing_date_damaged)
    assert Enum.any?(signing_issues, &(&1.id == "signing_date"))
    refute Enum.any?(signing_issues, &(&1.id == "party_intro"))
  end

  test "the brief jurisdiction is independently enforced at the body end" do
    damaged =
      replace_text(
        complete_projection(),
        @body_text,
        String.replace(@body_text, "서울중앙지방법원", "다른 법원")
      )

    assert {:error, issues} = validate_projection(damaged)
    assert Enum.any?(issues, &(&1.id == "contract_body_end"))
  end

  test "accepts compact and expanded schedules in the ACP-compatible pristine body-end block" do
    for format <- [:compact, :expanded] do
      projection = complete_projection(schedule: format)
      [section] = projection

      body_block =
        Enum.find(section, fn block ->
          Enum.any?(block, &match?(%{"type" => "paragraph", "text" => @body_text}, &1))
        end)

      assert [%{"type" => "paragraph", "text" => @body_text} | _payloads] = body_block
      assert Enum.any?(body_block, &match?(%{"type" => "table"}, &1))
      assert :ok = validate_projection(projection)
    end
  end

  test "rejects scattered or reordered work lines" do
    reordered =
      replace_text(
        complete_projection(),
        @body_text,
        Enum.join(
          [
            @jurisdiction,
            Enum.at(@work_items, 1),
            Enum.at(@work_items, 0),
            Enum.at(@work_items, 2)
          ],
          "\n"
        )
      )

    assert {:error, reordered_issues} =
             validate_projection(reordered)

    assert Enum.any?(reordered_issues, fn issue ->
             issue.id == "contract_body_end" and issue.reason == :work_item_placement_mismatch
           end)

    scattered =
      complete_projection()
      |> replace_text(@body_text, @jurisdiction)
      |> update_in([Access.at(0)], &(&1 ++ Enum.map(@work_items, fn item -> paragraph(item) end)))

    assert {:error, scattered_issues} =
             validate_projection(scattered)

    assert Enum.any?(scattered_issues, fn issue ->
             issue.id == "contract_body_end" and issue.reason == :work_item_placement_mismatch
           end)

    separated =
      replace_text(
        complete_projection(),
        @body_text,
        String.replace(@body_text, "\n", "\n\n", global: false)
      )

    assert {:error, separated_issues} =
             validate_projection(separated)

    assert Enum.any?(separated_issues, fn issue ->
             issue.id == "contract_body_end" and issue.reason == :work_item_placement_mismatch
           end)
  end

  test "rejects a correct schedule outside the body-end region" do
    projection = complete_projection(schedule: :compact) |> move_compact_schedule_after_annex()

    assert {:error, issues} = validate_projection(projection)

    assert Enum.any?(issues, fn issue ->
             issue.id == "contract_body_end" and issue.reason == :missing_body_end_schedule
           end)
  end

  test "requires the schedule itself to immediately follow the body-end work items" do
    unrelated_table =
      expanded_table([
        ["담당", "상태"],
        ["A", "예정"]
      ])

    projection =
      update_in(complete_projection(), [Access.at(0)], fn blocks ->
        Enum.map(blocks, fn block ->
          if Enum.any?(block, &match?(%{"type" => "paragraph", "text" => @body_text}, &1)) do
            [body_paragraph, body_char | schedule] = block
            [body_paragraph, body_char] ++ unrelated_table ++ schedule
          else
            block
          end
        end)
      end)

    assert {:error, issues} = validate_projection(projection)

    assert Enum.any?(issues, fn issue ->
             issue.id == "contract_body_end" and issue.reason == :schedule_placement_mismatch
           end)
  end

  test "accepts an existing empty paragraph when a schedule fills that blank block" do
    assert :ok = complete_projection() |> move_schedule_to_next_block() |> validate_projection()

    with_empty_paragraph = move_schedule_to_next_block(complete_projection(), paragraph(""))
    assert :ok = validate_projection(with_empty_paragraph)
  end

  test "accepts the real pristine HWP save shape with two empty spacers before the annex" do
    projection = real_pristine_shape_projection()
    [section] = projection

    article_index =
      Enum.find_index(section, fn block ->
        Enum.any?(block, &match?(%{"type" => "paragraph", "text" => @body_text}, &1))
      end)

    assert [
             %{"type" => "paragraph", "text" => ""},
             %{"type" => "table", "cells" => _cells}
           ] = Enum.at(section, article_index + 1)

    assert paragraph("") == Enum.at(section, article_index + 2)
    assert paragraph("") == Enum.at(section, article_index + 3)
    assert paragraph("【별첨】") == Enum.at(section, article_index + 4)
    assert :ok = validate_projection(projection)
  end

  test "rejects nonempty paragraphs and tables between a valid schedule and annex" do
    for intervening <- [
          paragraph("unexpected content"),
          expanded_table([["unrelated", "table"], ["A", "B"]])
        ] do
      damaged = insert_before_annex(real_pristine_shape_projection(), intervening)

      assert {:error, issues} = validate_projection(damaged)

      assert Enum.any?(issues, fn issue ->
               issue.id == "contract_body_end" and issue.reason == :schedule_placement_mismatch
             end)
    end
  end

  test "reports missed supported fields and untouched unsupported blanks" do
    projection =
      complete_projection()
      |> replace_text("◇ 납품장소 : 미기재", "◇ 납품장소 :")
      |> replace_text("전화번호 : 미기재", "전화번호 :", occurrence: 2)

    assert {:error, issues} = validate_projection(projection)
    assert Enum.any?(issues, &(&1.id == "delivery_place" and &1.reason == :missing_anchor))
    assert Enum.any?(issues, &(&1.id == "party_table" and &1.reason == :table_content_mismatch))
  end

  test "rejects stale placeholders with an appended 미기재 and an incomplete amount" do
    stale_date =
      replace_text(
        complete_projection(),
        "◇ 납품일자 : 미기재",
        "◇ 납품일자 : 년 월 일 또는 매월 ( )일 미기재"
      )

    assert {:error, issues} = validate_projection(stale_date)
    assert Enum.any?(issues, &(&1.id == "delivery_date"))

    one_amount =
      replace_text(
        complete_projection(),
        "◇ 계약 금액 : 금 팔천팔백만원정(￦88,000,000원)(부가가치세 포함)",
        "◇ 계약 금액 : 금 88,000,000원정(￦ )(부가가치세 포함)"
      )

    assert {:error, issues} = validate_projection(one_amount)
    assert Enum.any?(issues, &(&1.id == "contract_amount"))
  end

  @tag :edit_failure
  test "rejects collapsed semantic blanks and invented unsupported payment methods" do
    projection =
      complete_projection()
      |> replace_text(
        "◇ 계약 금액 : 금 팔천팔백만원정(￦88,000,000원)(부가가치세 포함)",
        "◇ 계약 금액 : 금 88,000,000원정(￦ 88,000,000)(부가가치세 포함)"
      )
      |> replace_text(
        "◇ 성과물의 작성 개시예정일로부터 최소 (미기재)일 이전까지 교부",
        "◇ 성과물의 작성 개시예정일로부터 최소 미기재일 이전까지 교부"
      )
      |> replace_text(
        "사. 계약이행보증금요율 : 계약금액의 (미기재)%",
        "사. 계약이행보증금요율 : 계약금액의 미기재%"
      )
      |> replace_text(
        "하. 계약갱신 여부에 대한 최고기한 : 미기재",
        "하. 계약갱신 여부에 대한 최고기한 : 미기재까지"
      )
      |> replace_text(
        "거. 이행거절을 위한 기성금 등의 미지급 횟수 : 미기재 회 미지급",
        "거. 이행거절을 위한 기성금 등의 미지급 횟수 : 미기재회 미지급"
      )
      |> update_table_block(
        ["구분", "비율", "지급금액", "지급기일", "지급방법"],
        fn block ->
          Enum.map(block, fn
            %{"type" => "paragraph", "text" => "미기재"} = paragraph ->
              %{paragraph | "text" => "현금"}

            payload ->
              payload
          end)
        end
      )

    assert {:error, issues} = validate_projection(projection)

    for id <-
          ~w(contract_amount instruction_lead performance_bond renewal_deadline withholding_count payment_table) do
      assert Enum.any?(issues, &(&1.id == id)), "expected #{id} to fail"
    end
  end

  test "party table values cannot substitute for the front-matter intro or signing date" do
    projection =
      complete_projection()
      |> replace_text(
        @intro,
        "---------------(이하 ‘원사업자’)와 ------------(이하 ‘수급사업자’)는(은) 신의에 따라 성실히 계약상의 권리를 행사한다."
      )
      |> replace_text("2026년 7월 20일", "년 월 일", occurrence: 1)

    assert {:error, issues} = validate_projection(projection)
    assert Enum.any?(issues, &(&1.id == "party_intro"))
    assert Enum.any?(issues, &(&1.id == "signing_date"))
  end

  test "fails wrong payment cells and a missing or mislabeled 4x4 schedule" do
    wrong_payment = replace_text(complete_projection(), "35,200,000원", "3,520,000원")
    assert {:error, issues} = validate_projection(wrong_payment)
    assert Enum.any?(issues, &(&1.id == "payment_table"))

    wrong_schedule = replace_text(complete_projection(), "산출물", "수행 내용")
    assert {:error, issues} = validate_projection(wrong_schedule)

    assert Enum.any?(issues, fn issue ->
             issue.id == "performance_payment_schedule" and issue.reason == :missing_table
           end)
  end

  test "rejects a duplicate schedule even when both copies are exact" do
    duplicate = insert_before_annex(complete_projection(), schedule_table())

    assert {:error, issues} = validate_projection(duplicate)

    assert Enum.any?(issues, fn issue ->
             issue.id == "performance_payment_schedule" and issue.reason == :duplicate_table
           end)
  end

  test "rejects a second schedule candidate even when its body is malformed" do
    malformed_duplicate =
      insert_before_text(
        complete_projection(),
        "◇ 원재료의 공급일 : 미기재",
        expanded_table([
          ["단계", "산출물", "지급 시점", "금액"],
          ["착수", "잘못된 산출물", "미기재", "0원"]
        ])
      )

    assert {:error, issues} =
             validate_projection(malformed_duplicate)

    assert Enum.any?(issues, fn issue ->
             issue.id == "performance_payment_schedule" and issue.reason == :duplicate_table and
               issue.detail.count == 2
           end)
  end

  test "rejects a second payment-table candidate even when its body is malformed" do
    malformed_duplicate =
      insert_before_text(
        complete_projection(),
        "◇ 원재료의 공급일 : 미기재",
        expanded_table([
          ["구분", "비율", "지급금액", "지급기일", "지급방법"],
          ["선급금", "99.0%", "0원", "미기재", "미기재"]
        ])
      )

    assert {:error, issues} = validate_projection(malformed_duplicate)

    assert Enum.any?(issues, fn issue ->
             issue.id == "payment_table" and issue.reason == :duplicate_table and
               issue.detail.count == 2
           end)
  end

  test "rejects any additional 4x4 schedule in the body-end region despite header edits" do
    reordered_mistyped_schedule =
      expanded_table([
        ["금액", "수행 단계", "지급시점 오기", "산출 문서"],
        ["0원", "착수", "미기재", "잘못된 산출물"],
        ["0원", "중간", "미기재", "잘못된 산출물"],
        ["0원", "완료", "미기재", "잘못된 산출물"]
      ])

    for placement <- [:same_block, :next_block] do
      projection =
        update_in(complete_projection(), [Access.at(0)], fn blocks ->
          case placement do
            :same_block ->
              Enum.map(blocks, fn block ->
                if Enum.any?(block, &match?(%{"type" => "paragraph", "text" => @body_text}, &1)),
                  do: block ++ reordered_mistyped_schedule,
                  else: block
              end)

            :next_block ->
              annex_index = Enum.find_index(blocks, &(&1 == paragraph("【별첨】")))
              List.insert_at(blocks, annex_index, reordered_mistyped_schedule)
          end
        end)

      assert {:error, issues} = validate_projection(projection)

      assert Enum.any?(issues, fn issue ->
               issue.id == "contract_body_end" and
                 issue.reason == :duplicate_body_end_schedule and issue.detail.count == 2
             end)
    end
  end

  test "allows an unrelated 4x4 table after the annex boundary" do
    unrelated_annex =
      expanded_table([
        ["담당", "연락처", "비고", "상태"],
        ["A", "1", "-", "예정"],
        ["B", "2", "-", "예정"],
        ["C", "3", "-", "예정"]
      ])

    projection =
      update_in(complete_projection(), [Access.at(0)], &(&1 ++ [unrelated_annex]))

    assert :ok = validate_projection(projection)
  end

  test "excludes an exact schedule-shaped table in an optional annex" do
    optional_annex_schedule =
      update_in(complete_projection(), [Access.at(0)], &(&1 ++ [schedule_table()]))

    assert :ok = validate_projection(optional_annex_schedule)
  end

  test "requires the primary arbitration slot and preserves rate and unit labels" do
    missing_arbitrator = complete_projection(arbitrator: "")
    assert {:error, issues} = validate_projection(missing_arbitrator)
    assert Enum.any?(issues, &(&1.id == "arbitrator"))

    destructive_rate =
      replace_text(
        complete_projection(),
        "사. 계약이행보증금요율 : 계약금액의 (미기재)%",
        "사. 계약이행보증금요율 : 미기재"
      )

    assert {:error, issues} = validate_projection(destructive_rate)
    assert Enum.any?(issues, &(&1.id == "performance_bond"))
  end

  @tag :edit_failure
  test "requires one native-positioned overlay intersecting the exact recipient marker" do
    for {mode, reason} <- [
          {:none, :picture_count_mismatch},
          {:duplicate, :picture_count_mismatch},
          {:principal, :picture_spatial_mismatch},
          {:inline, :picture_properties_mismatch},
          {:wrong_wrap, :picture_properties_mismatch},
          {:overlap_disabled, :picture_properties_mismatch},
          {:wrong_spatial, :picture_spatial_mismatch},
          {:covering, :picture_spatial_mismatch},
          {:barely_overlapping, :picture_spatial_mismatch},
          {:distorted, :picture_spatial_mismatch},
          {:near_boundary_fail, :picture_spatial_mismatch}
        ] do
      assert {:error, issues} =
               validate_projection(complete_projection(signature: mode))

      assert Enum.any?(issues, fn issue ->
               issue.id == "recipient_signature" and issue.reason == reason
             end)
    end

    assert :ok = validate_projection(complete_projection(signature: :near_boundary_pass))
  end

  test "accepts the exact live marker-centered 5000x1208 signature placement" do
    picture = signature_picture(:recipient)

    assert Map.take(picture, ~w(horzOffset vertOffset width height)) == %{
             "horzOffset" => 40_854,
             "vertOffset" => 35_047,
             "width" => 5_000,
             "height" => 1_208
           }

    assert_in_delta picture["width"] / 75 / (@marker_geometry.right - @marker_geometry.left),
                    3.072,
                    0.001

    assert_in_delta picture["height"] / 75 / (@marker_geometry.bottom - @marker_geometry.top),
                    1.211,
                    0.001

    assert :ok = validate_projection(complete_projection())
  end

  test "reports which marker-relative signature constraints failed" do
    assert {:error, issues} = validate_projection(complete_projection(signature: :covering))

    assert %{detail: [%{failed: failed}]} =
             Enum.find(issues, &(&1.id == "recipient_signature"))

    assert :width_ratio in failed
    assert :height_ratio in failed
    assert :aspect_ratio in failed
  end

  test "semantic whitelist accepts only the exact brief changes from pristine" do
    pristine = pristine_projection()
    completed = complete_projection()

    assert :ok =
             ProjectionAudit.validate_standard_contract_semantic_diff(pristine, completed)

    preserved_extra = paragraph("보존해야 하는 원문")

    assert :ok =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               insert_before_annex(pristine, preserved_extra),
               insert_before_annex(completed, preserved_extra)
             )
  end

  test "semantic whitelist accepts the native empty anchor owned by the inserted schedule" do
    native_anchor = [
      %{
        "type" => "paragraph",
        "text" => "",
        "paraShapeId" => 89,
        "styleId" => 0,
        "alignment" => "justify"
      }
    ]

    completed = move_schedule_to_next_block(complete_projection(), native_anchor)

    assert :ok =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine_projection(),
               completed
             )

    native_with_trailing_anchors =
      completed
      |> insert_before_annex(native_anchor)
      |> insert_before_annex(native_anchor)

    assert :ok =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine_projection(),
               native_with_trailing_anchors
             )

    unrelated_anchor = insert_before_annex(complete_projection(), native_anchor)

    assert {:error, [%{reason: :unapproved_semantic_sequence}]} =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine_projection(),
               unrelated_anchor
             )
  end

  test "native body-end paragraphs remain ordered and immediately precede the schedule" do
    completed = native_body_end_projection(complete_projection())

    assert :ok = validate_projection(completed)

    assert :ok =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine_projection(),
               completed
             )
  end

  test "native body-end accepts ref-less inserted paragraphs beside a styled source clause" do
    pristine =
      update_paragraph(
        pristine_projection(),
        @pristine_jurisdiction,
        &Map.merge(&1, %{"paraShapeId" => 89, "styleId" => 0, "alignment" => "justify"})
      )

    completed =
      complete_projection()
      |> native_body_end_projection()
      |> update_paragraph(
        @jurisdiction,
        &Map.merge(&1, %{"paraShapeId" => 89, "styleId" => 0, "alignment" => "justify"})
      )

    assert :ok =
             ProjectionAudit.validate_standard_contract_semantic_diff(pristine, completed)
  end

  test "semantic whitelist permits the brief date in repeated attachment signature dates" do
    assert :ok =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine_projection(),
               complete_projection()
             )
  end

  test "semantic whitelist permits the brief values in the direct-payment summary" do
    pristine_summary =
      expanded_table([
        ["원 도 급 계약사항", "원 도 급 계 약 명(名)", "", ""],
        ["", "최 초 계 약 금 액", "", ""],
        ["", "계 약 기 간", "", ""],
        ["하 도 급 계약사항", "하 도 급 계 약 명(名)", "", ""],
        ["", "최 초 계 약 금 액", "", ""],
        ["", "계 약 기 간", "", ""],
        ["", "원사업자", "상호 와 대표자", ""],
        ["", "", "주 소", ""],
        ["", "수급사업자", "상호 와 대표자", ""],
        ["", "", "주 소", ""]
      ])

    completed_summary =
      expanded_table([
        ["원 도 급 계약사항", "원 도 급 계 약 명(名)", "", "웹 서비스 접근성 개선 용역"],
        ["", "최 초 계 약 금 액", "", "88,000,000원"],
        ["", "계 약 기 간", "", "2026년 7월 20일부터 2026년 10월 31일까지"],
        ["하 도 급 계약사항", "하 도 급 계 약 명(名)", "", "웹 서비스 접근성 개선 용역"],
        ["", "최 초 계 약 금 액", "", "88,000,000원"],
        ["", "계 약 기 간", "", "2026년 7월 20일부터 2026년 10월 31일까지"],
        ["", "원사업자", "상호 와 대표자", "주식회사 블루버드 디자인랩 / 이서준"],
        ["", "", "주 소", "미기재"],
        ["", "수급사업자", "상호 와 대표자", "주식회사 에크리츠 / 김에크리츠"],
        ["", "", "주 소", "미기재"]
      ])

    assert :ok =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               insert_before_annex(pristine_projection(), pristine_summary),
               insert_before_annex(complete_projection(), completed_summary)
             )
  end

  test "semantic whitelist rejects invented or deleted unrelated content" do
    invented = insert_before_annex(complete_projection(), paragraph("합의되지 않은 현금 지급"))

    assert {:error, invented_issues} =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine_projection(),
               invented
             )

    assert Enum.any?(invented_issues, &(&1.reason == :unapproved_semantic_sequence))

    preserved_extra = paragraph("삭제하면 안 되는 원문")
    pristine = insert_before_annex(pristine_projection(), preserved_extra)

    assert {:error, deleted_issues} =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine,
               complete_projection()
             )

    assert Enum.any?(deleted_issues, &(&1.reason == :unapproved_semantic_sequence))

    invented_table =
      insert_before_annex(
        complete_projection(),
        expanded_table([["임의", "내용"], ["현금", "추가"]])
      )

    assert {:error, table_issues} =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine_projection(),
               invented_table
             )

    assert Enum.any?(table_issues, &(&1.reason == :unapproved_semantic_sequence))

    trailing_compact_paragraph =
      update_in(complete_projection(schedule: :compact), [Access.at(0)], fn blocks ->
        Enum.map(blocks, fn block ->
          if Enum.any?(block, &match?(%{"type" => "paragraph", "text" => @body_text}, &1)),
            do: block ++ paragraph("표 뒤에 숨긴 임의 내용"),
            else: block
        end)
      end)

    assert {:error, compact_issues} =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine_projection(),
               trailing_compact_paragraph
             )

    assert Enum.any?(compact_issues, &(&1.reason == :unapproved_semantic_sequence))
  end

  test "semantic table replacements allow engine-derived cell height reflow" do
    pristine = put_arbitrator_value_cell_height(pristine_projection(), 282)
    completed = put_arbitrator_value_cell_height(complete_projection(), 1_282)

    assert :ok =
             ProjectionAudit.validate_standard_contract_semantic_diff(pristine, completed)

    damaged = put_arbitrator_value_cell_height(complete_projection(), 9_999)

    assert {:error, issues} =
             ProjectionAudit.validate_standard_contract_semantic_diff(pristine, damaged)

    assert Enum.any?(issues, &(&1.reason == :unapproved_semantic_sequence))
  end

  test "ordered semantic whitelist rejects clause and required-table relocation" do
    reordered_clauses =
      swap_blocks(
        complete_projection(),
        &block_has_text?(&1, "◇ 계약명 : 웹 서비스 접근성 개선 용역"),
        &block_has_text?(&1, "◇ 계약기간 : 2026년 7월 20일부터 2026년 10월 31일까지")
      )

    relocated_payment =
      move_block_after(
        complete_projection(),
        &block_has_table_headers?(&1, ["구분", "비율", "지급금액", "지급기일", "지급방법"]),
        &block_has_text?(&1, "◇ 원재료의 공급일 : 미기재")
      )

    swapped_party_and_arbitrator =
      swap_blocks(
        complete_projection(),
        &block_has_table_headers?(&1, ["원사업자", "수급사업자"]),
        &block_has_table_headers?(&1, ["중재인 또는 중재기관", "미기재"])
      )

    for damaged <- [reordered_clauses, relocated_payment, swapped_party_and_arbitrator] do
      assert {:error, issues} =
               ProjectionAudit.validate_standard_contract_semantic_diff(
                 pristine_projection(),
                 damaged
               )

      assert Enum.any?(issues, &(&1.reason == :unapproved_semantic_sequence))
    end
  end

  test "expanded-table trailing paragraphs belong to the last cell and are rejected" do
    unrelated = expanded_table([["보존 표", "값"], ["A", "B"]])
    pristine = insert_before_annex(pristine_projection(), unrelated)
    completed = insert_before_annex(complete_projection(), unrelated)

    damaged =
      update_in(completed, [Access.at(0)], fn blocks ->
        Enum.map(blocks, fn block ->
          if block_has_table_headers?(block, ["보존 표", "값"]),
            do: block ++ paragraph("마지막 셀 뒤에 숨긴 내용"),
            else: block
        end)
      end)

    assert {:error, [%{reason: :unapproved_semantic_sequence, detail: detail}]} =
             ProjectionAudit.validate_standard_contract_semantic_diff(pristine, damaged)

    assert detail.final.kind == :table
    assert List.last(List.last(detail.final.matrix)) == "B 마지막 셀 뒤에 숨긴 내용"
  end

  test "semantic tokens allow ref and edited char mirrors but reject char or shape mutations" do
    pristine =
      pristine_projection()
      |> replace_block_with_char_mirror("◇ 계약명 :", "old-ref", 900)
      |> insert_before_annex([
        %{"type" => "paragraph", "text" => "보존 문단"},
        %{"type" => "char", "text" => "보존 문단", "fontSize" => 1_000, "ref" => "old"}
      ])

    completed =
      complete_projection()
      |> replace_block_with_char_mirror(
        "◇ 계약명 : 웹 서비스 접근성 개선 용역",
        "new-ref",
        1_100
      )
      |> insert_before_annex([
        %{"type" => "paragraph", "text" => "보존 문단"},
        %{"type" => "char", "text" => "보존 문단", "fontSize" => 1_000, "ref" => "new"}
      ])

    assert :ok =
             ProjectionAudit.validate_standard_contract_semantic_diff(pristine, completed)

    tampered_char =
      replace_block_with_char_mirror(completed, "보존 문단", "new", 1_000, "변조된 문자")

    assert {:error, char_issues} =
             ProjectionAudit.validate_standard_contract_semantic_diff(pristine, tampered_char)

    assert Enum.any?(char_issues, &(&1.reason == :unapproved_semantic_sequence))

    shape_added =
      insert_before_annex(completed, [
        %{"type" => "shape", "shapeType" => "rectangle", "width" => 10, "height" => 10}
      ])

    assert {:error, shape_issues} =
             ProjectionAudit.validate_standard_contract_semantic_diff(pristine, shape_added)

    assert Enum.any?(shape_issues, &(&1.reason == :unapproved_semantic_sequence))
  end

  test "semantic whitelist requires all five party replacements and the signature after the first" do
    assert :ok =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine_projection(),
               complete_projection()
             )

    omitted = drop_party_table_occurrence(complete_projection(), 5)

    assert {:error, omitted_issues} =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine_projection(),
               omitted
             )

    assert Enum.any?(omitted_issues, &(&1.reason == :unapproved_semantic_sequence))

    wrong_occurrence = complete_projection(signature_occurrence: 2)

    assert {:error, signature_issues} =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine_projection(),
               wrong_occurrence
             )

    assert Enum.any?(signature_issues, &(&1.reason == :unapproved_semantic_sequence))

    extra_mutation =
      replace_text(
        complete_projection(),
        "상호 또는 명칭 : 주식회사 에크리츠",
        "상호 또는 명칭 : 주식회사 에크리츠 변경",
        occurrence: 5
      )

    assert {:error, mutation_issues} =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine_projection(),
               extra_mutation
             )

    assert Enum.any?(mutation_issues, &(&1.reason == :unapproved_semantic_sequence))
  end

  test "preserves the source party table that has no telephone paragraph" do
    pristine = drop_party_telephone_occurrence(pristine_projection(), 3)
    completed = drop_party_telephone_occurrence(complete_projection(), 3)

    assert :ok = validate_projection(completed)

    assert :ok =
             ProjectionAudit.validate_standard_contract_semantic_diff(pristine, completed)

    assert {:error, invented_issues} =
             ProjectionAudit.validate_standard_contract_semantic_diff(
               pristine,
               complete_projection()
             )

    assert Enum.any?(invented_issues, &(&1.reason == :unapproved_semantic_sequence))
  end

  test "rejects malformed 5x5 payment candidates regardless of header damage" do
    damaged_headers = [
      ["구분", "", "지급금액", "지급기일", "지급방법"],
      ["구분", "비율", "지급 금액", "지급기일", "지급방법"],
      ["비율", "구분", "지급금액", "지급기일", "지급방법"]
    ]

    for headers <- damaged_headers do
      malformed =
        expanded_table([
          headers,
          ["A", "B", "C", "D", "E"],
          ["A", "B", "C", "D", "E"],
          ["A", "B", "C", "D", "E"],
          ["A", "B", "C", "D", "E"]
        ])

      projection =
        insert_before_text(
          complete_projection(),
          "◇ 원재료의 공급일 : 미기재",
          malformed
        )

      assert {:error, issues} = validate_projection(projection)

      assert Enum.any?(issues, fn issue ->
               issue.id == "payment_table" and issue.reason == :duplicate_table and
                 issue.detail.count == 2
             end)
    end
  end

  test "rejects duplicate and missing expanded-table cell coordinates" do
    legitimate_merged_total =
      update_table_block(
        complete_projection(),
        ["구분", "비율", "지급금액", "지급기일", "지급방법"],
        fn block ->
          block
          |> remove_expanded_cell({4, 4})
          |> remove_expanded_cell({4, 3})
        end
      )

    assert :ok = validate_projection(legitimate_merged_total)

    duplicate =
      update_table_block(complete_projection(), ["구분", "비율", "지급금액", "지급기일", "지급방법"], fn block ->
        block ++ [%{"type" => "cell", "row" => 0, "col" => 0}] ++ paragraph("구분")
      end)

    missing =
      update_table_block(complete_projection(), ["구분", "비율", "지급금액", "지급기일", "지급방법"], fn block ->
        remove_expanded_cell(block, {3, 4})
      end)

    for damaged <- [duplicate, missing] do
      assert {:error, issues} = validate_projection(damaged)

      assert Enum.any?(issues, fn issue ->
               issue.id == "payment_table" and issue.reason == :invalid_table_coordinates
             end)
    end
  end

  test "saved demo validator exposes no baseline-free arity" do
    assert Code.ensure_loaded?(ProjectionAudit)
    refute function_exported?(ProjectionAudit, :validate_standard_contract_demo, 3)
    assert function_exported?(ProjectionAudit, :validate_standard_contract_demo, 4)
  end

  test "rejects an extra differently-propped picture anywhere in the projection" do
    extra_picture =
      signature_picture(:recipient)
      |> Map.put("horzAlign", "Center")
      |> Map.put("width", 9000)

    projection =
      update_in(complete_projection(), [Access.at(0)], fn blocks ->
        blocks ++ [[extra_picture]]
      end)

    assert {:error, issues} = validate_projection(projection)

    assert Enum.any?(issues, fn issue ->
             issue.id == "recipient_signature" and
               issue.reason == :global_picture_count_mismatch and
               issue.detail == %{expected: 2, actual: 3}
           end)
  end

  test "pairs projection placement with exactly one real BinData SHA-256 match" do
    root =
      Path.join(System.tmp_dir!(), "projection-audit-hash-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    document = Path.join(root, "contract.hwp")
    image = Path.join(root, "signature.png")
    extractor = Path.join(root, "hwp5proc")
    File.write!(document, "fake container")
    File.write!(image, "original-image-bytes")

    File.write!(extractor, """
    #!/bin/sh
    if [ "$1" = "ls" ]; then
      printf 'BinData/BIN0001.bmp\\nBinData/BIN0002.png\\n'
    elif [ "$1" = "cat" ] && [ "$3" = "BinData/BIN0002.png" ]; then
      printf 'original-image-bytes'
    else
      printf 'different-bytes'
    fi
    """)

    File.chmod!(extractor, 0o755)
    on_exit(fn -> File.rm_rf(root) end)

    assert :ok =
             ProjectionAudit.validate_embedded_image_hash(document, image, executable: extractor)

    File.write!(image, "derivative-bytes")

    assert {:error, [%{reason: :embedded_image_hash_count_mismatch}]} =
             ProjectionAudit.validate_embedded_image_hash(document, image, executable: extractor)

    File.write!(image, "original-image-bytes")

    File.write!(extractor, """
    #!/bin/sh
    if [ "$1" = "ls" ]; then
      printf 'BinData/BIN0002.png\\nBinData/BIN0003.unexpected\\n'
    elif [ "$1" = "cat" ]; then
      printf 'original-image-bytes'
    fi
    """)

    assert {:error,
            [
              %{
                reason: :embedded_image_hash_count_mismatch,
                detail: %{expected: 1, actual: 2}
              }
            ]} =
             ProjectionAudit.validate_embedded_image_hash(document, image, executable: extractor)
  end

  test "production demo validation runs native marker geometry and supplied image hash together" do
    if Ehwp.available?() do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection-audit-demo-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      document = Path.join(root, "native-target.hwp")
      image = Path.join(root, "signature.png")
      extractor = Path.join(root, "hwp5proc")
      File.write!(image, "original-image-bytes")
      write_native_target_document(document)

      File.write!(extractor, """
      #!/bin/sh
      if [ "$1" = "ls" ]; then
        printf 'BinData/BIN0001.png\\n'
      elif [ "$1" = "cat" ]; then
        printf 'original-image-bytes'
      fi
      """)

      File.chmod!(extractor, 0o755)
      on_exit(fn -> File.rm_rf(root) end)
      marker_geometry = native_marker_geometry(document)
      completed = complete_projection(signature: {:geometry, marker_geometry})

      assert {:error, missing_baseline_issues} =
               ProjectionAudit.validate_standard_contract_demo(
                 completed,
                 document,
                 image,
                 executable: extractor
               )

      assert Enum.any?(
               missing_baseline_issues,
               &(&1.reason == :pristine_projection_missing)
             )

      assert :ok =
               ProjectionAudit.validate_standard_contract_demo(
                 completed,
                 document,
                 image,
                 executable: extractor,
                 pristine_projection: pristine_projection()
               )

      File.write!(image, "different-image-bytes")

      assert {:error, issues} =
               ProjectionAudit.validate_standard_contract_demo(
                 completed,
                 document,
                 image,
                 executable: extractor,
                 pristine_projection: pristine_projection()
               )

      assert Enum.any?(issues, &(&1.reason == :embedded_image_hash_count_mismatch))
    else
      IO.puts("\n[skip] ehwp NIF unavailable; skipping native demo validation proof")
    end
  end

  test "production demo validation uses the configured native marker occurrence" do
    if Ehwp.available?() do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection-audit-occurrence-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      document = Path.join(root, "repeated-native-target.hwp")
      image = Path.join(root, "signature.png")
      extractor = Path.join(root, "hwp5proc")
      File.write!(image, "original-image-bytes")
      write_native_target_document(document, 5)

      File.write!(extractor, """
      #!/bin/sh
      if [ "$1" = "ls" ]; then
        printf 'BinData/BIN0001.png\\n'
      elif [ "$1" = "cat" ]; then
        printf 'original-image-bytes'
      fi
      """)

      File.chmod!(extractor, 0o755)
      on_exit(fn -> File.rm_rf(root) end)
      marker_geometry = native_marker_geometry(document, occurrence: 1)
      completed = complete_projection(signature: {:geometry, marker_geometry})

      assert :ok =
               ProjectionAudit.validate_standard_contract_demo(
                 completed,
                 document,
                 image,
                 executable: extractor,
                 pristine_projection: pristine_projection()
               )
    else
      IO.puts("\n[skip] ehwp NIF unavailable; skipping native occurrence proof")
    end
  end

  test "a pristine HWPX projection survives ACP write-back and disk reprojection" do
    if ehwp_available?(@hwpx_fixture) do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection-audit-roundtrip-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      document = Path.join(root, "contract.hwpx")
      File.cp!(@hwpx_fixture, document)

      on_exit(fn ->
        Pool.close_by_path(document)
        File.rm_rf(root)
      end)

      old_text = "산업통상자원부 고시 제2020 - 93호"
      new_text = "산업통상자원부 고시 제2020 - 94호"

      assert {:ok, pristine_bytes} = Projection.project_file(document)
      assert ProjectionAudit.exact_paragraph_count(pristine_bytes, old_text) == 1

      pristine = pristine_bytes |> projection_json() |> Jason.decode!()
      edited = replace_text(pristine, old_text, new_text)

      assert {:ok, %{applied: applied}} =
               Projection.write_back(document, Jason.encode!(edited) <> "\n")

      assert applied > 0

      Pool.close_by_path(document)
      assert {:ok, saved_bytes} = Projection.project_file(document)
      assert ProjectionAudit.exact_paragraph_count(saved_bytes, old_text) == 0
      assert ProjectionAudit.exact_paragraph_count(saved_bytes, new_text) == 1
    else
      IO.puts("\n[skip] ehwp NIF unavailable; skipping ACP projection round-trip proof")
    end
  end

  test "counts only exact committed signature paragraphs" do
    projection = complete_projection()

    assert ProjectionAudit.exact_paragraph_count(
             projection,
             "대표자 성명 : 김에크리츠 (인)"
           ) == 5

    assert ProjectionAudit.exact_paragraph_count(projection, "김에크리츠") == 0
  end

  defp validate_projection(projection) do
    ProjectionAudit.validate_standard_contract_projection(projection, @marker_geometry)
  end

  defp complete_projection(opts \\ []) do
    signature = Keyword.get(opts, :signature, :recipient)
    signature_occurrence = Keyword.get(opts, :signature_occurrence, 1)
    schedule = Keyword.get(opts, :schedule, :expanded)
    arbitrator = Keyword.get(opts, :arbitrator, "미기재")

    before_parties =
      [
        baseline_picture_block(),
        paragraph("◇ 계약명 : 웹 서비스 접근성 개선 용역"),
        paragraph("◇ 계약기간 : 2026년 7월 20일부터 2026년 10월 31일까지"),
        paragraph("◇ 계약 금액 : 금 팔천팔백만원정(￦88,000,000원)(부가가치세 포함)"),
        payment_table(),
        paragraph("◇ 원재료의 공급일 : 미기재"),
        paragraph("◇ 원재료의 공급장소 : 미기재"),
        paragraph("◇ 교부일 : 미기재"),
        paragraph("◇ 성과물의 작성 개시예정일로부터 최소 (미기재)일 이전까지 교부"),
        paragraph("◇ 납품일자 : 미기재"),
        paragraph("◇ 납품장소 : 미기재"),
        paragraph("사. 계약이행보증금요율 : 계약금액의 (미기재)%"),
        paragraph("아. 대금지급보증금요율 : 계약금액의 (미기재)%"),
        paragraph("◇ 지연이자요율(대금 지급 지연) : 연 (미기재)%"),
        paragraph("◇ 기타 지연이자요율 : 연 (미기재)%"),
        paragraph("차. 지체상금요율 : 지체일당 계약금액의 (미기재)/1,000"),
        paragraph("카. 하자담보책임기간 : 성과물을 납품한 날로부터 (미기재)년"),
        paragraph("◇ 연동제 적용대상 없음 (미기재)"),
        paragraph("◇ 적용함 : (미기재) 【하도급대금 연동 계약서】"),
        paragraph("◇ 일부 적용함 : (미기재) 【하도급대금 연동 계약서】 및 【하도급대금 미연동 계약서】"),
        paragraph("◇ 전부 적용하지 않음 : (미기재) 【하도급대금 미연동 계약서】"),
        paragraph("하. 계약갱신 여부에 대한 최고기한 : 미기재"),
        paragraph("거. 이행거절을 위한 기성금 등의 미지급 횟수 : 미기재 회 미지급"),
        paragraph(@intro),
        paragraph("2026년 7월 20일")
      ]

    after_parties =
      [
        arbitration_table(arbitrator),
        body_end_block(schedule),
        paragraph("【별첨】")
      ]

    [before_parties ++ completed_party_blocks(signature, signature_occurrence) ++ after_parties]
  end

  defp pristine_projection do
    before_parties =
      [
        baseline_picture_block(),
        paragraph("◇ 계약명 :"),
        paragraph("◇ 계약기간 : 년 월 일부터 년 월 일까지"),
        paragraph("◇ 계약 금액 : 금 원정(￦ )(부가가치세 포함)"),
        pristine_payment_table(),
        paragraph("◇ 원재료의 공급일 : 년 월 일[또는 매월 ( )일]"),
        paragraph("◇ 원재료의 공급장소 :"),
        paragraph("◇ 교부일 : 년 월 일"),
        paragraph("◇ 성과물의 작성 개시예정일로부터 최소 ( )일 이전까지 교부"),
        paragraph("◇ 납품일자 : 년 월 일 또는 매월 ( )일"),
        paragraph("◇ 납품장소 :"),
        paragraph("사. 계약이행보증금요율 : 계약금액의 ( )%"),
        paragraph("아. 대금지급보증금요율 : 계약금액의 ( )%"),
        paragraph("◇ 지연이자요율(대금 지급 지연) : 연 ( )%"),
        paragraph("◇ 기타 지연이자요율 : 연 ( )%"),
        paragraph("차. 지체상금요율 : 지체일당 계약금액의 ( )/1,000"),
        paragraph("카. 하자담보책임기간 : 성과물을 납품한 날로부터 ( )년"),
        paragraph("◇ 연동제 적용대상 없음 ( )"),
        paragraph("◇ 적용함 : ( ) 【하도급대금 연동 계약서】"),
        paragraph("◇ 일부 적용함 : ( ) 【하도급대금 연동 계약서】 및 【하도급대금 미연동 계약서】"),
        paragraph("◇ 전부 적용하지 않음 : ( ) 【하도급대금 미연동 계약서】"),
        paragraph("하. 계약갱신 여부에 대한 최고기한 : 년 월 일까지"),
        paragraph("거. 이행거절을 위한 기성금 등의 미지급 횟수 : 회 미지급"),
        paragraph(@pristine_intro),
        paragraph("년 월 일")
      ]

    after_parties =
      [
        arbitration_table(""),
        [
          %{"type" => "paragraph", "text" => @pristine_jurisdiction},
          %{"type" => "char", "text" => @pristine_jurisdiction}
        ],
        paragraph("【별첨】")
      ]

    [before_parties ++ pristine_party_blocks() ++ after_parties]
  end

  defp pristine_payment_table do
    expanded_table([
      ["구분", "비율", "지급금액", "지급기일", "지급방법"],
      ["선급금", "%", "", "", ""],
      ["중도금 또는 기성금\n(지급회수: 회)", "%", "", "", ""],
      ["잔 금", "%", "", "", ""],
      ["합계", "100.0%", "", "", ""]
    ])
  end

  defp pristine_party_table do
    expanded_table([
      ["원사업자", "수급사업자"],
      [
        "상호 또는 명칭 :\n전화번호 :\n주 소 :\n대표자 성명 : (인)\n사업자(법인)번호 :",
        "상호 또는 명칭 :\n전화번호 :\n주 소 :\n대표자 성명 : (인)\n사업자(법인)번호 :"
      ]
    ])
  end

  defp baseline_picture_block do
    [
      %{"type" => "paragraph", "text" => ""},
      %{
        "type" => "picture",
        "ref" => %{"type" => "picture", "id" => "pristine-cover-picture"},
        "description" => "preserved source picture",
        "treatAsChar" => false,
        "horzOffset" => 37_129,
        "vertOffset" => 123,
        "width" => 10_172,
        "height" => 7_396
      }
    ]
  end

  defp payment_table do
    expanded_table([
      ["구분", "비율", "지급금액", "지급기일", "지급방법"],
      ["선급금", "30.0%", "26,400,000원", "계약 체결 후 5영업일 이내", "미기재"],
      [
        "중도금 또는 기성금\n(지급회수: 1회)",
        "40.0%",
        "35,200,000원",
        "중간 산출물 승인 후",
        "미기재"
      ],
      ["잔 금", "30.0%", "26,400,000원", "최종 검수 완료 후", "미기재"],
      ["합계", "100.0%", "88,000,000원", "", ""]
    ])
  end

  defp party_table(signature) do
    table =
      expanded_table([
        ["원사업자", "수급사업자"],
        [
          "상호 또는 명칭 : 주식회사 블루버드 디자인랩\n전화번호 : 미기재\n주 소 : 미기재\n대표자 성명 : 이서준 (인)\n사업자(법인)번호 : 미기재",
          "상호 또는 명칭 : 주식회사 에크리츠\n전화번호 : 미기재\n주 소 : 미기재\n대표자 성명 : 김에크리츠 (인)\n사업자(법인)번호 : 미기재"
        ]
      ])

    {payloads, _cell} =
      Enum.map_reduce(table, nil, fn
        %{"type" => "cell", "row" => row, "col" => col} = cell, _current ->
          {[cell], {row, col}}

        %{"type" => "paragraph", "text" => text} = paragraph, {1, col} = current ->
          insert? =
            case signature do
              :none ->
                false

              :principal ->
                col == 0 and text == "대표자 성명 : 이서준 (인)"

              _other ->
                col == 1 and text == "대표자 성명 : 김에크리츠 (인)"
            end

          pictures =
            cond do
              not insert? ->
                []

              signature == :duplicate ->
                [signature_picture(signature), signature_picture(signature)]

              true ->
                [signature_picture(signature)]
            end

          {[paragraph | pictures], current}

        payload, current ->
          {[payload], current}
      end)

    List.flatten(payloads)
  end

  defp party_tables(signature, signature_occurrence) do
    Enum.map(1..5, fn occurrence ->
      party_table(if(occurrence == signature_occurrence, do: signature, else: :none))
    end)
  end

  defp completed_party_blocks(signature, signature_occurrence) do
    [first | rest] = party_tables(signature, signature_occurrence)
    date = paragraph("2026년 7월 20일")

    [
      first,
      date,
      Enum.at(rest, 0),
      date,
      date,
      Enum.at(rest, 1),
      date,
      Enum.at(rest, 2),
      date,
      Enum.at(rest, 3)
    ]
  end

  defp pristine_party_blocks do
    table = pristine_party_table()

    [
      table,
      paragraph("20____년 ____월 ____일"),
      table,
      paragraph("년 월 일"),
      paragraph("년 월 일"),
      table,
      paragraph("년 월 일"),
      table,
      paragraph("년 월 일"),
      table
    ]
  end

  defp drop_party_telephone_occurrence([blocks], occurrence) do
    {blocks, _seen} =
      Enum.map_reduce(blocks, 0, fn block, seen ->
        texts = Enum.map(block, &Map.get(&1, "text"))

        if "원사업자" in texts and "수급사업자" in texts do
          seen = seen + 1

          block =
            if seen == occurrence do
              Enum.reject(block, fn node ->
                Map.get(node, "type") == "paragraph" and
                  String.starts_with?(Map.get(node, "text", ""), "전화번호")
              end)
            else
              block
            end

          {block, seen}
        else
          {block, seen}
        end
      end)

    [blocks]
  end

  defp signature_picture({:geometry, marker}) do
    picture_width = 5_000 / 75
    picture_height = 1_208 / 75
    marker_center_x = (marker.left + marker.right) / 2
    marker_center_y = (marker.top + marker.bottom) / 2

    %{
      "type" => "picture",
      "ref" => %{"type" => "picture", "id" => "synthetic-ref"},
      "treatAsChar" => false,
      "horzRelTo" => "Paper",
      "vertRelTo" => "Paper",
      "horzAlign" => "Left",
      "vertAlign" => "Top",
      "horzOffset" => round((marker_center_x - picture_width / 2) * 75),
      "vertOffset" => round((marker_center_y - picture_height / 2) * 75),
      "textWrap" => "InFrontOfText",
      "allowOverlap" => true,
      "width" => 5_000,
      "height" => 1_208
    }
  end

  defp signature_picture(mode) do
    wrong_position? = mode in [:principal, :wrong_spatial]
    covering? = mode == :covering
    barely_overlapping? = mode == :barely_overlapping
    distorted? = mode == :distorted

    horz_offset =
      cond do
        wrong_position? or covering? -> 0
        barely_overlapping? -> round(@marker_geometry.right * 75) - 1
        true -> 40_854
      end

    vert_offset =
      cond do
        wrong_position? or covering? -> 0
        mode == :near_boundary_pass -> 35_047 + round(0.04 * 1_208)
        mode == :near_boundary_fail -> 35_047 + round(0.06 * 1_208)
        true -> 35_047
      end

    %{
      "type" => "picture",
      "ref" => %{"type" => "picture", "id" => "synthetic-ref"},
      "treatAsChar" => mode == :inline,
      "horzRelTo" => if(mode == :inline, do: "Para", else: "Paper"),
      "vertRelTo" => if(mode == :inline, do: "Para", else: "Paper"),
      "horzAlign" => "Left",
      "vertAlign" => "Top",
      "horzOffset" => horz_offset,
      "vertOffset" => vert_offset,
      "textWrap" => if(mode == :wrong_wrap, do: "Square", else: "InFrontOfText"),
      "allowOverlap" => mode != :overlap_disabled,
      "width" => if(covering?, do: 100_000, else: 5_000),
      "height" =>
        cond do
          covering? -> 100_000
          distorted? -> 5_000
          true -> 1_208
        end
    }
  end

  defp schedule_table do
    expanded_table([
      ["단계", "산출물", "지급 시점", "금액"],
      ["착수", "진단 계획서", "계약 체결 후 5영업일 이내", "26,400,000원"],
      ["중간", "진단 결과 및 개선 가이드 초안", "중간 산출물 승인 후", "35,200,000원"],
      ["완료", "최종 가이드 및 재검수 보고서", "최종 검수 완료 후", "26,400,000원"]
    ])
  end

  defp compact_schedule_table do
    [
      %{
        "type" => "table",
        "cells" => [
          ["단계", "산출물", "지급 시점", "금액"],
          ["착수", "진단 계획서", "계약 체결 후 5영업일 이내", "26,400,000원"],
          ["중간", "진단 결과 및 개선 가이드 초안", "중간 산출물 승인 후", "35,200,000원"],
          ["완료", "최종 가이드 및 재검수 보고서", "최종 검수 완료 후", "26,400,000원"]
        ]
      }
    ]
  end

  defp arbitration_table(value) do
    expanded_table([["중재인 또는 중재기관", value]])
  end

  defp body_end_block(schedule) do
    schedule_payloads =
      if schedule == :compact, do: compact_schedule_table(), else: schedule_table()

    [
      %{"type" => "paragraph", "text" => @body_text},
      %{"type" => "char", "text" => @jurisdiction}
      | schedule_payloads
    ]
  end

  defp move_compact_schedule_after_annex([section]) do
    {blocks, schedule} =
      Enum.map_reduce(section, nil, fn block, schedule ->
        if Enum.any?(block, &match?(%{"type" => "paragraph", "text" => @body_text}, &1)) do
          {table, body_payloads} =
            Enum.split_with(block, &match?(%{"type" => "table", "cells" => _cells}, &1))

          {body_payloads, List.first(table)}
        else
          {block, schedule}
        end
      end)

    [blocks ++ [[schedule]]]
  end

  defp move_schedule_to_next_block([section], prefix \\ []) do
    {section, _moved?} =
      Enum.flat_map_reduce(section, false, fn block, moved? ->
        cond do
          moved? ->
            {[block], true}

          Enum.any?(block, &match?(%{"type" => "paragraph", "text" => @body_text}, &1)) ->
            table_index = Enum.find_index(block, &match?(%{"type" => "table"}, &1))
            {body_payloads, schedule_payloads} = Enum.split(block, table_index)
            {[body_payloads, prefix ++ schedule_payloads], true}

          true ->
            {[block], false}
        end
      end)

    [section]
  end

  defp native_body_end_projection([section]) do
    native_anchor = %{
      "type" => "paragraph",
      "text" => "",
      "paraShapeId" => 89,
      "styleId" => 0,
      "alignment" => "justify"
    }

    section =
      Enum.flat_map(section, fn block ->
        if Enum.any?(block, &match?(%{"type" => "paragraph", "text" => @body_text}, &1)) do
          table_index = Enum.find_index(block, &match?(%{"type" => "table"}, &1))
          schedule_payloads = Enum.drop(block, table_index)

          [
            paragraph(@jurisdiction),
            paragraph(Enum.at(@work_items, 0)),
            paragraph(Enum.at(@work_items, 1)),
            paragraph(Enum.at(@work_items, 2)),
            [native_anchor | schedule_payloads]
          ]
        else
          [block]
        end
      end)

    [section]
  end

  defp real_pristine_shape_projection do
    complete_projection(schedule: :compact)
    |> move_schedule_to_next_block(paragraph(""))
    |> insert_before_annex(paragraph(""))
    |> insert_before_annex(paragraph(""))
  end

  defp insert_before_annex([section], block) do
    annex_index = Enum.find_index(section, &(&1 == paragraph("【별첨】")))
    [List.insert_at(section, annex_index, block)]
  end

  defp insert_before_text([section], text, block) do
    index =
      Enum.find_index(section, fn candidate ->
        Enum.any?(candidate, &match?(%{"type" => "paragraph", "text" => ^text}, &1))
      end)

    [List.insert_at(section, index, block)]
  end

  defp block_has_text?(block, text) do
    Enum.any?(block, &match?(%{"type" => "paragraph", "text" => ^text}, &1))
  end

  defp block_has_table_headers?(block, headers) do
    Enum.any?(ProjectionAudit.table_matrices(block), fn
      [actual | _rows] -> actual == headers
      _matrix -> false
    end)
  end

  defp drop_party_table_occurrence([section], wanted_occurrence) do
    {section, _occurrence} =
      Enum.flat_map_reduce(section, 0, fn block, occurrence ->
        if block_has_table_headers?(block, ["원사업자", "수급사업자"]) do
          occurrence = occurrence + 1
          {if(occurrence == wanted_occurrence, do: [], else: [block]), occurrence}
        else
          {[block], occurrence}
        end
      end)

    [section]
  end

  defp swap_blocks([section], first?, second?) do
    first_index = Enum.find_index(section, first?)
    second_index = Enum.find_index(section, second?)
    first = Enum.at(section, first_index)
    second = Enum.at(section, second_index)

    section =
      section
      |> List.replace_at(first_index, second)
      |> List.replace_at(second_index, first)

    [section]
  end

  defp move_block_after([section], moving?, anchor?) do
    moving_index = Enum.find_index(section, moving?)
    moving = Enum.at(section, moving_index)
    remaining = List.delete_at(section, moving_index)
    anchor_index = Enum.find_index(remaining, anchor?)
    [List.insert_at(remaining, anchor_index + 1, moving)]
  end

  defp replace_block_with_char_mirror(
         [section],
         text,
         ref,
         font_size,
         char_text \\ nil
       ) do
    char_text = char_text || text

    [
      Enum.map(section, fn block ->
        if block_has_text?(block, text) do
          [
            %{"type" => "paragraph", "text" => text},
            %{
              "type" => "char",
              "text" => char_text,
              "fontSize" => font_size,
              "ref" => ref
            }
          ]
        else
          block
        end
      end)
    ]
  end

  defp update_table_block([section], headers, update) do
    [
      Enum.map(section, fn block ->
        if block_has_table_headers?(block, headers), do: update.(block), else: block
      end)
    ]
  end

  defp remove_expanded_cell(payloads, coordinate) do
    {result, _dropping?} =
      Enum.reduce(payloads, {[], false}, fn
        %{"type" => "cell", "row" => row, "col" => col} = cell, {result, _dropping?} ->
          if {row, col} == coordinate do
            {result, true}
          else
            {[cell | result], false}
          end

        _payload, {result, true} ->
          {result, true}

        payload, {result, false} ->
          {[payload | result], false}
      end)

    Enum.reverse(result)
  end

  defp native_marker_geometry(path, opts \\ []) do
    target = "대표자 성명 : 김에크리츠 (인)"
    marker_offset = String.length("대표자 성명 : 김에크리츠 ")
    marker_length = String.length("(인)")

    handle =
      case Ehwp.open(path, []) do
        {:ok, handle, _metadata} -> handle
        {:ok, handle} -> handle
      end

    try do
      assert {:ok, matches_json} = Ehwp.find(handle, target, case_sensitive: true)
      assert {:ok, matches} = Jason.decode(matches_json)

      exact =
        Enum.filter(matches, fn match ->
          match["length"] == String.length(target)
        end)

      occurrence = Keyword.get(opts, :occurrence, 1)
      assert match = Enum.at(exact, occurrence - 1)

      assert %{
               "sec" => section,
               "charOffset" => char_offset,
               "cellContext" => %{
                 "parentPara" => paragraph,
                 "ctrlIdx" => control,
                 "cellIdx" => cell,
                 "cellPara" => cell_paragraph
               }
             } = match

      cursor = %{
        q: "cursor_rect",
        section: section,
        paragraph: paragraph,
        control: control,
        cell: cell,
        cell_para: cell_paragraph
      }

      assert {:ok, start_json} =
               Ehwp.query(handle, Map.put(cursor, :offset, char_offset + marker_offset))

      assert {:ok, end_json} =
               Ehwp.query(
                 handle,
                 Map.put(cursor, :offset, char_offset + marker_offset + marker_length)
               )

      assert {:ok, start_cursor} = Jason.decode(start_json)
      assert {:ok, end_cursor} = Jason.decode(end_json)
      assert start_cursor["pageIndex"] == end_cursor["pageIndex"]
      assert start_cursor["y"] == end_cursor["y"]

      %{
        page_index: start_cursor["pageIndex"],
        left: min(start_cursor["x"], end_cursor["x"]),
        right: max(start_cursor["x"], end_cursor["x"]),
        top: start_cursor["y"],
        bottom: start_cursor["y"] + max(start_cursor["height"], end_cursor["height"])
      }
    after
      Ehwp.close(handle)
    end
  end

  defp write_native_target_document(path, recipient_occurrences \\ 1) do
    {:ok, handle} = Rhwp.new()

    try do
      rows =
        Enum.map(1..recipient_occurrences, fn _occurrence ->
          [
            "대표자 성명 : 이서준 (인)",
            "대표자 성명 : 김에크리츠 (인)"
          ]
        end)

      assert {:ok, _result} =
               Rhwp.edit(handle, %{
                 "op" => "insert_table",
                 "ref" => "end",
                 "cells" => [["원사업자", "수급사업자"] | rows]
               })

      assert {:ok, _result} = Rhwp.save(handle, path: path, format: :hwp)
    after
      Rhwp.close(handle)
    end
  end

  # The projection is one JSON value spread one-group-per-line (#460): the
  # whole binary IS the JSON document.
  defp projection_json(bytes), do: bytes

  defp ehwp_available?(path) do
    case safe_ehwp_open(path) do
      {:ok, handle, _metadata} ->
        Ehwp.close(handle)
        true

      _other ->
        false
    end
  end

  defp safe_ehwp_open(path) do
    Ehwp.open(path, [])
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp expanded_table(matrix) do
    [%{"type" => "table"}] ++
      Enum.flat_map(Enum.with_index(matrix), fn {row, row_index} ->
        Enum.flat_map(Enum.with_index(row), fn {cell, col_index} ->
          [%{"type" => "cell", "row" => row_index, "col" => col_index}] ++
            Enum.flat_map(String.split(cell, "\n", trim: false), &paragraph/1)
        end)
      end)
  end

  defp paragraph(text), do: [%{"type" => "paragraph", "text" => text}]

  defp update_paragraph([section], text, update) do
    [
      Enum.map(section, fn block ->
        Enum.map(block, fn
          %{"type" => "paragraph", "text" => ^text} = paragraph -> update.(paragraph)
          payload -> payload
        end)
      end)
    ]
  end

  defp put_arbitrator_value_cell_height([section], height) do
    [
      Enum.map(section, fn block ->
        if Enum.any?(block, &match?(%{"type" => "paragraph", "text" => "중재인 또는 중재기관"}, &1)) do
          Enum.map(block, fn
            %{"type" => "table"} = table ->
              Map.put(table, "tableHeight", 1_282)

            %{"type" => "cell", "row" => 0, "col" => 1} = cell ->
              Map.put(cell, "height", height)

            payload ->
              payload
          end)
        else
          block
        end
      end)
    ]
  end

  defp replace_text(projection, old, new, opts \\ []) do
    target_occurrence = Keyword.get(opts, :occurrence, 1)
    {projection, _seen} = replace_text(projection, old, new, target_occurrence, 0)
    projection
  end

  defp replace_text(%{"text" => old} = payload, old, new, target, seen) do
    seen = seen + 1
    payload = if seen == target, do: %{payload | "text" => new}, else: payload
    {payload, seen}
  end

  defp replace_text(map, old, new, target, seen) when is_map(map) do
    Enum.reduce(map, {%{}, seen}, fn {key, value}, {acc, count} ->
      {value, count} = replace_text(value, old, new, target, count)
      {Map.put(acc, key, value), count}
    end)
  end

  defp replace_text(list, old, new, target, seen) when is_list(list) do
    Enum.map_reduce(list, seen, &replace_text(&1, old, new, target, &2))
  end

  defp replace_text(value, _old, _new, _target, seen), do: {value, seen}

  defp replace_signing_date([section], replacement) do
    {section, _state} =
      Enum.map_reduce(section, :before_intro, fn
        [%{"type" => "paragraph", "text" => @intro}] = block, :before_intro ->
          {block, :after_intro}

        [%{"type" => "paragraph", "text" => _date}], :after_intro ->
          {paragraph(replacement), :done}

        block, state ->
          {block, state}
      end)

    [section]
  end
end
