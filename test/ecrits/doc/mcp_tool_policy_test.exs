defmodule Ecrits.Doc.MCPToolPolicyTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.MCPToolPolicy
  alias Ecrits.Doc.Tools

  test "vfs mode advertises current metadata and a primary entry plus a gated fallback" do
    tools =
      Tools.tools()
      |> MCPToolPolicy.restrict_for_vfs(true)

    names = Enum.map(tools, &(&1["namespace"] <> "." <> &1["name"]))

    assert names == ["doc.open_doc", "doc.find", "doc.edit"]
    refute "doc.context" in names
    refute "doc.close_doc" in names

    open_doc_tool = Enum.find(tools, &(&1["name"] == "open_doc"))
    find_tool = Enum.find(tools, &(&1["name"] == "find"))
    edit_tool = Enum.find(tools, &(&1["name"] == "edit"))

    assert open_doc_tool["description"] =~ "current workspace document once"
    assert open_doc_tool["description"] =~ "mounted ACP projection"
    assert open_doc_tool["description"] =~ "document id"
    refute open_doc_tool["description"] =~ "JSONL"
    refute open_doc_tool["description"] =~ "mounted_at"

    assert find_tool["description"] =~ "One post-commit marker lookup only"
    assert find_tool["description"] =~ "before_marker_ref"
    assert find_tool["description"] =~ "containing its existing marker exactly once"
    refute find_tool["description"] =~ "ending in"
    assert get_in(find_tool, ["annotations", "readOnlyHint"])
    assert "marker" in Map.keys(get_in(find_tool, ["inputSchema", "properties"]))
    assert get_in(find_tool, ["inputSchema", "additionalProperties"]) == false
    assert get_in(find_tool, ["inputSchema", "properties", "marker", "minLength"]) == 1
    refute Map.has_key?(get_in(find_tool, ["inputSchema", "properties", "marker"]), "const")
    assert get_in(find_tool, ["inputSchema", "properties", "limit", "const"]) == 1

    assert edit_tool["description"] =~ "Fallback only"
    assert edit_tool["description"] =~ "requested picture"
    assert edit_tool["description"] =~ "text or table edits never belong here"
    assert edit_tool["description"] =~ "placement and sizing are server-owned"
    assert edit_tool["description"] =~ "doc.open_doc"
    assert "fallback" in get_in(edit_tool, ["inputSchema", "required"])
    assert "document" in get_in(edit_tool, ["inputSchema", "required"])

    assert Map.keys(get_in(edit_tool, ["inputSchema", "properties"])) |> Enum.sort() ==
             ["document", "fallback", "op"]

    assert get_in(edit_tool, ["inputSchema", "properties", "op", "properties", "op", "enum"]) ==
             ["insert_picture"]

    assert get_in(edit_tool, ["inputSchema", "properties", "op", "required"]) == [
             "op",
             "ref",
             "src"
           ]

    op_properties = get_in(edit_tool, ["inputSchema", "properties", "op", "properties"])
    refute "inline_in_cell" in Map.keys(op_properties)
    refute "overlay_marker_length" in Map.keys(op_properties)
    refute "width" in Map.keys(op_properties)
    refute "height" in Map.keys(op_properties)

    refute "query" in Map.keys(
             get_in(edit_tool, ["inputSchema", "properties", "op", "properties"])
           )

    refute "replacement" in Map.keys(
             get_in(edit_tool, ["inputSchema", "properties", "op", "properties"])
           )

    refute "cells" in Map.keys(
             get_in(edit_tool, ["inputSchema", "properties", "op", "properties"])
           )

    assert get_in(edit_tool, ["inputSchema", "properties", "fallback", "required"]) == [
             "attempted",
             "reason",
             "detail",
             "mounted_at"
           ]

    assert get_in(edit_tool, [
             "inputSchema",
             "properties",
             "fallback",
             "properties",
             "reason",
             "enum"
           ]) == ["unrepresentable"]
  end

  test "non-vfs mode keeps the normal doc tool catalog" do
    normal_names = Enum.map(Tools.tools(), &(&1["namespace"] <> "." <> &1["name"]))

    names =
      Tools.tools()
      |> MCPToolPolicy.restrict_for_vfs(false)
      |> Enum.map(&(&1["namespace"] <> "." <> &1["name"]))

    assert names == normal_names
    assert "doc.close_doc" in names
  end

  test "cached disallowed calls return a compact primary-surface policy" do
    message = MCPToolPolicy.disabled_in_vfs_message("doc.close_doc")

    assert message["error"] == "disabled_in_fuse_mode"
    assert message["tool"] == "doc.close_doc"
    assert byte_size(message["message"]) < 250
    assert message["message"] =~ "primary workspace document surface"
    assert message["message"] =~ "doc.edit"
    refute message["message"] =~ "JSONL"
    refute message["message"] =~ "table"
  end

  test "doc.edit fallback requires explicit fields and only admits native-only unrepresentable ops" do
    assert {:error, %{"error" => "disabled_in_fuse_mode"}} =
             MCPToolPolicy.authorize_vfs_call("doc.context", %{})

    assert :ok = MCPToolPolicy.authorize_vfs_call("doc.find", %{})

    assert {:error, %{"error" => "vfs_fallback_required"} = error} =
             MCPToolPolicy.authorize_vfs_call("doc.edit", %{})

    assert error["required_fallback"]["attempted"] == "vfs"

    assert {:error, %{"error" => "vfs_fallback_required"}} =
             MCPToolPolicy.authorize_vfs_call("doc.edit", %{
               "fallback" => %{
                 "attempted" => "vfs",
                 "reason" => "unrepresentable",
                 "detail" => "",
                 "mounted_at" => "/workspace/.ecrits/document.hwp.jsonl"
               }
             })

    assert {:error, %{"error" => "vfs_fallback_required"}} =
             MCPToolPolicy.authorize_vfs_call("doc.edit", %{
               "op" => %{"op" => "insert_picture"},
               "fallback" => %{
                 "attempted" => "vfs",
                 "reason" => "write_failed",
                 "detail" => "rename returned Input/output error",
                 "mounted_at" => "/workspace/.ecrits/document.hwp.jsonl"
               }
             })

    fallback = %{
      "attempted" => "vfs",
      "reason" => "unrepresentable",
      "detail" => "native-only placement",
      "mounted_at" => "/workspace/.ecrits/document.hwp.jsonl"
    }

    for op <- [
          %{"op" => "replace_text", "query" => "old", "replacement" => "new"},
          %{"op" => "set_cell", "ref" => "cell", "text" => "value"},
          %{"op" => "insert_table", "ref" => "paragraph", "rows" => 2, "cols" => 2}
        ] do
      assert {:error, %{"error" => "vfs_fallback_unrepresentable_required"}} =
               MCPToolPolicy.authorize_vfs_call("doc.edit", %{
                 "op" => op,
                 "fallback" => fallback
               })
    end

    assert {:error, %{"error" => "vfs_fallback_unrepresentable_required"}} =
             MCPToolPolicy.authorize_vfs_call("doc.edit", %{
               "op" => %{"op" => "insert_picture"},
               "fallback" => %{
                 "attempted" => "vfs",
                 "reason" => "unrepresentable",
                 "detail" => "requested image placement",
                 "mounted_at" => "/workspace/.ecrits/document.hwp.jsonl"
               }
             })

    assert :ok =
             MCPToolPolicy.authorize_vfs_call("doc.edit", %{
               "op" => %{
                 "op" => "insert_picture",
                 "ref" =>
                   Jason.encode!(%{
                     "section" => 0,
                     "paragraph" => 76,
                     "offset" => 16
                   }),
                 "src" => "/workspace/assets/stamp.png"
               },
               "fallback" => %{
                 "attempted" => "vfs",
                 "reason" => "unrepresentable",
                 "detail" => "the user requested a stamp picture immediately before [[APPROVED]]",
                 "mounted_at" => "/workspace/.ecrits/document.hwp.jsonl"
               }
             })

    precise_picture = %{
      "op" => "insert_picture",
      "ref" =>
        Jason.encode!(%{
          "section" => 0,
          "paragraph" => 76,
          "offset" => 16
        }),
      "src" => "/workspace/assets/stamp.png"
    }

    for extra <- [
          %{"width" => 999},
          %{"height" => 999},
          %{"inline_in_cell" => true},
          %{"overlay_marker_length" => 99},
          %{"x" => 1, "y" => 2}
        ] do
      assert {:error, %{"error" => "vfs_fallback_unrepresentable_required"}} =
               MCPToolPolicy.authorize_vfs_call("doc.edit", %{
                 "op" => Map.merge(precise_picture, extra),
                 "fallback" => fallback
               })
    end

    assert {:error, %{"error" => "vfs_fallback_unrepresentable_required"}} =
             MCPToolPolicy.authorize_vfs_call("doc.edit", %{
               "ops" => [precise_picture, %{"op" => "set_cell", "ref" => "cell", "text" => "x"}],
               "fallback" => fallback
             })

    assert {:error, %{"error" => "vfs_fallback_unrepresentable_required"}} =
             MCPToolPolicy.authorize_vfs_call("doc.edit", %{
               "op" => %{"op" => "insert_footnote"},
               "fallback" => fallback
             })
  end

  test "mounted ACP sequence accepts one generic exact existing-marker picture ref" do
    sequence = MCPToolPolicy.new_vfs_sequence()

    assert {:error, %{"error" => "native_marker_find_before_open"}} =
             MCPToolPolicy.authorize_vfs_sequence("doc.find", %{}, sequence)

    assert {:error, %{"error" => "doc_open_required_first"}} =
             MCPToolPolicy.authorize_vfs_sequence("doc.context", %{}, sequence)

    assert {:error, %{"error" => "current_document_open_required"}} =
             MCPToolPolicy.authorize_vfs_sequence(
               "doc.open_doc",
               %{"path" => "contract.hwp"},
               sequence
             )

    assert :ok =
             MCPToolPolicy.authorize_vfs_sequence(
               "doc.open_doc",
               %{"path" => "current"},
               sequence
             )

    sequence =
      MCPToolPolicy.record_vfs_open(
        sequence,
        %{
          "document" => "d_contract",
          "mounted_at" => "/workspace/.ecrits/contract.hwp.jsonl",
          "mount_name" => "contract.hwp",
          "path" => "/workspace/contract.hwp"
        },
        <<1>>
      )

    assert {:error, %{"error" => "doc_already_opened_for_turn"}} =
             MCPToolPolicy.authorize_vfs_sequence(
               "doc.open_doc",
               %{"path" => "current"},
               sequence
             )

    find_args = %{
      "document" => "d_contract",
      "pattern" => "Place the product photo at [[PHOTO]] before publishing",
      "type" => "paragraph",
      "marker" => "[[PHOTO]]",
      "case_sensitive" => true,
      "limit" => 1
    }

    assert {:error, %{"error" => "acp_commit_required"}} =
             MCPToolPolicy.authorize_vfs_sequence("doc.find", find_args, sequence, %{
               primary_committed?: false,
               exact_count: 1,
               committed_projection?: true
             })

    assert {:error, %{"error" => "exact_native_marker_find_required"}} =
             MCPToolPolicy.authorize_vfs_sequence(
               "doc.find",
               %{find_args | "pattern" => "Approved by Alex", "limit" => 20},
               sequence,
               %{
                 primary_committed?: true,
                 exact_count: 0,
                 committed_projection?: true
               }
             )

    assert :ok =
             MCPToolPolicy.authorize_vfs_sequence("doc.find", find_args, sequence, %{
               primary_committed?: true,
               exact_count: 1,
               committed_projection?: true
             })

    ref =
      Jason.encode!(%{
        "section" => 0,
        "paragraph" => 76,
        "offset" => 27
      })

    sequence =
      MCPToolPolicy.record_vfs_find(
        sequence,
        %{
          "matches" => [
            %{
              "before_marker_ref" => ref,
              "marker" => "[[PHOTO]]",
              "marker_offset" => 27
            }
          ]
        },
        find_args
      )

    assert %{
             phase: :native_marker_ref_ready,
             native_marker: "[[PHOTO]]",
             native_marker_offset: 27,
             native_marker_ref: ^ref
           } = sequence

    assert {:error, %{"error" => "native_marker_find_already_used"}} =
             MCPToolPolicy.authorize_vfs_sequence("doc.find", find_args, sequence, %{
               primary_committed?: true,
               exact_count: 1,
               committed_projection?: true
             })

    edit_args = %{
      "document" => "d_contract",
      "op" => %{
        "op" => "insert_picture",
        "ref" => ref,
        "src" => "/workspace/assets/product-photo.png"
      },
      "fallback" => %{
        "attempted" => "vfs",
        "reason" => "unrepresentable",
        "detail" => "the user requested a product photo at [[PHOTO]]",
        "mounted_at" => "/workspace/.ecrits/contract.hwp.jsonl"
      }
    }

    assert :ok = MCPToolPolicy.authorize_vfs_sequence("doc.edit", edit_args, sequence)

    assert {:error, %{"error" => "native_marker_ref_required"}} =
             MCPToolPolicy.authorize_vfs_sequence(
               "doc.edit",
               put_in(edit_args, ["op", "ref"], ref <> " "),
               sequence
             )

    sequence = MCPToolPolicy.record_vfs_edit(sequence)

    assert {:error, %{"error" => "native_marker_ref_required"}} =
             MCPToolPolicy.authorize_vfs_sequence("doc.edit", edit_args, sequence)
  end

  # 2026-07-19 field regression: a full brief-driven fill made every annex
  # signature row byte-identical ("대표자 성명 : 김에크리츠 (인)" x10), so the
  # unique-pattern lookup could not address the intended one and the failure
  # was misreported as a missing commit.
  test "repeated committed paragraphs are addressable with occurrence" do
    sequence =
      MCPToolPolicy.new_vfs_sequence()
      |> MCPToolPolicy.record_vfs_open(
        %{
          "document" => "d_contract",
          "mounted_at" => "/workspace/.ecrits/contract.hwp.jsonl",
          "mount_name" => "contract.hwp",
          "path" => "/workspace/contract.hwp"
        },
        <<1>>
      )

    find_args = %{
      "document" => "d_contract",
      "pattern" => "대표자 성명 : 김에크리츠 (인)",
      "type" => "paragraph",
      "marker" => "(인)",
      "case_sensitive" => true,
      "limit" => 1
    }

    committed = %{primary_committed?: true, committed_projection?: true}

    ambiguous =
      MCPToolPolicy.authorize_vfs_sequence(
        "doc.find",
        find_args,
        sequence,
        Map.put(committed, :exact_count, 10)
      )

    assert {:error, %{"error" => "find_pattern_ambiguous", "count" => 10, "message" => message}} =
             ambiguous

    assert message =~ "occurrence"
    assert message =~ "between 1 and 10"

    assert {:error, %{"error" => "find_pattern_not_committed", "message" => stale_message}} =
             MCPToolPolicy.authorize_vfs_sequence(
               "doc.find",
               find_args,
               sequence,
               Map.put(committed, :exact_count, 0)
             )

    assert stale_message =~ "reread the mounted projection"

    # both pattern-level failures earn the corrected retry; commit failures do not
    for {:error, reason} <- [ambiguous], do: assert(MCPToolPolicy.retryable_find_error?(reason))
    assert MCPToolPolicy.retryable_find_error?(%{"error" => "find_pattern_not_committed"})
    refute MCPToolPolicy.retryable_find_error?(%{"error" => "acp_commit_required"})
    refute MCPToolPolicy.retryable_find_error?(%{"error" => "exact_native_marker_find_required"})

    # once the retry is used, the same failure reads as terminal
    retried = Map.put(sequence, :find_retry_used?, true)

    assert {:error, %{"error" => "find_pattern_ambiguous", "message" => terminal_message}} =
             MCPToolPolicy.authorize_vfs_sequence(
               "doc.find",
               find_args,
               retried,
               Map.put(committed, :exact_count, 10)
             )

    assert terminal_message =~ "already used"

    # a valid ordinal authorizes; out-of-range or malformed ordinals do not
    assert :ok =
             MCPToolPolicy.authorize_vfs_sequence(
               "doc.find",
               Map.put(find_args, "occurrence", 7),
               sequence,
               Map.put(committed, :exact_count, 10)
             )

    assert {:error, %{"error" => "find_pattern_ambiguous", "message" => exceeded}} =
             MCPToolPolicy.authorize_vfs_sequence(
               "doc.find",
               Map.put(find_args, "occurrence", 11),
               sequence,
               Map.put(committed, :exact_count, 10)
             )

    assert exceeded =~ "occurrence 11 exceeds"

    for bad <- [0, -1, "3"] do
      assert {:error, %{"error" => "exact_native_marker_find_required"}} =
               MCPToolPolicy.authorize_vfs_sequence(
                 "doc.find",
                 Map.put(find_args, "occurrence", bad),
                 sequence,
                 Map.put(committed, :exact_count, 10)
               )
    end

    # occurrence rides as the internal search limit and never reaches the tool
    prepared = MCPToolPolicy.prepare_vfs_call("doc.find", Map.put(find_args, "occurrence", 7))
    assert prepared["limit"] == 7
    refute Map.has_key?(prepared, "occurrence")
    assert MCPToolPolicy.prepare_vfs_call("doc.find", find_args)["limit"] == 1
  end

  test "finalize_vfs_find_result selects the occurrence-th document-order match" do
    match = fn ref ->
      %{"before_marker_ref" => ref, "marker" => "(인)", "marker_offset" => 12}
    end

    result = %{"matches" => [match.("hwp:a"), match.("hwp:b"), match.("hwp:c")]}
    request = %{"marker" => "(인)", "occurrence" => 3}

    assert {:ok, %{"matches" => [%{"before_marker_ref" => "hwp:c"}]}} =
             MCPToolPolicy.finalize_vfs_find_result({:ok, result}, request)

    assert {:error, %{"error" => "native_marker_not_found"}} =
             MCPToolPolicy.finalize_vfs_find_result(
               {:ok, result},
               %{request | "occurrence" => 4}
             )

    # an unusable match shifts ordinals, so the selection must refuse
    broken = %{"matches" => [match.("hwp:a"), %{"marker" => "(인)"}, match.("hwp:c")]}

    assert {:error, %{"error" => "native_marker_not_found"}} =
             MCPToolPolicy.finalize_vfs_find_result({:ok, broken}, request)

    # without occurrence, distinct refs stay ambiguous
    assert {:error, %{"error" => "native_marker_not_unique", "count" => 3}} =
             MCPToolPolicy.finalize_vfs_find_result({:ok, result}, %{"marker" => "(인)"})
  end

  test "partial or failed open results never advance the turn" do
    awaiting = MCPToolPolicy.new_vfs_sequence()

    valid = %{
      "document" => "d_contract",
      "mounted_at" => "/workspace/.ecrits/contract.hwp.jsonl",
      "mount_name" => "contract.hwp",
      "path" => "/workspace/contract.hwp",
      "mount_error" => nil
    }

    for result <- [
          %{valid | "document" => nil},
          %{valid | "mounted_at" => nil},
          %{valid | "mount_error" => "projection unavailable"}
        ] do
      assert MCPToolPolicy.record_vfs_open(awaiting, result, <<1>>) == awaiting
    end

    assert MCPToolPolicy.record_vfs_open(awaiting, valid, nil) == awaiting

    assert %{phase: :acp_primary, baseline_revision: <<1>>} =
             MCPToolPolicy.record_vfs_open(awaiting, valid, <<1>>)
  end

  test "authorized marker edit derives server-owned overlay metadata without dimensions" do
    args = %{
      "document" => "d_contract",
      "op" => %{
        "op" => "insert_picture",
        "ref" => "exact-ref",
        "src" => "/workspace/assets/product-photo.png"
      },
      "fallback" => %{"reason" => "unrepresentable"}
    }

    prepared =
      MCPToolPolicy.prepare_vfs_call("doc.edit", args, %{
        native_marker: "[[PHOTO]]"
      })

    assert prepared["op"]["ref"] == "exact-ref"
    assert prepared["op"]["src"] == "/workspace/assets/product-photo.png"
    assert prepared["op"]["inline_in_cell"] == false
    assert prepared["op"]["overlay_marker_length"] == 9
    refute Map.has_key?(prepared["op"], "width")
    refute Map.has_key?(prepared["op"], "height")
    assert MCPToolPolicy.prepare_vfs_call("doc.find", args) == args
  end

  test "completed marker lookup is usable only when all returned evidence matches the request" do
    request = %{"marker" => "<SEAL>"}

    usable = %{
      "matches" => [
        %{
          "before_marker_ref" =>
            Jason.encode!(%{"section" => 2, "paragraph" => 14, "offset" => 22}),
          "marker" => "<SEAL>",
          "marker_offset" => 22
        }
      ]
    }

    assert {:ok, ^usable} = MCPToolPolicy.finalize_vfs_find_result({:ok, usable}, request)

    for unusable <- [
          %{"matches" => []},
          put_in(usable, ["matches", Access.at(0), "marker"], "<OTHER>"),
          put_in(usable, ["matches", Access.at(0), "marker_offset"], nil),
          put_in(usable, ["matches", Access.at(0), "before_marker_ref"], nil)
        ] do
      assert {:error, %{"error" => "native_marker_not_found", "message" => message}} =
               MCPToolPolicy.finalize_vfs_find_result({:ok, unusable}, request)

      assert message =~ "Do not call doc.find again"
    end
  end

  test "picture fallback rejects malformed and negative cell paths" do
    fallback = %{
      "attempted" => "vfs",
      "reason" => "unrepresentable",
      "detail" => "requested picture at an exact existing marker",
      "mounted_at" => "/workspace/.ecrits/contract.hwp.jsonl"
    }

    for bad_ref <- [
          %{"section" => 0, "paragraph" => 1, "offset" => 0, "cellPath" => []},
          %{
            "section" => 0,
            "paragraph" => 1,
            "offset" => 0,
            "cellPath" => [
              %{"controlIndex" => 0, "cellIndex" => -1, "cellParaIndex" => 0}
            ]
          },
          %{
            "section" => 0,
            "paragraph" => 1,
            "offset" => 0,
            "cellPath" => [%{"controlIndex" => 0, "cellIndex" => 1}]
          }
        ] do
      assert {:error, %{"error" => "vfs_fallback_unrepresentable_required"}} =
               MCPToolPolicy.authorize_vfs_call("doc.edit", %{
                 "op" => %{
                   "op" => "insert_picture",
                   "ref" => Jason.encode!(bad_ref),
                   "src" => "/workspace/assets/stamp.png"
                 },
                 "fallback" => fallback
               })
    end
  end
end
