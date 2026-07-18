defmodule Ecrits.Workspace.FileIndexTest do
  use ExUnit.Case, async: true

  alias Ecrits.Workspace.FileIndex

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-file-index-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "assets"))
    File.mkdir_p!(Path.join(root, ".hidden"))
    File.mkdir_p!(Path.join(root, ".ecrits"))
    File.write!(Path.join(root, "프로젝트_브리프.md"), "brief")
    File.write!(Path.join(root, "assets/서명.png"), "png")
    File.write!(Path.join(root, "contract.hwp"), "raw")
    File.write!(Path.join(root, ".hidden/secret.md"), "secret")
    File.write!(Path.join(root, ".ecrits/contract.hwp.jsonl"), "{}")

    outside = root <> "-outside.md"
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(root, "linked.md"))

    on_exit(fn ->
      File.rm_rf(root)
      File.rm(outside)
    end)

    %{root: root}
  end

  test "lists code-editor evidence and picture paths without hidden, raw, or linked files", %{
    root: root
  } do
    assert {:ok, files} = FileIndex.list(root)

    assert files == [
             %{
               "absolute_path" => Path.join(root, "assets/서명.png"),
               "kind" => "picture",
               "path" => "assets/서명.png"
             },
             %{
               "absolute_path" => Path.join(root, "프로젝트_브리프.md"),
               "kind" => "text",
               "path" => "프로젝트_브리프.md"
             }
           ]
  end
end
