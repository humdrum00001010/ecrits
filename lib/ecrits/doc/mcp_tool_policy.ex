defmodule Ecrits.Doc.MCPToolPolicy do
  @moduledoc false

  @vfs_allowed_tools ~w(doc.open_doc)

  @spec vfs_allowed_tools() :: [String.t()]
  def vfs_allowed_tools, do: @vfs_allowed_tools

  @spec vfs_allowed?(String.t()) :: boolean()
  def vfs_allowed?(name), do: name in @vfs_allowed_tools

  @spec restrict_for_vfs([map()], boolean()) :: [map()]
  def restrict_for_vfs(tools, true) when is_list(tools) do
    Enum.filter(tools, &(tool_name(&1) in @vfs_allowed_tools))
  end

  def restrict_for_vfs(tools, _vfs_enabled), do: tools

  @spec disabled_in_vfs_message(String.t()) :: map()
  def disabled_in_vfs_message(name) do
    %{
      "error" => "disabled_in_fuse_mode",
      "tool" => name,
      "message" =>
        "FUSE mode: the document is a nested JSONL IR file " <>
          "([[[payload_node]]]). Read/find/edit payload node fields with native shell " <>
          "tools over `.ecrits/mount/<name>.jsonl` (cat/grep/sed). Never replace " <>
          "the file with one payload object and never look for mounted_at inside " <>
          "the JSONL; it is IR-only. Never create, copy, or edit fallback JSONL " <>
          "outside `.ecrits/mount`; `/tmp/<name>.jsonl` and workspace-root " <>
          "<name>.jsonl are fake scratch files that do not route to the document. " <>
          "If `.ecrits/mount/<name>.jsonl` is missing after `doc.open_doc`, stop " <>
          "and report that blocker. For whole-file rewrites, create the temp file " <>
          "inside `.ecrits/mount` and mv it over the target; do not use mktemp " <>
          "outside the mount or dd over the target. Insert pictures as a payload node inside an " <>
          "existing paragraph list such as " <>
          "{\"type\":\"picture\",\"src\":\"/abs/img.png\"}; ecrits chooses a readable " <>
          "default size from the image aspect, so width/height are only needed for " <>
          "intentional HWPUNIT resizing. Move by editing x/y/treatAsChar; resize by " <>
          "editing width/height; delete by removing that " <>
          "payload from its paragraph list. Only doc.open_doc is available as an " <>
          "MCP tool in VFS mode; do not call doc.close_doc during edits."
    }
  end

  defp tool_name(%{"namespace" => ns, "name" => name}) when is_binary(ns) and is_binary(name),
    do: ns <> "." <> name

  defp tool_name(%{"name" => name}) when is_binary(name), do: name
  defp tool_name(_tool), do: nil
end
