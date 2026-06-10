defmodule Ecrits.Local.ConfigStoreTest do
  use ExUnit.Case, async: true

  alias Ecrits.Local.ConfigStore
  alias Ecrits.Local.Metadata

  test "loads defaults before config exists" do
    root = tmp_root()

    assert {:ok, config} = ConfigStore.load(root)
    assert config["schema_version"] == Metadata.schema_version()
    assert config["workspaces"] == []
  end

  test "save is an ephemeral compatibility no-op" do
    root = tmp_root()

    assert :ok = ConfigStore.save(root, %{"locale" => "ko", "workspace_name" => "Matter"})
    assert {:ok, "fallback"} = ConfigStore.get(root, :locale, "fallback")
    assert {:ok, nil} = ConfigStore.get(root, "workspace_name")

    assert {:ok, config} = ConfigStore.load(root)
    assert config["schema_version"] == Metadata.schema_version()
    refute Map.has_key?(config, "locale")
    refute File.exists?(Path.join(root, ".ecrits"))
  end

  test "put does not persist config values" do
    root = tmp_root()

    assert :ok = ConfigStore.put(root, :locale, "en")
    assert :ok = ConfigStore.put(root, "theme", "system")

    assert {:ok, config} = ConfigStore.load(root)
    refute Map.has_key?(config, "locale")
    refute Map.has_key?(config, "theme")
    refute File.exists?(Path.join(root, ".ecrits"))
  end

  defp tmp_root do
    root =
      Path.join(System.tmp_dir!(), "ecrits-local-config-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
