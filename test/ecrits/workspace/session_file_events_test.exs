defmodule Ecrits.Workspace.SessionFileEventsTest do
  use ExUnit.Case, async: false

  alias Ecrits.Workspace.Session

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "ecrits-session-file-events-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)

    on_exit(fn ->
      if pid = Session.whereis(path) do
        GenServer.stop(pid, :normal, 1_000)
      end

      File.rm_rf(path)
    end)

    {:ok, path: path}
  end

  test "file watcher is shared per workspace session and broadcasts events", %{path: path} do
    assert :ok = Session.subscribe_file_events(path)

    session = Session.whereis(path)
    %{fs_watcher_pid: watcher} = :sys.get_state(session)
    assert is_pid(watcher)

    assert :ok = Session.subscribe_file_events(path)
    assert %{fs_watcher_pid: ^watcher} = :sys.get_state(session)

    changed_path = Path.join(path, "changed.txt")
    send(session, {:file_event, watcher, {changed_path, [:created]}})

    assert_receive {:workspace_fs_event, ^changed_path}, 1_000
  end
end
