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

  test "mounted VFS preamble keeps ACP mutations while allowing shell search" do
    if Ecrits.Fuse.DocMount.enabled?() do
      prompt = Prompt.acp_preamble(doc_vfs_mounted: true)

      assert byte_size(prompt) <= 1900
      assert prompt =~ "do not edit read-only requests"
      assert prompt =~ "Open the document once with `doc.open_doc`"
      assert prompt =~ "do not discover MCP resources"
      assert prompt =~ "ACP read/search/edit for text and tables"
      assert prompt =~ "shell search stays read-only"
      assert prompt =~ "one paragraph group per line"
      assert prompt =~ "preserving each line's trailing comma"
      refute prompt =~ "Do not use resource discovery, shell/execute"
      refute prompt =~ "zsh, rg"
      assert prompt =~ "Keep every document mutation in ACP"
      assert prompt =~ "hwp5txt, raw-HWP extraction, or scripted shell rewrites"
      assert prompt =~ "For brief-driven fills"
      assert prompt =~ "every field, list item, and table row"
      assert prompt =~ "plausible value consistent with the user's request"
      assert prompt =~ "internally consistent wherever they recur"
      assert prompt =~ "never stamp placeholder markers"
      refute prompt =~ "미기재"
      assert prompt =~ "label, parentheses, and unit intact"
      assert prompt =~ "Reread the mounted file immediately before composing each write"
      assert prompt =~ "server may normalize between commits"
      assert prompt =~ "one post-commit `doc.find`"
      assert prompt =~ "one image-only `doc.edit`"
      assert prompt =~ "exactly one payload node per insert"
      assert prompt =~ "`table` node with `cells`"
      assert prompt =~ "new heading or paragraph nodes are structural"
      assert prompt =~ "marker must fit one rendered line"
      assert prompt =~ "On an EINVAL rejection"
      assert prompt =~ "restage the same change from that fresh read"
      assert prompt =~ "pass `occurrence` (1-based, document order)"
      refute prompt =~ "shell_tool = false"
      refute prompt =~ "before shell"
      refute prompt =~ "temp_path"
      refute prompt =~ "mounted_at"
      refute prompt =~ "first recipient"
      refute prompt =~ "work-content"
      refute prompt =~ "payment schedule"
      refute prompt =~ "unresolved template"
      refute prompt =~ "doc.context"
      refute prompt =~ "/private/tmp"
      refute prompt =~ "mv -f"
      refute prompt =~ "cellPath"
      refute prompt =~ "controlIndex"
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
