defmodule Contract.Local.ConfigStoreTest do
  use ExUnit.Case, async: true

  alias Contract.Local.ConfigStore
  alias Contract.Local.Metadata

  test "loads defaults before config exists" do
    root = tmp_root()

    assert {:ok, config} = ConfigStore.load(root)
    assert config["schema_version"] == Metadata.schema_version()
    assert config["workspaces"] == []
  end

  test "saves config atomically with schema version metadata" do
    root = tmp_root()

    assert :ok = ConfigStore.save(root, %{"locale" => "ko", "workspace_name" => "Matter"})
    assert {:ok, "ko"} = ConfigStore.get(root, :locale)
    assert {:ok, "Matter"} = ConfigStore.get(root, "workspace_name")

    assert {:ok, config} = ConfigStore.load(root)
    assert config["schema_version"] == Metadata.schema_version()
    assert config["locale"] == "ko"

    config_path = Path.join([root, ".contract", "config.json"])
    assert File.read!(config_path) =~ ~s("schema_version": #{Metadata.schema_version()})
  end

  test "put preserves existing config values" do
    root = tmp_root()

    assert :ok = ConfigStore.put(root, :locale, "en")
    assert :ok = ConfigStore.put(root, "theme", "system")

    assert {:ok, config} = ConfigStore.load(root)
    assert config["locale"] == "en"
    assert config["theme"] == "system"
  end

  defp tmp_root do
    root =
      Path.join(System.tmp_dir!(), "contract-local-config-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
