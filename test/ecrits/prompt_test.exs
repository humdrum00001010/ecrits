defmodule Ecrits.PromptTest do
  use ExUnit.Case, async: true

  alias Ecrits.Prompt

  test "does not retain global authoring recipes" do
    refute {:mcp_instructions, 0} in Prompt.__info__(:functions)
  end

  test "selected elements remain context without prescribing an edit workflow" do
    prompt =
      Prompt.with_selected_elements(
        "place the signature",
        [
          %{
            "document" => "contract.hwp",
            "type" => "picture",
            "ref" => %{"section" => 0, "paragraph" => 2, "control" => 1}
          }
        ],
        :fskit
      )

    assert prompt =~ "Selected document elements (1):"
    assert prompt =~ "Use this as target context"
    refute prompt =~ "doc.edit"
    refute prompt =~ "JSONL"
  end

  test "mounted VFS preamble allows direct edits or scripts without inventing a preflight tool" do
    if Ecrits.Fuse.DocMount.enabled?() do
      prompt = Prompt.acp_preamble(doc_vfs_mounted: true)

      ultracode_prompt =
        Prompt.acp_preamble(
          doc_vfs_mounted: true,
          reasoning_effort: "ultracode"
        )

      assert byte_size(prompt) <= 7_000
      assert byte_size(ultracode_prompt) <= 7_000
      assert prompt =~ "Call `doc.open_doc` once and use the returned mount path"
      assert prompt =~ "Python/Ruby writes are allowed"
      assert prompt =~ "Direct file edits and workspace-local helper scripts are both valid"
      assert prompt =~ "one fresh full read"
      assert prompt =~ "SOURCE → FIELDS → MAP → transform"
      assert prompt =~ "source-data sections only; exclude procedural instructions"
      assert prompt =~ "never authorize a blind fill loop"
      assert prompt =~ "MAP is the sole transform plan"
      assert prompt =~ "transform only MAP destinations"
      assert prompt =~ "Every source fact from source-data sections"
      assert prompt =~ "require `unmapped_source_facts == []`"
      assert prompt =~ "require `unresolved_fields == []`"
      assert prompt =~ "list any fact with no destination instead of silently dropping it"
      assert prompt =~ "Do not merely claim these lists are empty"
      assert prompt =~ "verify the complete inventories, never a sample"
      assert prompt =~ "Never initialize either result directly to `[]`"
      assert prompt =~ "Keep SOURCE values as complete source literals"
      assert prompt =~ "units or suffixes already present"
      assert prompt =~ "Generate every mutation from MAP"
      assert prompt =~ "preserve the pristine label, punctuation, spacing, parentheses, and units"
      assert prompt =~ "replace only the placeholder or value span"
      assert prompt =~ "prose facts such as jurisdiction"
      assert prompt =~ "validate the parsed candidate bytes before the first rename"
      assert prompt =~ "Post-commit checks are read-only"
      assert prompt =~ "the rehearsal failed rather than reopening the projection"
      assert prompt =~ "Freeze FIELDS from pristine before transform"
      assert prompt =~ "stable group/node position or table cell coordinates"
      assert prompt =~ "first complete field sequence as owner"
      assert prompt =~ "second as subcontractor"

      assert prompt =~
               "If the write returns EINVAL, treat the candidate as rejected, not as proof of a stale read"

      assert prompt =~
               "Remove every changed pristine-blank paragraph outside a proven table-cell value block"

      refute prompt =~ "retry the same change once from that fresh state"

      assert prompt =~
               "Parse and write the complete wrapper as one JSON value; never reconstruct line commas"

      assert prompt =~ "Do not investigate or repair stale `previewText`"

      assert prompt =~
               "After successful `doc.edit`, run no further shell, projection, or MCP call"

      refute prompt =~ "before the first numbered article"
      refute prompt =~ "repair stale data"
      refute prompt =~ "doc.preflight"
      refute prompt =~ "preflight_contract"
      refute prompt =~ "<mounted_at>.tmp"
      refute prompt =~ "mandatory code order"
      refute prompt =~ "write one workspace-local helper script"
      refute {:vfs_preflight_tool_description, 0} in Prompt.__info__(:functions)
    else
      assert true
    end
  end

  test "mounted VFS preamble protects table structure and native image ordering" do
    if Ecrits.Fuse.DocMount.enabled?() do
      prompt = Prompt.acp_preamble(doc_vfs_mounted: true)

      assert prompt =~ "`char` nodes are derived runs and must not be edited or audited"
      assert prompt =~ "Any paragraph before the first `cell` is structural"
      assert prompt =~ "must remain byte-for-byte unchanged"
      assert prompt =~ "Blank means `text.strip()` is empty"
      assert prompt =~ "Classify using visible labels and local cell structure"
      assert prompt =~ "blank or whitespace-only non-cell paragraph is layout"
      assert prompt =~ "its own cell block or labeled row proves that exact node"
      assert prompt =~ "zip values across every table `paragraph`"
      assert prompt =~ "Target by `cell` coordinates and visible label"
      assert prompt =~ "Preserve a label paragraph when its separate value paragraph"

      assert prompt =~ "Match pristine nodes by insertion-adjusted stable identity"
      assert prompt =~ "never positional-zip shifted group lists"

      refute prompt =~
               "compare each node at the same array position before and after the transform"

      assert prompt =~
               "Reject only when a matched node's own `text` changed and its new value contains a newline"

      assert prompt =~ "never add or replace a `cells` matrix on an existing table payload"

      assert prompt =~
               "If a proven value cell has no paragraph, set that existing `cell` node's `text`"

      assert prompt =~ "never insert a ref-less paragraph inside an existing table"
      assert prompt =~ "EINVAL means no durable commit"
      assert prompt =~ "stop before `doc.find` or `doc.edit`"
      assert prompt =~ "attach exactly one new `table` payload"
      assert prompt =~ "semantic preceding-anchor group"
      assert prompt =~ "Compute structural anchors from pristine before inserting"

      assert prompt =~
               "a successful table-inserting rename is the final projection write for the turn"

      assert prompt =~
               "never attach a table to that new paragraph group"

      assert prompt =~ "Use `doc.edit` only after the durable projection commit"
      assert prompt =~ "stop before the image edit"
      assert prompt =~ "Then verify read-only and never rewrite the projection"

      assert prompt =~
               "projection `previewText` and picture payloads are stale after the native edit"

      refute prompt =~ "FileLane"
      refute prompt =~ "search_text_file"
      refute prompt =~ "edit_text_file"
    else
      assert true
    end
  end

  test "VFS MCP copy stays compact and recipe-free" do
    open_doc = Prompt.vfs_open_doc_tool_description()
    fallback = Prompt.vfs_edit_fallback_tool_description()
    find = Prompt.vfs_native_ref_tool_description()

    assert byte_size(open_doc) < 300
    assert byte_size(fallback) < 300
    assert open_doc =~ "current workspace document once"
    assert open_doc =~ "mounted ACP projection"
    assert open_doc =~ "document id"
    assert open_doc =~ "ACP file tools"
    assert fallback =~ "Fallback only"
    assert fallback =~ "requested picture"
    assert fallback =~ "supplied file unchanged"
    assert fallback =~ "text or table edits never belong here"
    assert fallback =~ "placement and sizing are server-owned"
    assert find =~ "One post-commit marker lookup only"
    assert find =~ "exact requested target paragraph"
    assert find =~ "before_marker_ref verbatim"
    refute open_doc =~ "JSONL"
    refute fallback =~ "cellPath"
  end
end
