defmodule Ecrits.Doc.ProjectionAudit do
  @moduledoc """
  Deterministic, index-free checks over the mounted document projection.

  Requirements describe semantic text labels and table contents. The audit
  locates them by normalized content, never by section/paragraph/cell numbers,
  so inserting another paragraph or table does not invalidate the contract.
  """

  @standard_contract_demo_work_items [
    "웹 서비스의 접근성 진단과 우선순위 개선 목록 작성",
    "핵심 화면 개선 가이드와 재검수 결과 보고서 작성",
    "운영 담당자용 접근성 유지관리 가이드 제공"
  ]

  @standard_contract_demo_intro "주식회사 블루버드 디자인랩(이하 ‘원사업자’)와 주식회사 에크리츠(이하 ‘수급사업자’)는(은) 신의에 따라 성실히 계약상의 권리를 행사하고, 의무를 이행할 것을 확약하며, 그 증거로써 이 계약서를 작성하여 당사자가 기명날인한 후 각각 1부씩 보관한다."

  @standard_contract_demo_jurisdiction "제51조(재판관할) 이 계약과 관련된 소는 서울중앙지방법원에 제기한다."

  @standard_contract_demo_schedule_headers ["단계", "산출물", "지급 시점", "금액"]

  @standard_contract_demo_requirements %{
    texts: [
      %{id: "contract_name", exact: "◇ 계약명 : 웹 접근성 진단 및 개선 가이드 제작", count: 1},
      %{id: "contract_period", exact: "◇ 계약기간 : 2026년 7월 20일부터 2026년 10월 31일까지", count: 1},
      %{
        id: "contract_amount",
        exact: "◇ 계약 금액 : 금 88,000,000원정(￦88,000,000)(부가가치세 포함)",
        count: 1
      },
      %{id: "party_intro", exact: @standard_contract_demo_intro, count: 1},
      %{
        id: "signing_date",
        exact: "미기재",
        after: @standard_contract_demo_intro,
        before: "원사업자",
        count: 1
      },
      %{id: "supply_date", exact: "◇ 원재료의 공급일 : 미기재", count: 1},
      %{id: "supply_place", exact: "◇ 원재료의 공급장소 : 미기재", count: 1},
      %{id: "instruction_date", exact: "◇ 교부일 : 미기재", count: 1},
      %{
        id: "instruction_lead",
        exact: "◇ 성과물의 작성 개시예정일로부터 최소 (미기재)일 이전까지 교부",
        count: 1
      },
      %{id: "delivery_date", exact: "◇ 납품일자 : 미기재", count: 1},
      %{id: "delivery_place", exact: "◇ 납품장소 : 미기재", count: 1},
      %{
        id: "performance_bond",
        exact: "사. 계약이행보증금요율 : 계약금액의 (미기재)%",
        count: 1
      },
      %{
        id: "payment_bond",
        exact: "아. 대금지급보증금요율 : 계약금액의 (미기재)%",
        count: 1
      },
      %{
        id: "late_interest",
        exact: "◇ 지연이자요율(대금 지급 지연) : 연 (미기재)%",
        count: 1
      },
      %{id: "other_interest", exact: "◇ 기타 지연이자요율 : 연 (미기재)%", count: 1},
      %{
        id: "delay_penalty",
        exact: "차. 지체상금요율 : 지체일당 계약금액의 (미기재)/1,000",
        count: 1
      },
      %{
        id: "defect_period",
        exact: "카. 하자담보책임기간 : 성과물을 납품한 날로부터 (미기재)년",
        count: 1
      },
      %{id: "indexation_none", exact: "◇ 연동제 적용대상 없음 (미기재)", count: 1},
      %{
        id: "indexation_all",
        exact: "◇ 적용함 : (미기재) 【하도급대금 연동 계약서】",
        count: 1
      },
      %{
        id: "indexation_partial",
        exact: "◇ 일부 적용함 : (미기재) 【하도급대금 연동 계약서】 및 【하도급대금 미연동 계약서】",
        count: 1
      },
      %{
        id: "indexation_excluded",
        exact: "◇ 전부 적용하지 않음 : (미기재) 【하도급대금 미연동 계약서】",
        count: 1
      },
      %{id: "renewal_deadline", exact: "하. 계약갱신 여부에 대한 최고기한 : 미기재", count: 1},
      %{
        id: "withholding_count",
        exact: "거. 이행거절을 위한 기성금 등의 미지급 횟수 : 미기재 회 미지급",
        count: 1
      }
    ],
    tables: [
      %{
        id: "payment_table",
        headers: ["구분", "비율", "지급금액", "지급기일", "지급방법"],
        dimensions: {5, 5},
        allowed_missing_coordinates: [{4, 3}, {4, 4}],
        reject_any_duplicate_candidate: true,
        duplicate_candidate_dimensions: {5, 5},
        after: "◇ 계약 금액 : 금 88,000,000원정(￦88,000,000)(부가가치세 포함)",
        before: "◇ 원재료의 공급일 : 미기재",
        rows: [
          ["선급금", "30.0%", "26,400,000원", "계약 체결 후 5영업일 이내", "미기재"],
          [
            ["중도금 또는 기성금", "(지급회수: 1회)"],
            "40.0%",
            "35,200,000원",
            "중간 산출물 승인 후",
            "미기재"
          ],
          ["잔 금", "30.0%", "26,400,000원", "최종 검수 완료 후", "미기재"],
          ["합계", "100.0%", "88,000,000원", "", ""]
        ]
      },
      %{
        id: "party_table",
        headers: ["원사업자", "수급사업자"],
        dimensions: {2, 2},
        rows: [
          [
            [
              "상호 또는 명칭 : 주식회사 블루버드 디자인랩",
              "전화번호 : 미기재",
              "주 소 : 미기재",
              "대표자 성명 : 이서준 (인)",
              "사업자(법인)번호 : 미기재"
            ],
            [
              "상호 또는 명칭 : 주식회사 에크리츠",
              "전화번호 : 미기재",
              "주 소 : 미기재",
              "대표자 성명 : 김에크리츠 (인)",
              "사업자(법인)번호 : 미기재"
            ]
          ]
        ]
      },
      %{
        id: "performance_payment_schedule",
        headers: @standard_contract_demo_schedule_headers,
        dimensions: {4, 4},
        reject_any_duplicate_candidate: true,
        before: "【별첨】",
        rows: [
          ["착수", "진단 계획서", "계약 체결 후 5영업일 이내", "26,400,000원"],
          ["중간", "진단 결과 및 개선 가이드 초안", "중간 산출물 승인 후", "35,200,000원"],
          ["완료", "최종 가이드 및 재검수 보고서", "최종 검수 완료 후", "26,400,000원"]
        ]
      },
      %{
        id: "arbitrator",
        headers: ["중재인 또는 중재기관", "미기재"],
        dimensions: {1, 2}
      }
    ],
    body_end: [
      %{
        id: "contract_body_end",
        article_line: @standard_contract_demo_jurisdiction,
        work_items: @standard_contract_demo_work_items,
        schedule_headers: @standard_contract_demo_schedule_headers,
        before: "【별첨】"
      }
    ],
    pictures: [
      %{
        id: "recipient_signature",
        target_text: "대표자 성명 : 김에크리츠 (인)",
        marker: "(인)",
        count: 1,
        global_picture_count: 2,
        require_native_marker_overlap: true,
        marker_relative_geometry: %{
          width_ratio: {2.5, 3.7},
          height_ratio: {0.9, 1.6},
          minimum_marker_overlap: %{horizontal: 0.95, vertical: 0.95},
          maximum_picture_center_offset: %{horizontal: 0.05, vertical: 0.05},
          aspect_ratio: %{expected: 1337 / 323, tolerance: 0.03}
        },
        coordinate_properties: ~w(horzOffset vertOffset width height),
        properties: %{
          "treatAsChar" => false,
          "horzRelTo" => "Paper",
          "vertRelTo" => "Paper",
          "horzAlign" => "Left",
          "vertAlign" => "Top",
          "textWrap" => "InFrontOfText",
          "allowOverlap" => true
        }
      }
    ]
  }

  @type issue :: %{
          required(:id) => String.t(),
          required(:reason) => atom(),
          optional(:detail) => term()
        }

  @spec validate(binary() | list(), map(), keyword()) :: :ok | {:error, [issue()]}
  def validate(projection, requirements, opts \\ []) when is_map(requirements) do
    with {:ok, tree} <- decode_projection(projection) do
      issues =
        validate_text_requirements(tree, Map.get(requirements, :texts, [])) ++
          validate_table_requirements(tree, Map.get(requirements, :tables, [])) ++
          validate_body_end_requirements(tree, Map.get(requirements, :body_end, [])) ++
          validate_picture_requirements(tree, Map.get(requirements, :pictures, []), opts)

      case issues do
        [] -> :ok
        issues -> {:error, issues}
      end
    else
      {:error, reason} ->
        {:error, [%{id: "projection", reason: :invalid_projection, detail: reason}]}
    end
  end

  @doc "Validate standard-contract projection semantics against native marker geometry."
  @spec validate_standard_contract_projection(binary() | list(), map()) ::
          :ok | {:error, [issue()]}
  def validate_standard_contract_projection(projection, marker_geometry)
      when is_map(marker_geometry) do
    validate(projection, @standard_contract_demo_requirements,
      picture_marker_geometries: %{"recipient_signature" => marker_geometry}
    )
  end

  @doc """
  Compare a pristine standard contract with its completed projection.

  The comparison is semantic and index-free: it inventories non-table
  paragraphs, normalized table matrices, and document pictures. Only the
  brief's named field replacements, the exact payment/party/arbitration table
  replacements, the exact 4-column schedule insertion, and one signature
  picture insertion are accepted.
  """
  @spec validate_standard_contract_semantic_diff(binary() | list(), binary() | list()) ::
          :ok | {:error, [issue()]}
  def validate_standard_contract_semantic_diff(pristine_projection, final_projection) do
    with {:ok, pristine_tree} <- decode_projection(pristine_projection),
         {:ok, final_tree} <- decode_projection(final_projection) do
      pristine = semantic_sequence(pristine_tree)
      final = semantic_sequence(final_tree)

      pristine
      |> validate_standard_contract_sequence(final)
      |> validation_result()
    else
      {:error, reason} ->
        {:error,
         [%{id: "standard_contract_semantic_diff", reason: :invalid_projection, detail: reason}]}
    end
  end

  @doc """
  Validate the saved standard-contract demo, native placement, supplied image,
  and pristine-to-final semantic diff.

  Pass the projection made from the untouched source document as
  `:pristine_projection`. Omitting it is a validation failure because the
  final projection alone cannot prove that unrelated content was preserved.
  """
  @spec validate_standard_contract_demo(binary() | list(), String.t(), String.t(), keyword()) ::
          :ok | {:error, [issue()]}
  def validate_standard_contract_demo(projection, document_path, image_path, opts)
      when is_list(opts) do
    picture_requirement =
      Enum.find(@standard_contract_demo_requirements.pictures, &(&1.id == "recipient_signature"))

    {geometry_opts, geometry_issues} =
      case native_marker_geometry(document_path, picture_requirement) do
        {:ok, geometry} ->
          {[picture_marker_geometries: %{"recipient_signature" => geometry}], []}

        {:error, reason} ->
          {[allow_missing_native_marker_geometry: true],
           [
             %{
               id: "recipient_signature",
               reason: :native_marker_geometry_unavailable,
               detail: reason
             }
           ]}
      end

    projection_issues =
      projection
      |> validate(@standard_contract_demo_requirements, geometry_opts)
      |> validation_issues()

    hash_issues =
      document_path
      |> validate_embedded_image_hash(image_path, opts)
      |> validation_issues()

    semantic_issues =
      case Keyword.fetch(opts, :pristine_projection) do
        {:ok, pristine_projection} ->
          pristine_projection
          |> validate_standard_contract_semantic_diff(projection)
          |> validation_issues()

        :error ->
          [
            %{
              id: "standard_contract_semantic_diff",
              reason: :pristine_projection_missing
            }
          ]
      end

    validation_result(projection_issues ++ geometry_issues ++ hash_issues ++ semantic_issues)
  end

  @doc "Count paragraphs whose raw text is byte-for-byte equal to `text`."
  @spec exact_paragraph_count(binary() | list(), String.t()) :: non_neg_integer()
  def exact_paragraph_count(projection, text) when is_binary(text) do
    with {:ok, tree} <- decode_projection(projection) do
      tree
      |> payload_maps()
      |> Enum.count(&(&1["type"] == "paragraph" and &1["text"] == text))
    else
      _error -> 0
    end
  end

  @doc "Project every expanded or compact table into a normalized text matrix."
  @spec table_matrices(binary() | list()) :: [[[String.t()]]]
  def table_matrices(projection) do
    with {:ok, tree} <- decode_projection(projection) do
      tree
      |> payload_lists()
      |> Enum.flat_map(&matrix_from_payload_list/1)
    else
      _error -> []
    end
  end

  @doc "Require exactly one embedded HWP BinData stream with the supplied image's SHA-256."
  @spec validate_embedded_image_hash(String.t(), String.t(), keyword()) ::
          :ok | {:error, [issue()]}
  def validate_embedded_image_hash(document_path, image_path, opts \\ []) do
    executable = Keyword.get(opts, :executable) || System.find_executable("hwp5proc")

    with true <- File.regular?(document_path),
         true <- File.regular?(image_path),
         executable when is_binary(executable) <- executable,
         {:ok, streams} <- hwp_bin_data_streams(executable, document_path),
         {:ok, image_bytes} <- File.read(image_path) do
      expected_hash = sha256(image_bytes)

      matching =
        streams
        |> Enum.filter(fn stream ->
          case System.cmd(executable, ["cat", document_path, stream], stderr_to_stdout: true) do
            {bytes, 0} -> sha256(bytes) == expected_hash
            {_output, _status} -> false
          end
        end)

      case matching do
        [_one] ->
          :ok

        matches ->
          {:error,
           [
             %{
               id: "signature_image_hash",
               reason: :embedded_image_hash_count_mismatch,
               detail: %{expected: 1, actual: length(matches), sha256: expected_hash}
             }
           ]}
      end
    else
      false ->
        {:error, [%{id: "signature_image_hash", reason: :missing_input_file}]}

      nil ->
        {:error, [%{id: "signature_image_hash", reason: :extractor_unavailable}]}

      {:error, reason} ->
        {:error, [%{id: "signature_image_hash", reason: :extractor_failed, detail: reason}]}
    end
  end

  defp validate_text_requirements(tree, requirements) do
    texts =
      tree
      |> payload_maps()
      |> Enum.flat_map(fn
        %{"type" => "paragraph", "text" => text} when is_binary(text) -> [normalize(text)]
        _payload -> []
      end)

    Enum.flat_map(requirements, fn requirement ->
      id = requirement_id(requirement)
      expected = normalize(Map.get(requirement, :value, ""))
      scoped_texts = scope_texts(texts, requirement)

      matches =
        cond do
          is_binary(Map.get(requirement, :exact)) ->
            exact = normalize(Map.fetch!(requirement, :exact))
            Enum.filter(scoped_texts, &(&1 == exact))

          is_binary(Map.get(requirement, :label)) ->
            label = normalize(Map.fetch!(requirement, :label))
            Enum.filter(scoped_texts, &String.starts_with?(&1, label))

          true ->
            scoped_texts
        end

      cond do
        matches == [] ->
          [%{id: id, reason: :missing_anchor}]

        is_integer(Map.get(requirement, :count)) and
            length(matches) != Map.fetch!(requirement, :count) ->
          [
            %{
              id: id,
              reason: :text_count_mismatch,
              detail: %{expected: Map.fetch!(requirement, :count), actual: length(matches)}
            }
          ]

        is_binary(Map.get(requirement, :exact)) ->
          []

        expected != "" and not Enum.any?(matches, &String.contains?(&1, expected)) ->
          [%{id: id, reason: :missing_value, detail: Map.get(requirement, :value)}]

        true ->
          []
      end
    end)
  end

  defp validate_table_requirements(tree, requirements) do
    blocks = projection_blocks(tree)

    matrix_entries =
      blocks
      |> Enum.with_index()
      |> Enum.flat_map(fn {block, block_index} ->
        Enum.map(table_entries_from_payload_list(block), &Map.put(&1, :block_index, block_index))
      end)

    all_entries =
      tree
      |> payload_lists()
      |> Enum.flat_map(&table_entries_from_payload_list/1)

    Enum.flat_map(requirements, fn requirement ->
      id = requirement_id(requirement)
      headers = Enum.map(Map.get(requirement, :headers, []), &normalize/1)

      entries =
        scoped_table_entries(matrix_entries, blocks, requirement, all_entries)

      candidates = Enum.filter(entries, &table_candidate?(&1.matrix, headers, requirement))

      matching = Enum.filter(candidates, &table_matches?(&1.matrix, requirement))

      invalid_coordinates =
        Enum.flat_map(candidates, fn entry ->
          case table_entry_coordinate_issues(entry, requirement) do
            [] -> []
            issues -> [issues]
          end
        end)

      cond do
        candidates == [] ->
          [%{id: id, reason: :missing_table, detail: requirement}]

        Map.get(requirement, :reject_any_duplicate_candidate, false) and
            length(candidates) > 1 ->
          [%{id: id, reason: :duplicate_table, detail: %{count: length(candidates)}}]

        invalid_coordinates != [] ->
          [
            %{
              id: id,
              reason: :invalid_table_coordinates,
              detail: invalid_coordinates
            }
          ]

        matching == [] ->
          [%{id: id, reason: :table_content_mismatch, detail: requirement}]

        length(matching) == 1 ->
          []

        true ->
          [%{id: id, reason: :duplicate_table, detail: %{count: length(matching)}}]
      end
    end)
  end

  defp scoped_table_entries(entries, blocks, requirement, all_entries) do
    after_anchor = Map.get(requirement, :after)
    before_anchor = Map.get(requirement, :before)

    if is_binary(after_anchor) or is_binary(before_anchor) do
      after_index = semantic_anchor_block_index(blocks, after_anchor)
      before_index = semantic_anchor_block_index(blocks, before_anchor)

      cond do
        is_binary(after_anchor) and is_nil(after_index) ->
          []

        is_binary(before_anchor) and is_nil(before_index) ->
          []

        true ->
          Enum.filter(entries, fn entry ->
            (is_nil(after_index) or entry.block_index > after_index) and
              (is_nil(before_index) or entry.block_index < before_index)
          end)
      end
    else
      all_entries
    end
  end

  defp semantic_anchor_block_index(_blocks, anchor) when not is_binary(anchor), do: nil

  defp semantic_anchor_block_index(blocks, anchor) do
    normalized = normalize(anchor)

    Enum.find_index(blocks, fn block ->
      Enum.any?(block_paragraphs(block), &(logical_lines(&1) == [normalized]))
    end)
  end

  defp validate_body_end_requirements(tree, requirements) do
    blocks = projection_blocks(tree)

    Enum.flat_map(requirements, fn requirement ->
      id = requirement_id(requirement)
      article_line = normalize(Map.fetch!(requirement, :article_line))
      work_items = Enum.map(Map.fetch!(requirement, :work_items), &normalize/1)
      schedule_headers = Enum.map(Map.fetch!(requirement, :schedule_headers), &normalize/1)
      annex_marker = normalize(Map.fetch!(requirement, :before))

      article_blocks =
        blocks
        |> Enum.with_index()
        |> Enum.filter(fn {block, _index} ->
          Enum.any?(block_paragraphs(block), fn paragraph ->
            case logical_lines(paragraph) do
              [^article_line | _rest] -> true
              _other -> false
            end
          end)
        end)

      annex_index =
        Enum.find_index(blocks, fn block ->
          Enum.any?(block_paragraphs(block), &(logical_lines(&1) == [annex_marker]))
        end)

      schedule_blocks =
        blocks
        |> schedule_candidate_blocks(schedule_headers)
        |> scope_body_end_schedule_blocks(article_blocks, annex_index)

      body_end_4x4_tables = body_end_4x4_tables(blocks, article_blocks, annex_index)

      validate_body_article(id, article_blocks, blocks, article_line, work_items) ++
        validate_body_schedule_duplicates(id, body_end_4x4_tables) ++
        validate_body_schedule(
          id,
          blocks,
          article_blocks,
          schedule_blocks,
          annex_index,
          article_line
        )
    end)
  end

  defp validate_body_article(id, article_blocks, blocks, article_line, work_items) do
    all_lines =
      Enum.flat_map(blocks, &Enum.flat_map(block_paragraphs(&1), fn p -> logical_lines(p) end))

    counts =
      Map.new(work_items, fn item ->
        {item, Enum.count(all_lines, &(&1 == item))}
      end)

    case article_blocks do
      [{block, _index}] ->
        matching_paragraphs =
          Enum.filter(block_paragraphs(block), fn paragraph ->
            case logical_lines(paragraph) do
              [^article_line | _rest] -> true
              _other -> false
            end
          end)

        case matching_paragraphs do
          [paragraph] ->
            if logical_lines(paragraph) == [article_line | work_items] and
                 map_size(counts) == length(work_items) and
                 Enum.all?(counts, fn {_item, count} -> count == 1 end) do
              []
            else
              [
                %{
                  id: id,
                  reason: :work_item_placement_mismatch,
                  detail: %{expected: work_items, counts: counts}
                }
              ]
            end

          _other ->
            [
              %{
                id: id,
                reason: :work_item_placement_mismatch,
                detail: %{expected: work_items, counts: counts}
              }
            ]
        end

      [] ->
        [%{id: id, reason: :missing_body_end_article, detail: article_line}]

      many ->
        [%{id: id, reason: :ambiguous_body_end_article, detail: %{count: length(many)}}]
    end
  end

  defp validate_body_schedule(
         id,
         blocks,
         article_blocks,
         schedule_blocks,
         annex_index,
         article_line
       ) do
    case {article_blocks, schedule_blocks, annex_index} do
      {[{article_block, article_index}], [{schedule_block, schedule_index, schedule_table_index}],
       annex_index}
      when is_integer(annex_index) ->
        same_block? =
          schedule_index == article_index and
            schedule_follows_article_in_block?(
              article_block,
              article_line,
              schedule_table_index
            )

        next_block? =
          schedule_index == article_index + 1 and
            schedule_starts_block?(schedule_block, schedule_table_index)

        # Payload-local insertion preserves unused sibling paragraph blocks.
        # They are inert only when every payload is an empty paragraph.
        spacer_blocks =
          blocks
          |> Enum.slice(schedule_index + 1, max(annex_index - schedule_index - 1, 0))

        annex_follows_schedule? =
          annex_index > schedule_index and Enum.all?(spacer_blocks, &empty_paragraph_block?/1)

        if (same_block? or next_block?) and annex_follows_schedule? do
          []
        else
          [
            %{
              id: id,
              reason: :schedule_placement_mismatch,
              detail: %{
                article_block: article_index,
                schedule_block: schedule_index,
                annex_block: annex_index,
                same_block: article_block == schedule_block,
                empty_spacers_only: annex_follows_schedule?
              }
            }
          ]
        end

      {_article_blocks, [], _annex_index} ->
        [%{id: id, reason: :missing_body_end_schedule}]

      {_article_blocks, many, _annex_index} when length(many) > 1 ->
        [%{id: id, reason: :duplicate_body_end_schedule, detail: %{count: length(many)}}]

      {_article_blocks, _schedule_blocks, nil} ->
        [%{id: id, reason: :missing_annex_boundary}]

      _other ->
        []
    end
  end

  defp validate_picture_requirements(tree, requirements, opts) do
    all_pictures = Enum.filter(projection_payloads(tree), &(&1["type"] == "picture"))
    marker_geometries = Keyword.get(opts, :picture_marker_geometries, %{})
    allow_missing_geometry? = Keyword.get(opts, :allow_missing_native_marker_geometry, false)

    blocks = payload_lists(tree)

    Enum.flat_map(requirements, fn requirement ->
      id = requirement_id(requirement)
      target = normalize(Map.get(requirement, :target_text, ""))

      target_contexts =
        Enum.flat_map(blocks, fn block ->
          block
          |> expanded_cells()
          |> Enum.filter(fn cell ->
            Enum.any?(cell.paragraphs, &(normalize(Map.get(&1, "text", "")) == target))
          end)
          |> Enum.map(&%{block: block, cell: &1})
        end)

      case target_contexts do
        [] ->
          [%{id: id, reason: :missing_picture_target}]

        [_first, _second | _rest] ->
          [
            %{
              id: id,
              reason: :ambiguous_picture_target,
              detail: %{count: length(target_contexts)}
            }
          ]

        [%{block: block, cell: cell}] ->
          block_pictures = Enum.filter(block, &(&1["type"] == "picture"))

          validate_target_pictures(
            id,
            cell,
            block_pictures,
            requirement,
            all_pictures,
            Map.get(marker_geometries, id),
            allow_missing_geometry?
          )
      end
    end)
  end

  defp validate_target_pictures(
         id,
         cell,
         block_pictures,
         requirement,
         all_pictures,
         marker_geometry,
         allow_missing_geometry?
       ) do
    pictures =
      if Map.get(requirement, :require_native_marker_overlap, false),
        do: block_pictures,
        else: Enum.filter(cell.payloads, &(&1["type"] == "picture"))

    expected_count = Map.get(requirement, :count, 1)

    spatial_mismatches =
      if is_map(marker_geometry) do
        Enum.flat_map(pictures, fn picture ->
          case picture_marker_geometry(picture, marker_geometry, requirement) do
            :ok -> []
            {:error, detail} -> [detail]
          end
        end)
      else
        []
      end

    cond do
      length(pictures) != expected_count ->
        [
          %{
            id: id,
            reason: :picture_count_mismatch,
            detail: %{expected: expected_count, actual: length(pictures)}
          }
        ]

      not Enum.all?(pictures, &picture_matches?(&1, requirement)) ->
        [%{id: id, reason: :picture_properties_mismatch}]

      not Enum.all?(pictures, &picture_has_required_coordinates?(&1, requirement)) ->
        [%{id: id, reason: :picture_coordinates_missing}]

      not global_picture_count_matches?(all_pictures, requirement) ->
        [
          %{
            id: id,
            reason: :global_picture_count_mismatch,
            detail: %{
              expected: Map.get(requirement, :global_picture_count),
              actual: length(all_pictures)
            }
          }
        ]

      Map.get(requirement, :require_native_marker_overlap, false) and
        is_nil(marker_geometry) and not allow_missing_geometry? ->
        [%{id: id, reason: :native_marker_geometry_missing}]

      Map.get(requirement, :require_native_marker_overlap, false) and
        is_map(marker_geometry) and
          spatial_mismatches != [] ->
        [%{id: id, reason: :picture_spatial_mismatch, detail: spatial_mismatches}]

      true ->
        []
    end
  end

  defp picture_matches?(picture, requirement) do
    requirement
    |> Map.get(:properties, %{})
    |> Enum.all?(fn {key, value} -> Map.get(picture, to_string(key)) == value end)
  end

  defp global_picture_count_matches?(pictures, requirement) do
    case Map.get(requirement, :global_picture_count) do
      expected when is_integer(expected) and expected >= 0 ->
        length(pictures) == expected

      _not_required ->
        true
    end
  end

  defp picture_has_required_coordinates?(picture, requirement) do
    requirement
    |> Map.get(:coordinate_properties, [])
    |> Enum.all?(fn key ->
      case Map.get(picture, to_string(key)) do
        value when key in ["width", "height"] -> is_number(value) and value > 0
        value -> is_number(value) and value >= 0
      end
    end)
  end

  @hwpunit_per_render_unit 75.0

  defp picture_marker_geometry(picture, marker, requirement) do
    with left when is_number(left) <- Map.get(picture, "horzOffset"),
         top when is_number(top) <- Map.get(picture, "vertOffset"),
         width when is_number(width) and width > 0 <- Map.get(picture, "width"),
         height when is_number(height) and height > 0 <- Map.get(picture, "height"),
         marker_left when is_number(marker_left) <- Map.get(marker, :left),
         marker_right when is_number(marker_right) <- Map.get(marker, :right),
         marker_top when is_number(marker_top) <- Map.get(marker, :top),
         marker_bottom when is_number(marker_bottom) <- Map.get(marker, :bottom),
         marker_width when marker_width > 0 <- marker_right - marker_left,
         marker_height when marker_height > 0 <- marker_bottom - marker_top do
      picture_left = left / @hwpunit_per_render_unit
      picture_top = top / @hwpunit_per_render_unit
      picture_width = width / @hwpunit_per_render_unit
      picture_height = height / @hwpunit_per_render_unit
      picture_right = picture_left + picture_width
      picture_bottom = picture_top + picture_height
      overlap_width = max(min(picture_right, marker_right) - max(picture_left, marker_left), 0)
      overlap_height = max(min(picture_bottom, marker_bottom) - max(picture_top, marker_top), 0)

      metrics = %{
        width_ratio: picture_width / marker_width,
        height_ratio: picture_height / marker_height,
        marker_overlap: %{
          horizontal: overlap_width / marker_width,
          vertical: overlap_height / marker_height
        },
        picture_center_offset: %{
          horizontal:
            abs((picture_left + picture_right) / 2 - (marker_left + marker_right) / 2) /
              picture_width,
          vertical:
            abs((picture_top + picture_bottom) / 2 - (marker_top + marker_bottom) / 2) /
              picture_height
        },
        aspect_ratio: picture_width / picture_height
      }

      constraints = Map.get(requirement, :marker_relative_geometry, %{})
      failed = failed_marker_geometry_constraints(metrics, constraints)

      if failed == [] do
        :ok
      else
        {:error, %{failed: failed, metrics: metrics, constraints: constraints}}
      end
    else
      _ -> {:error, %{failed: [:invalid_geometry]}}
    end
  end

  defp failed_marker_geometry_constraints(metrics, constraints) do
    overlap = metrics.marker_overlap
    center_offset = metrics.picture_center_offset
    minimum_overlap = Map.get(constraints, :minimum_marker_overlap, %{})
    maximum_center_offset = Map.get(constraints, :maximum_picture_center_offset, %{})
    aspect_ratio = Map.get(constraints, :aspect_ratio, %{})

    []
    |> maybe_failed(
      not ratio_in_range?(metrics.width_ratio, Map.get(constraints, :width_ratio)),
      :width_ratio
    )
    |> maybe_failed(
      not ratio_in_range?(metrics.height_ratio, Map.get(constraints, :height_ratio)),
      :height_ratio
    )
    |> maybe_failed(
      overlap.horizontal < Map.get(minimum_overlap, :horizontal, 0.0),
      :horizontal_overlap
    )
    |> maybe_failed(
      overlap.vertical < Map.get(minimum_overlap, :vertical, 0.0),
      :vertical_overlap
    )
    |> maybe_failed(
      center_offset.horizontal > Map.get(maximum_center_offset, :horizontal, 1.0),
      :horizontal_center_offset
    )
    |> maybe_failed(
      center_offset.vertical > Map.get(maximum_center_offset, :vertical, 1.0),
      :vertical_center_offset
    )
    |> maybe_failed(not aspect_ratio_matches?(metrics.aspect_ratio, aspect_ratio), :aspect_ratio)
    |> Enum.reverse()
  end

  defp ratio_in_range?(_value, nil), do: true

  defp ratio_in_range?(value, {minimum, maximum})
       when is_number(minimum) and is_number(maximum),
       do: value >= minimum and value <= maximum

  defp ratio_in_range?(_value, _range), do: false

  defp aspect_ratio_matches?(_actual, constraints) when constraints == %{}, do: true

  defp aspect_ratio_matches?(actual, %{expected: expected, tolerance: tolerance})
       when is_number(expected) and expected > 0 and is_number(tolerance) and tolerance >= 0,
       do: abs(actual - expected) / expected <= tolerance

  defp aspect_ratio_matches?(_actual, _constraints), do: false

  defp maybe_failed(failures, true, reason), do: [reason | failures]
  defp maybe_failed(failures, false, _reason), do: failures

  defp semantic_sequence(tree) do
    tree
    |> projection_blocks()
    |> Enum.flat_map(&semantic_block_tokens/1)
  end

  defp semantic_block_tokens([]), do: []

  defp semantic_block_tokens([%{"type" => "table", "cells" => cells} = table | rest])
       when is_list(cells) do
    [semantic_table_token([table]) | semantic_block_tokens(rest)]
  end

  defp semantic_block_tokens([%{"type" => "table"} = table | rest]) do
    {owned_payloads, remaining} =
      Enum.split_while(rest, &(&1["type"] != "table"))

    table_payloads = [table | owned_payloads]
    token = semantic_table_token(table_payloads)
    pictures = semantic_picture_tokens(owned_payloads)

    [token | pictures] ++ semantic_block_tokens(remaining)
  end

  defp semantic_block_tokens([
         %{"type" => "paragraph", "text" => text} = paragraph | rest
       ])
       when is_binary(text) do
    {chars, remaining} = Enum.split_while(rest, &(&1["type"] == "char"))

    case normalize(text) do
      "" ->
        empty_paragraph_payload_tokens(paragraph, chars) ++ semantic_block_tokens(remaining)

      normalized ->
        [
          %{
            kind: :paragraph,
            text: normalized,
            meta: canonical_payload(paragraph, ~w(type text)),
            chars: Enum.map(chars, &canonical_payload(&1, ~w(type ref writableProperties)))
          }
          | semantic_block_tokens(remaining)
        ]
    end
  end

  defp semantic_block_tokens([%{"type" => "picture"} = picture | rest]) do
    [semantic_picture_token(picture) | semantic_block_tokens(rest)]
  end

  defp semantic_block_tokens([%{} = payload | rest]) do
    [semantic_payload_token(payload) | semantic_block_tokens(rest)]
  end

  defp semantic_block_tokens([_value | rest]), do: semantic_block_tokens(rest)

  defp empty_paragraph_payload_tokens(paragraph, chars) do
    paragraph_meta = canonical_payload(paragraph, ~w(type text))

    cond do
      paragraph_meta != %{} ->
        [%{kind: :empty_paragraph_meta, meta: paragraph_meta}]

      Enum.all?(chars, &(normalize(Map.get(&1, "text", "")) == "")) ->
        []

      true ->
        Enum.map(chars, &semantic_payload_token/1)
    end
  end

  defp semantic_table_token(payloads) do
    table = Enum.find(payloads, &match?(%{"type" => "table"}, &1))

    matrix =
      case matrix_from_table_payloads(payloads) do
        [matrix] -> canonical_matrix(matrix)
        [] -> []
      end

    cells =
      Enum.flat_map(payloads, fn
        %{"type" => "cell", "row" => row, "col" => col} = cell ->
          [
            %{
              row: row,
              col: col,
              meta: canonical_payload(cell, ~w(type text row col))
            }
          ]

        _payload ->
          []
      end)

    %{
      kind: :table,
      matrix: matrix,
      table_meta: canonical_payload(table, ~w(type text cells)),
      cells: cells,
      coordinates: expanded_table_coordinates(payloads),
      coordinate_issues: expanded_table_coordinate_issues(payloads),
      paragraph_meta:
        Enum.flat_map(payloads, fn
          %{"type" => "paragraph"} = paragraph ->
            [canonical_payload(paragraph, ~w(type text))]

          _payload ->
            []
        end),
      chars:
        Enum.flat_map(payloads, fn
          %{"type" => "char"} = char ->
            [canonical_payload(char, ~w(type ref writableProperties))]

          _payload ->
            []
        end),
      extras:
        Enum.flat_map(payloads, fn
          %{"type" => type} = payload
          when type not in ["table", "cell", "paragraph", "char", "picture"] ->
            [semantic_payload_token(payload)]

          _payload ->
            []
        end)
    }
  end

  defp semantic_picture_tokens(payloads) do
    Enum.flat_map(payloads, fn
      %{"type" => "picture"} = picture -> [semantic_picture_token(picture)]
      _payload -> []
    end)
  end

  defp semantic_picture_token(picture) do
    %{kind: :picture, value: canonical_payload(picture, ~w(type text))}
  end

  defp semantic_payload_token(payload) do
    type = Map.get(payload, "type", "unknown")
    ignored = if type == "document", do: ~w(type text previewText), else: ~w(type)
    %{kind: :payload, type: type, value: canonical_payload(payload, ignored)}
  end

  defp canonical_payload(nil, _ignored), do: %{}

  defp canonical_payload(payload, ignored) when is_map(payload) do
    payload
    |> Map.drop(ignored ++ ~w(ref writableProperties))
    |> canonical_term()
  end

  defp canonical_term(term) when is_map(term) do
    Map.new(term, fn {key, value} -> {key, canonical_term(value)} end)
  end

  defp canonical_term(term) when is_list(term), do: Enum.map(term, &canonical_term/1)
  defp canonical_term(term), do: term

  defp validate_standard_contract_sequence(pristine, final) do
    initial = %{used: MapSet.new(), signature_pending?: false}

    case consume_standard_contract_sequence(pristine, final, initial) do
      {:ok, state} ->
        missing = MapSet.difference(standard_contract_expected_changes(), state.used)

        if MapSet.size(missing) == 0 do
          []
        else
          [
            %{
              id: "standard_contract_semantic_diff",
              reason: :missing_expected_transformations,
              detail: %{missing: missing |> MapSet.to_list() |> Enum.sort()}
            }
          ]
        end

      {:error, detail} ->
        [
          %{
            id: "standard_contract_semantic_diff",
            reason: :unapproved_semantic_sequence,
            detail: detail
          }
        ]
    end
  end

  defp consume_standard_contract_sequence([], [], state), do: {:ok, state}

  defp consume_standard_contract_sequence(
         pristine,
         [%{kind: :picture} | final],
         %{
           signature_pending?: true
         } = state
       ) do
    state =
      state
      |> Map.put(:signature_pending?, false)
      |> mark_standard_contract_change("recipient_signature")

    consume_standard_contract_sequence(pristine, final, state)
  end

  defp consume_standard_contract_sequence(pristine, [%{kind: :table} = token | final], state) do
    schedule = standard_contract_table_matrix("performance_payment_schedule")

    if token.matrix == schedule and valid_inserted_schedule_token?(token) and
         not MapSet.member?(state.used, "performance_payment_schedule") do
      consume_standard_contract_sequence(
        pristine,
        final,
        mark_standard_contract_change(state, "performance_payment_schedule")
      )
    else
      consume_standard_contract_pair(pristine, [token | final], state)
    end
  end

  defp consume_standard_contract_sequence(pristine, final, state),
    do: consume_standard_contract_pair(pristine, final, state)

  defp consume_standard_contract_pair([token | pristine], [token | final], state),
    do: consume_standard_contract_sequence(pristine, final, state)

  defp consume_standard_contract_pair([before | pristine], [final_token | final], state) do
    case standard_contract_replacement(before, final_token, state) do
      {:ok, id} ->
        state =
          state
          |> mark_standard_contract_change(id)
          |> Map.put(:signature_pending?, id == "party_table")

        consume_standard_contract_sequence(pristine, final, state)

      :error ->
        {:error,
         %{
           pristine: semantic_token_summary(before),
           final: semantic_token_summary(final_token),
           completed: state.used |> MapSet.to_list() |> Enum.sort()
         }}
    end
  end

  defp consume_standard_contract_pair([], [final_token | _final], state) do
    {:error,
     %{
       pristine: :end_of_projection,
       final: semantic_token_summary(final_token),
       completed: state.used |> MapSet.to_list() |> Enum.sort()
     }}
  end

  defp consume_standard_contract_pair([before | _pristine], [], state) do
    {:error,
     %{
       pristine: semantic_token_summary(before),
       final: :end_of_projection,
       completed: state.used |> MapSet.to_list() |> Enum.sort()
     }}
  end

  defp standard_contract_replacement(
         %{kind: :paragraph} = before,
         %{kind: :paragraph} = final_token,
         state
       ) do
    standard_contract_paragraph_edit_slots()
    |> Enum.find(fn slot ->
      not MapSet.member?(state.used, slot.id) and
        paragraph_before_matches?(before.text, slot.before) and final_token.text == slot.after and
        before.meta == final_token.meta
    end)
    |> case do
      %{id: id} -> {:ok, id}
      nil -> :error
    end
  end

  defp standard_contract_replacement(
         %{kind: :table} = before,
         %{kind: :table} = final_token,
         state
       ) do
    standard_contract_table_edit_slots()
    |> Enum.find(fn slot ->
      not MapSet.member?(state.used, slot.id) and
        standard_contract_table_before_matches?(before.matrix, slot.before) and
        final_token.matrix == slot.after and
        table_replacement_structure_valid?(before, final_token)
    end)
    |> case do
      %{id: id} -> {:ok, id}
      nil -> :error
    end
  end

  defp standard_contract_replacement(_before, _after, _state), do: :error

  defp table_replacement_structure_valid?(before, final_token) do
    before.coordinate_issues == [] and final_token.coordinate_issues == [] and
      before.table_meta == final_token.table_meta and before.cells == final_token.cells and
      before.extras == final_token.extras
  end

  defp valid_inserted_schedule_token?(token) do
    expected_coordinates = for row <- 0..3, col <- 0..3, do: {row, col}

    token.coordinate_issues == [] and token.extras == [] and
      (token.coordinates == [] or Enum.sort(token.coordinates) == expected_coordinates)
  end

  defp mark_standard_contract_change(state, id),
    do: %{state | used: MapSet.put(state.used, id)}

  defp standard_contract_expected_changes do
    paragraph_ids = Enum.map(standard_contract_paragraph_edit_slots(), & &1.id)
    table_ids = Enum.map(standard_contract_table_edit_slots(), & &1.id)

    MapSet.new(
      paragraph_ids ++ table_ids ++ ["performance_payment_schedule", "recipient_signature"]
    )
  end

  defp semantic_token_summary(%{kind: :paragraph, text: text}),
    do: %{kind: :paragraph, text: text}

  defp semantic_token_summary(%{kind: :table, matrix: matrix, coordinate_issues: issues}),
    do: %{kind: :table, matrix: matrix, coordinate_issues: issues}

  defp semantic_token_summary(%{kind: :picture}), do: %{kind: :picture}

  defp semantic_token_summary(%{kind: :payload, type: type}),
    do: %{kind: :payload, type: type}

  defp semantic_token_summary(token), do: token

  defp standard_contract_paragraph_edit_slots do
    [
      paragraph_edit_slot("contract_name", {:prefix, "◇ 계약명 :"}),
      paragraph_edit_slot("contract_period", {:prefix, "◇ 계약기간 :"}),
      paragraph_edit_slot("contract_amount", {:prefix, "◇ 계약 금액 :"}),
      paragraph_edit_slot(
        "party_intro",
        {:contains_all, ["(이하 ‘원사업자’)", "(이하 ‘수급사업자’)"]}
      ),
      paragraph_edit_slot("signing_date", {:exact, "년 월 일"}),
      paragraph_edit_slot("supply_date", {:prefix, "◇ 원재료의 공급일 :"}),
      paragraph_edit_slot("supply_place", {:prefix, "◇ 원재료의 공급장소 :"}),
      paragraph_edit_slot("instruction_date", {:prefix, "◇ 교부일 :"}),
      paragraph_edit_slot(
        "instruction_lead",
        {:prefix, "◇ 성과물의 작성 개시예정일로부터 최소"}
      ),
      paragraph_edit_slot("delivery_date", {:prefix, "◇ 납품일자 :"}),
      paragraph_edit_slot("delivery_place", {:prefix, "◇ 납품장소 :"}),
      paragraph_edit_slot("performance_bond", {:prefix, "사. 계약이행보증금요율"}),
      paragraph_edit_slot("payment_bond", {:prefix, "아. 대금지급보증금요율"}),
      paragraph_edit_slot(
        "late_interest",
        {:prefix, "◇ 지연이자요율(대금 지급 지연) :"}
      ),
      paragraph_edit_slot("other_interest", {:prefix, "◇ 기타 지연이자요율 :"}),
      paragraph_edit_slot("delay_penalty", {:prefix, "차. 지체상금요율 :"}),
      paragraph_edit_slot("defect_period", {:prefix, "카. 하자담보책임기간 :"}),
      paragraph_edit_slot("indexation_none", {:prefix, "◇ 연동제 적용대상 없음"}),
      paragraph_edit_slot("indexation_all", {:prefix, "◇ 적용함 :"}),
      paragraph_edit_slot("indexation_partial", {:prefix, "◇ 일부 적용함 :"}),
      paragraph_edit_slot("indexation_excluded", {:prefix, "◇ 전부 적용하지 않음 :"}),
      paragraph_edit_slot("renewal_deadline", {:prefix, "하. 계약갱신 여부에 대한 최고기한 :"}),
      paragraph_edit_slot(
        "withholding_count",
        {:prefix, "거. 이행거절을 위한 기성금 등의 미지급 횟수 :"}
      ),
      %{
        id: "contract_body_end",
        before: {:prefix, "제51조(재판관할) 이 계약과 관련된 소는"},
        after:
          normalize(
            Enum.join(
              [@standard_contract_demo_jurisdiction | @standard_contract_demo_work_items],
              " "
            )
          )
      }
    ]
  end

  defp paragraph_edit_slot(id, before_matcher) do
    requirement =
      Enum.find(@standard_contract_demo_requirements.texts, &(&1.id == id))

    %{id: id, before: before_matcher, after: normalize(requirement.exact)}
  end

  defp paragraph_before_matches?(text, {:exact, expected}),
    do: text == normalize(expected)

  defp paragraph_before_matches?(text, {:prefix, prefix}),
    do: String.starts_with?(text, normalize(prefix))

  defp paragraph_before_matches?(text, {:contains_all, fragments}),
    do: Enum.all?(fragments, &String.contains?(text, normalize(&1)))

  defp standard_contract_table_edit_slots do
    [
      %{id: "payment_table", before: :payment_table},
      %{id: "party_table", before: :party_table},
      %{id: "arbitrator", before: :arbitrator}
    ]
    |> Enum.map(fn slot ->
      Map.put(slot, :after, standard_contract_table_matrix(slot.id))
    end)
  end

  defp standard_contract_table_before_matches?([headers | _rows], :payment_table),
    do: row_matches?(headers, ["구분", "비율", "지급금액", "지급기일", "지급방법"])

  defp standard_contract_table_before_matches?([headers | _rows], :party_table),
    do: row_matches?(headers, ["원사업자", "수급사업자"])

  defp standard_contract_table_before_matches?([[first | _rest] | _rows], :arbitrator),
    do: normalize(first) == "중재인 또는 중재기관"

  defp standard_contract_table_before_matches?(_matrix, _kind), do: false

  defp standard_contract_table_matrix(id) do
    requirement = Enum.find(@standard_contract_demo_requirements.tables, &(&1.id == id))

    [requirement.headers | Map.get(requirement, :rows, [])]
    |> canonical_matrix()
  end

  defp canonical_matrix(matrix) do
    Enum.map(matrix, fn row -> Enum.map(row, &normalize_expected_cell/1) end)
  end

  defp normalize_expected_cell(value) when is_binary(value), do: normalize(value)
  defp normalize_expected_cell(value) when is_list(value), do: normalize(Enum.join(value, " "))

  defp expanded_table_coordinate_issues(payloads) do
    cells = Enum.filter(payloads, &match?(%{"type" => "cell"}, &1))

    if cells == [] do
      []
    else
      {valid, invalid} =
        Enum.split_with(cells, fn
          %{"row" => row, "col" => col}
          when is_integer(row) and row >= 0 and is_integer(col) and col >= 0 ->
            true

          _cell ->
            false
        end)

      coordinates = Enum.map(valid, &{&1["row"], &1["col"]})

      duplicates =
        coordinates
        |> Enum.frequencies()
        |> Enum.flat_map(fn
          {coordinate, count} when count > 1 -> [%{coordinate: coordinate, count: count}]
          _entry -> []
        end)
        |> Enum.sort()

      []
      |> maybe_coordinate_issue(invalid != [], :invalid, %{count: length(invalid)})
      |> maybe_coordinate_issue(duplicates != [], :duplicate, duplicates)
      |> Enum.reverse()
    end
  end

  defp expanded_table_coordinates(payloads) do
    Enum.flat_map(payloads, fn
      %{"type" => "cell", "row" => row, "col" => col}
      when is_integer(row) and row >= 0 and is_integer(col) and col >= 0 ->
        [{row, col}]

      _payload ->
        []
    end)
  end

  defp table_entry_coordinate_issues(%{expanded?: false}, _requirement), do: []

  defp table_entry_coordinate_issues(entry, requirement) do
    dimensions = Map.get(requirement, :dimensions)
    allowed_missing = Map.get(requirement, :allowed_missing_coordinates, [])

    missing =
      case dimensions do
        {rows, cols} when rows > 0 and cols > 0 ->
          expected = for row <- 0..(rows - 1), col <- 0..(cols - 1), do: {row, col}
          (expected -- Enum.uniq(entry.coordinates)) -- allowed_missing

        _dimensions ->
          []
      end

    entry.coordinate_issues
    |> maybe_coordinate_issue(missing != [], :missing, missing)
    |> Enum.reverse()
  end

  defp maybe_coordinate_issue(issues, true, kind, detail),
    do: [%{kind: kind, detail: detail} | issues]

  defp maybe_coordinate_issue(issues, false, _kind, _detail), do: issues

  defp table_candidate?([first_row | _rows] = matrix, headers, requirement) do
    if Map.get(requirement, :reject_any_duplicate_candidate, false) do
      headers_shared?(first_row, headers) or
        candidate_dimension_matches?(
          matrix,
          Map.get(requirement, :duplicate_candidate_dimensions)
        )
    else
      row_matches?(first_row, headers)
    end
  end

  defp table_candidate?(_matrix, _headers, _requirement), do: false

  defp candidate_dimension_matches?(_matrix, nil), do: false

  defp candidate_dimension_matches?(matrix, dimensions),
    do: dimension_matches?(matrix, dimensions)

  defp headers_shared?(actual, expected) do
    actual = Enum.map(actual, &normalize_cell/1)
    expected = Enum.map(expected, &normalize_cell/1)
    ordered_subsequence?(actual, expected)
  end

  defp ordered_subsequence?(_actual, []), do: true
  defp ordered_subsequence?([], _expected), do: false

  defp ordered_subsequence?([actual | actual_rest], [expected | expected_rest] = expected_all) do
    if actual == expected do
      ordered_subsequence?(actual_rest, expected_rest)
    else
      ordered_subsequence?(actual_rest, expected_all)
    end
  end

  defp projection_blocks(term) when is_list(term) do
    if Enum.any?(term, &payload?/1) do
      [term]
    else
      Enum.flat_map(term, &projection_blocks/1)
    end
  end

  defp projection_blocks(_term), do: []

  defp payload?(%{"type" => type}) when is_binary(type), do: true
  defp payload?(_term), do: false

  defp block_paragraphs(block) do
    Enum.flat_map(block, fn
      %{"type" => "paragraph", "text" => text} when is_binary(text) -> [text]
      _payload -> []
    end)
  end

  defp logical_lines(text) when is_binary(text) do
    lines = text |> String.split(~r/\R/u, trim: false) |> Enum.map(&normalize/1)

    lines
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  defp schedule_candidate_blocks(blocks, headers) do
    blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, index} ->
      block
      |> indexed_table_matrices()
      |> Enum.flat_map(fn
        {table_index, [first_row | _rows]} ->
          if headers_shared?(first_row, headers),
            do: [{block, index, table_index}],
            else: []

        {_table_index, _matrix} ->
          []
      end)
    end)
  end

  defp scope_body_end_schedule_blocks(candidates, [{_article, article_index}], annex_index)
       when is_integer(annex_index) and annex_index > article_index do
    Enum.filter(candidates, fn {_block, block_index, _table_index} ->
      block_index >= article_index and block_index < annex_index
    end)
  end

  defp scope_body_end_schedule_blocks(_candidates, _article_blocks, _annex_index), do: []

  defp body_end_4x4_tables(blocks, [{_article, article_index}], annex_index)
       when is_integer(annex_index) and annex_index > article_index do
    blocks
    |> Enum.with_index()
    |> Enum.filter(fn {_block, index} -> index >= article_index and index < annex_index end)
    |> Enum.flat_map(fn {block, index} ->
      block
      |> matrix_from_payload_list()
      |> Enum.filter(&dimension_matches?(&1, {4, 4}))
      |> Enum.map(fn _matrix -> index end)
    end)
  end

  defp body_end_4x4_tables(_blocks, _article_blocks, _annex_index), do: []

  defp validate_body_schedule_duplicates(id, candidates) when length(candidates) > 1 do
    [
      %{
        id: id,
        reason: :duplicate_body_end_schedule,
        detail: %{count: length(candidates), blocks: candidates}
      }
    ]
  end

  defp validate_body_schedule_duplicates(_id, _candidates), do: []

  defp schedule_follows_article_in_block?(block, article_line, table_index) do
    article_index =
      Enum.find_index(block, fn
        %{"type" => "paragraph", "text" => text} when is_binary(text) ->
          case logical_lines(text) do
            [^article_line | _rest] -> true
            _other -> false
          end

        _payload ->
          false
      end)

    is_integer(article_index) and is_integer(table_index) and table_index > article_index and
      block
      |> Enum.slice(article_index + 1, table_index - article_index - 1)
      |> Enum.all?(fn
        %{"type" => type} when type in ["paragraph", "table"] -> false
        _payload -> true
      end)
  end

  defp schedule_starts_block?(block, table_index) do
    case table_index do
      index when is_integer(index) and index >= 0 ->
        block
        |> Enum.take(index)
        |> Enum.all?(&empty_paragraph_payload?/1)

      _not_found ->
        false
    end
  end

  defp empty_paragraph_block?(block) when is_list(block) and block != [],
    do: Enum.all?(block, &empty_paragraph_payload?/1)

  defp empty_paragraph_block?(_block), do: false

  defp empty_paragraph_payload?(%{"type" => "paragraph", "text" => text})
       when is_binary(text),
       do: logical_lines(text) == []

  defp empty_paragraph_payload?(_payload), do: false

  defp table_matches?(matrix, requirement) do
    dimension_matches?(matrix, Map.get(requirement, :dimensions)) and
      rows_match?(matrix, Map.get(requirement, :rows, []))
  end

  defp dimension_matches?(_matrix, nil), do: true

  defp dimension_matches?(matrix, {expected_rows, expected_cols}) do
    length(matrix) == expected_rows and
      Enum.all?(matrix, &(length(&1) == expected_cols))
  end

  defp rows_match?(_matrix, []), do: true

  defp rows_match?([_headers | actual_rows], expected_rows) do
    expected_rows
    |> Enum.with_index()
    |> Enum.all?(fn {expected, index} ->
      case Enum.at(actual_rows, index) do
        nil -> false
        actual -> row_matches?(actual, expected)
      end
    end)
  end

  defp rows_match?([], _expected_rows), do: false

  defp row_matches?(actual, expected) when length(actual) == length(expected) do
    Enum.zip(actual, expected)
    |> Enum.all?(fn {actual_cell, expected_cell} -> cell_matches?(actual_cell, expected_cell) end)
  end

  defp row_matches?(_actual, _expected), do: false

  defp cell_matches?(actual, expected) when is_binary(expected),
    do: normalize(actual) == normalize(expected)

  defp cell_matches?(actual, expected) when is_list(expected),
    do: normalize(actual) == normalize(Enum.join(expected, " "))

  defp cell_matches?(_actual, _expected), do: false

  defp requirement_id(%{id: id}) when is_binary(id), do: id
  defp requirement_id(_requirement), do: "unnamed"

  defp decode_projection(projection) when is_list(projection), do: {:ok, projection}

  defp decode_projection(projection) when is_binary(projection) do
    case Jason.decode(projection) do
      {:ok, tree} when is_list(tree) -> {:ok, tree}
      {:ok, _other} -> {:error, :root_not_array}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_projection(_projection), do: {:error, :unsupported_input}

  defp payload_maps(term) when is_map(term), do: [term]
  defp payload_maps(term) when is_list(term), do: Enum.flat_map(term, &payload_maps/1)
  defp payload_maps(_term), do: []

  # Projection payloads are maps that occur as members of payload arrays. A
  # nested ref map can itself contain type: picture, but it is metadata rather
  # than another document picture and therefore must not affect global counts.
  defp projection_payloads(term) when is_list(term) do
    direct = Enum.filter(term, &payload?/1)

    nested =
      Enum.flat_map(term, fn
        %{} = map -> map |> Map.values() |> Enum.flat_map(&projection_payloads/1)
        list when is_list(list) -> projection_payloads(list)
        _value -> []
      end)

    direct ++ nested
  end

  defp projection_payloads(%{} = map) do
    map
    |> Map.values()
    |> Enum.flat_map(&projection_payloads/1)
  end

  defp projection_payloads(_term), do: []

  defp payload_lists(term) when is_list(term) do
    here =
      if Enum.any?(term, fn
           %{"type" => "table"} -> true
           _payload -> false
         end),
         do: [term],
         else: []

    here ++ Enum.flat_map(term, &payload_lists/1)
  end

  defp payload_lists(_term), do: []

  defp matrix_from_payload_list(payloads) do
    payloads
    |> indexed_table_matrices()
    |> Enum.map(&elem(&1, 1))
  end

  defp table_entries_from_payload_list(payloads) do
    table_indexes =
      payloads
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{"type" => "table"}, index} -> [index]
        _entry -> []
      end)

    table_indexes
    |> Enum.with_index()
    |> Enum.flat_map(fn {start_index, position} ->
      end_index = Enum.at(table_indexes, position + 1, length(payloads))
      table_payloads = Enum.slice(payloads, start_index, end_index - start_index)

      Enum.map(matrix_from_table_payloads(table_payloads), fn matrix ->
        %{
          table_index: start_index,
          matrix: matrix,
          expanded?: Enum.any?(table_payloads, &match?(%{"type" => "cell"}, &1)),
          coordinates: expanded_table_coordinates(table_payloads),
          coordinate_issues: expanded_table_coordinate_issues(table_payloads)
        }
      end)
    end)
  end

  defp indexed_table_matrices(payloads) do
    table_indexes =
      payloads
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{"type" => "table"}, index} -> [index]
        _entry -> []
      end)

    table_indexes
    |> Enum.with_index()
    |> Enum.flat_map(fn {start_index, position} ->
      end_index = Enum.at(table_indexes, position + 1, length(payloads))

      payloads
      |> Enum.slice(start_index, end_index - start_index)
      |> matrix_from_table_payloads()
      |> Enum.map(&{start_index, &1})
    end)
  end

  defp matrix_from_table_payloads(payloads) do
    table = Enum.find(payloads, &match?(%{"type" => "table"}, &1))
    expanded_cells? = Enum.any?(payloads, &match?(%{"type" => "cell"}, &1))

    cond do
      expanded_cells? ->
        case expanded_matrix(payloads) do
          [] -> []
          matrix -> [matrix]
        end

      is_map(table) and compact_matrix?(table["cells"]) ->
        [Enum.map(table["cells"], fn row -> Enum.map(row, &normalize_cell/1) end)]

      true ->
        []
    end
  end

  defp expanded_cells(payloads) do
    {cells, current} =
      Enum.reduce(payloads, {[], nil}, fn
        %{"type" => "cell", "row" => row, "col" => col}, {cells, current}
        when is_integer(row) and is_integer(col) ->
          {flush_expanded_cell(cells, current),
           %{row: row, col: col, payloads: [], paragraphs: []}}

        %{} = payload, {cells, %{} = current} ->
          paragraphs =
            if payload["type"] == "paragraph",
              do: current.paragraphs ++ [payload],
              else: current.paragraphs

          {cells, %{current | payloads: current.payloads ++ [payload], paragraphs: paragraphs}}

        _payload, acc ->
          acc
      end)

    flush_expanded_cell(cells, current)
  end

  defp flush_expanded_cell(cells, nil), do: cells
  defp flush_expanded_cell(cells, cell), do: cells ++ [cell]

  defp expanded_matrix(payloads) do
    {cells, current} =
      Enum.reduce(payloads, {%{}, nil}, fn
        %{"type" => "cell", "row" => row, "col" => col}, {cells, current}
        when is_integer(row) and is_integer(col) ->
          {flush_cell(cells, current), %{row: row, col: col, texts: []}}

        %{"type" => "paragraph", "text" => text}, {cells, %{texts: texts} = current}
        when is_binary(text) ->
          {cells, %{current | texts: texts ++ [text]}}

        _payload, acc ->
          acc
      end)

    cells = flush_cell(cells, current)

    case Map.keys(cells) do
      [] ->
        []

      keys ->
        max_row = keys |> Enum.map(&elem(&1, 0)) |> Enum.max()
        max_col = keys |> Enum.map(&elem(&1, 1)) |> Enum.max()

        for row <- 0..max_row do
          for col <- 0..max_col do
            Map.get(cells, {row, col}, "")
          end
        end
    end
  end

  defp flush_cell(cells, nil), do: cells

  defp flush_cell(cells, %{row: row, col: col, texts: texts}) do
    Map.put(
      cells,
      {row, col},
      texts |> Enum.reject(&(&1 == "")) |> Enum.join("\n") |> normalize()
    )
  end

  defp compact_matrix?(cells) when is_list(cells) and cells != [],
    do: Enum.all?(cells, &is_list/1)

  defp compact_matrix?(_cells), do: false

  defp normalize_cell(cell) when is_binary(cell), do: normalize(cell)
  defp normalize_cell(cell), do: cell |> to_string() |> normalize()

  defp scope_texts(texts, requirement) do
    after_anchor = Map.get(requirement, :after)
    before_anchor = Map.get(requirement, :before)

    start_index =
      case after_anchor do
        anchor when is_binary(anchor) ->
          case Enum.find_index(texts, &(&1 == normalize(anchor))) do
            nil -> length(texts)
            index -> index + 1
          end

        _none ->
          0
      end

    end_index =
      case before_anchor do
        anchor when is_binary(anchor) ->
          texts
          |> Enum.with_index()
          |> Enum.find_value(length(texts), fn {text, index} ->
            if index >= start_index and text == normalize(anchor), do: index, else: false
          end)

        _none ->
          length(texts)
      end

    texts
    |> Enum.slice(start_index, max(end_index - start_index, 0))
  end

  defp normalize(text) when is_binary(text) do
    text
    |> String.normalize(:nfc)
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp hwp_bin_data_streams(executable, document_path) do
    case System.cmd(executable, ["ls", document_path], stderr_to_stdout: true) do
      {output, 0} ->
        streams =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.starts_with?(&1, "BinData/"))
          |> Enum.uniq()

        {:ok, streams}

      {output, status} ->
        {:error, %{status: status, output: String.slice(output, 0, 200)}}
    end
  end

  defp native_marker_geometry(document_path, requirement) do
    cond do
      not File.regular?(document_path) ->
        {:error, :document_not_found}

      true ->
        case Ehwp.open(document_path, []) do
          {:ok, handle, _metadata} -> with_native_handle(handle, requirement)
          {:ok, handle} -> with_native_handle(handle, requirement)
          {:error, reason} -> {:error, {:open_failed, reason}}
          other -> {:error, {:unexpected_open_result, other}}
        end
    end
  rescue
    error -> {:error, {:native_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:native_exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp with_native_handle(handle, requirement) do
    try do
      native_marker_geometry_from_handle(handle, requirement)
    after
      Ehwp.close(handle)
    end
  end

  defp native_marker_geometry_from_handle(handle, requirement) do
    target = Map.fetch!(requirement, :target_text)
    marker = Map.fetch!(requirement, :marker)

    with {:ok, marker_offset, marker_length} <- marker_span(target, marker),
         {:ok, matches_json} <- Ehwp.find(handle, target, case_sensitive: true),
         {:ok, matches} <- Jason.decode(matches_json),
         {:ok, match} <- one_exact_native_match(matches, target),
         {:ok, cursor_base} <- native_cursor_base(match),
         {:ok, start_cursor} <-
           native_cursor_rect(handle, cursor_base, match["charOffset"] + marker_offset),
         {:ok, end_cursor} <-
           native_cursor_rect(
             handle,
             cursor_base,
             match["charOffset"] + marker_offset + marker_length
           ),
         {:ok, geometry} <- marker_geometry_from_cursors(start_cursor, end_cursor) do
      {:ok, geometry}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_native_result, other}}
    end
  end

  defp marker_span(target, marker)
       when is_binary(target) and is_binary(marker) and marker != "" do
    case String.split(target, marker, parts: 3) do
      [prefix, _suffix] -> {:ok, String.length(prefix), String.length(marker)}
      [_prefix, _middle, _suffix] -> {:error, :ambiguous_marker_in_target}
      [_target] -> {:error, :marker_not_in_target}
    end
  end

  defp marker_span(_target, _marker), do: {:error, :invalid_marker}

  defp one_exact_native_match(matches, target) when is_list(matches) do
    expected_length = String.length(target)

    exact =
      Enum.filter(matches, fn
        %{"charOffset" => offset, "length" => length}
        when is_integer(offset) and is_integer(length) ->
          length == expected_length

        _match ->
          false
      end)

    case exact do
      [match] -> {:ok, match}
      [] -> {:error, :native_target_not_found}
      matches -> {:error, {:ambiguous_native_target, length(matches)}}
    end
  end

  defp one_exact_native_match(_matches, _target), do: {:error, :invalid_native_find_result}

  defp native_cursor_base(%{
         "sec" => section,
         "charOffset" => char_offset,
         "cellContext" => %{
           "parentPara" => paragraph,
           "ctrlIdx" => control,
           "cellIdx" => cell,
           "cellPara" => cell_para
         }
       })
       when is_integer(section) and is_integer(char_offset) and is_integer(paragraph) and
              is_integer(control) and is_integer(cell) and is_integer(cell_para) do
    {:ok,
     %{
       q: "cursor_rect",
       section: section,
       paragraph: paragraph,
       control: control,
       cell: cell,
       cell_para: cell_para
     }}
  end

  defp native_cursor_base(_match), do: {:error, :native_target_has_no_cell_context}

  defp native_cursor_rect(handle, base, offset) when is_integer(offset) and offset >= 0 do
    case Ehwp.query(handle, Map.put(base, :offset, offset)) do
      {:ok, json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, cursor} when is_map(cursor) -> {:ok, cursor}
          {:ok, _other} -> {:error, :invalid_cursor_rect}
          {:error, reason} -> {:error, {:invalid_cursor_json, reason}}
        end

      {:error, reason} ->
        {:error, {:cursor_query_failed, reason}}

      other ->
        {:error, {:unexpected_cursor_query_result, other}}
    end
  end

  defp marker_geometry_from_cursors(
         %{
           "pageIndex" => page_index,
           "x" => start_x,
           "y" => start_y,
           "height" => start_height
         },
         %{"pageIndex" => page_index, "x" => end_x, "y" => end_y, "height" => end_height}
       )
       when is_integer(page_index) and is_number(start_x) and is_number(end_x) and
              is_number(start_y) and is_number(end_y) and is_number(start_height) and
              is_number(end_height) and start_height > 0 and end_height > 0 do
    if start_y == end_y and start_x != end_x do
      {:ok,
       %{
         page_index: page_index,
         left: min(start_x, end_x),
         right: max(start_x, end_x),
         top: start_y,
         bottom: start_y + max(start_height, end_height)
       }}
    else
      {:error, :marker_spans_multiple_native_lines}
    end
  end

  defp marker_geometry_from_cursors(_start_cursor, _end_cursor),
    do: {:error, :invalid_cursor_geometry}

  defp validation_issues(:ok), do: []
  defp validation_issues({:error, issues}) when is_list(issues), do: issues

  defp validation_result([]), do: :ok
  defp validation_result(issues), do: {:error, issues}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
