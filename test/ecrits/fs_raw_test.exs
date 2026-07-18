defmodule Ecrits.FSRawTest do
  use ExUnit.Case, async: false

  alias Ecrits.FS

  test "raw callback IO stays independent while file_server_2 is occupied" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-fs-raw-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "document.hwp")
    File.mkdir_p!(root)
    File.write!(path, "before")

    on_exit(fn -> File.rm_rf(root) end)

    supervisor = start_supervised!(Task.Supervisor)
    file_server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(file_server)

    try do
      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          with {:ok, "before"} <- FS.raw_read(path),
               :ok <- FS.raw_atomic_write(path, "after"),
               {:ok, "after"} <- FS.raw_read(path) do
            :ok
          end
        end)

      assert :ok = Task.await(task, 1_000)
    after
      :ok = :sys.resume(file_server)
    end

    assert File.read!(path) == "after"
  end
end
