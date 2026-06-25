defmodule Ecrits.Doc.MCPToolPolicyTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.MCPToolPolicy
  alias Ecrits.Doc.Tools

  test "vfs mode advertises only doc.open_doc" do
    names =
      Tools.tools()
      |> MCPToolPolicy.restrict_for_vfs(true)
      |> Enum.map(&(&1["namespace"] <> "." <> &1["name"]))

    assert names == ["doc.open_doc"]
    refute "doc.close_doc" in names
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

  test "cached disallowed calls are directed back to the mounted file" do
    message = MCPToolPolicy.disabled_in_vfs_message("doc.close_doc")

    assert message["error"] == "disabled_in_fuse_mode"
    assert message["tool"] == "doc.close_doc"
    assert message["message"] =~ "Only doc.open_doc is available"
    assert message["message"] =~ "do not call doc.close_doc during edits"
    assert message["message"] =~ ".ecrits/mount/<name>.jsonl"
  end
end
