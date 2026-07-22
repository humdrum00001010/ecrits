defmodule Ecrits.NormalizationSchemaBoundaryTest do
  use ExUnit.Case, async: true

  test "ACP Session does not own a second file-activity normalizer" do
    source = File.read!("lib/ecrits/acp_agent/session.ex")
    refute source =~ "defp normalize_file_activity_item("
  end

  test "document and VFS records have one schema authority" do
    sources =
      [
        "lib/ecrits/doc/tools.ex",
        "lib/ecrits/doc/op.ex",
        "lib/ecrits/fuse/open_docs.ex",
        "lib/ecrits_web/live/workspace/workspace_live.ex"
      ]
      |> Enum.map_join("\n", &File.read!/1)

    refute sources =~ "defp normalize_nearby("
    refute sources =~ "@known_op_keys"
    refute sources =~ "defp clean_lifecycle("
    refute sources =~ "defp normalize_vfs_edit_lifecycle_event("
  end

  test "workspace records have one schema authority" do
    sources =
      ["lib/ecrits/workspace/session.ex", "lib/ecrits/workspace_handoff.ex"]
      |> Enum.map_join("\n", &File.read!/1)

    for name <- [
          "normalize_agent_state",
          "normalize_adapter_opts",
          "normalize_foreground",
          "normalize_foregrounds",
          "normalize_session_documents",
          "normalize_agent_turn_owners",
          "normalize_turn_finalizations",
          "normalize_turn_finalization_active"
        ] do
      refute sources =~ "defp #{name}("
    end
  end
end
