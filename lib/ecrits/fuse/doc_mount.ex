defmodule Ecrits.Fuse.DocMount do
  @moduledoc """
  Stateless facade over `Exfuse` for the per-workspace document VFS mount.

  One mount per workspace, living at `<workspace_root>/.ecrits/mount`, serving
  `Ecrits.Fuse.DocFs` over the workspace root. There is NO GenServer here — this
  module only holds the `ensure`/`teardown` bookkeeping; `exfuse`'s own
  `Exfuse.MountSup` owns the port processes.

  `ensure/1` and `teardown/1` are defensive: they run from the workspace
  `Ecrits.Workspace.Session` GenServer (and a LiveView Task), so a mount failure
  (missing macFUSE, unbuilt port, FUSE error) must NEVER crash the caller. Both
  rescue/catch and log via `Logger`.

  Truth about "is it mounted?" comes from the OS mount table, not `Exfuse.list/0`
  (the Elixir side can lag / linger a stopping server). `Exfuse.umount/1` already
  does a clean kernel unmount (`umount` then `diskutil unmount force`) and stops
  the server normally, so `teardown/1` just trusts it.

  Gated by `enabled?/0`: the `:doc_vfs` config flag (default ON), the `exfuse`
  Rust port, and macFUSE. See `docs/plans/2026-06-23-exfuse-doc-vfs-migration.md`.
  """

  require Logger

  @macfuse_marker "/Library/Filesystems/macfuse.fs"

  @doc "The mount point for a workspace root: `<root>/.ecrits/mount` (root expanded)."
  @spec mount_point(String.t()) :: String.t()
  def mount_point(root), do: Path.join(Path.expand(root), ".ecrits/mount")

  @doc """
  Whether the doc VFS can be mounted on this machine: `:doc_vfs` config not
  disabled (default ON), the `exfuse` port present, and macFUSE installed.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config_enabled?() and port_available?() and macfuse_present?()
  end

  @doc "Whether the workspace's mount point is live in the OS mount table."
  @spec mounted?(String.t()) :: boolean()
  def mounted?(root), do: in_mount_table?(mount_point(root))

  # Mounted AND actually serving. A mount left by a prior crash/restart (port
  # killed without a clean unmount) lingers in the mount table but returns I/O
  # error FAST on access — so `ensure/1` must remount it, not report `:already`.
  defp mounted_and_live?(root) do
    point = mount_point(root)
    in_mount_table?(point) and live?(point)
  end

  # External probe (no BEAM `:file_server`): a healthy mount `ls`-es fast (cheap
  # ETS-backed readdir); a dead node returns non-zero (I/O error) fast.
  defp live?(point) do
    match?({_out, 0}, System.cmd("ls", [point], stderr_to_stdout: true))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  Idempotently mount the doc VFS for a workspace root.

  `:disabled` when `enabled?/0` is false, `{:ok, :already}` when already mounted,
  `{:ok, :mounted}` on a fresh mount, or `{:error, reason}`. Never raises.
  """
  @spec ensure(String.t()) :: :disabled | {:ok, :already | :mounted} | {:error, term()}
  def ensure(root) do
    cond do
      not enabled?() -> :disabled
      mounted_and_live?(root) -> {:ok, :already}
      true -> do_mount(root)
    end
  rescue
    error ->
      Logger.error("[DocMount] ensure crashed for #{inspect(root)}: #{inspect(error)}")
      {:error, error}
  catch
    kind, reason ->
      Logger.error("[DocMount] ensure crashed for #{inspect(root)}: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  @doc """
  Unmount the workspace's doc VFS. Treats absent/unmounted as success. Never
  raises. `Exfuse.umount/1` handles the kernel unmount + server stop.
  """
  @spec teardown(String.t()) :: :ok | {:error, term()}
  def teardown(root) do
    _ = Exfuse.umount(mount_point(root))
    :ok
  rescue
    error ->
      Logger.error("[DocMount] teardown crashed for #{inspect(root)}: #{inspect(error)}")
      {:error, error}
  catch
    kind, reason ->
      Logger.error("[DocMount] teardown crashed for #{inspect(root)}: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  # ── helpers ───────────────────────────────────────────────────────

  defp do_mount(root) do
    point = mount_point(root)
    # Clear any lingering/half-stopped server for this point (e.g. a concurrent
    # mounter raced us) so we don't end up with two servers on one mount point.
    _ = Exfuse.umount(point)
    ensure_clean_dir(point)

    case Exfuse.mount(point, Ecrits.Fuse.DocFs, %{root: Path.expand(root)}) do
      {:ok, _pid} ->
        if mount_serving?(point) do
          Logger.info("[DocMount] mounted doc VFS at #{point}")
          {:ok, :mounted}
        else
          # Port started but the kernel mount() never reached the mount table in
          # the settle window. Roll back so no dead, unservable mountpoint lingers.
          rollback_failed_mount(point)

          Logger.warning(
            "[DocMount] mount did not reach the kernel table at #{point}; rolled back"
          )

          {:error, :mount_not_serving}
        end

      {:error, reason} ->
        rollback_failed_mount(point)
        Logger.error("[DocMount] mount failed at #{point}: #{inspect(reason)}")
        {:error, reason}

      other ->
        rollback_failed_mount(point)
        Logger.error("[DocMount] unexpected mount result at #{point}: #{inspect(other)}")
        {:error, other}
    end
  end

  # Authoritative "is this point mounted?" — the OS mount table. macOS resolves
  # /tmp -> /private/tmp, so match the realpath too.
  defp in_mount_table?(point) do
    targets = Enum.uniq([point, real_path(point)])

    case System.cmd("mount", [], stderr_to_stdout: true) do
      {out, 0} -> Enum.any?(targets, &String.contains?(out, " on " <> &1 <> " "))
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # A fresh mount can take a moment to settle (longer right after a teardown), so
  # poll briefly before declaring it un-served.
  defp mount_serving?(point), do: mount_serving?(point, 8)
  defp mount_serving?(_point, 0), do: false

  defp mount_serving?(point, tries) do
    if in_mount_table?(point) do
      true
    else
      Process.sleep(250)
      mount_serving?(point, tries - 1)
    end
  end

  # mkdir_p the mount LEAF, healing a dead/stale mount node a prior teardown may
  # have left (mkdir over a dead FUSE node raises File.Error :enotdir).
  defp ensure_clean_dir(point) do
    File.mkdir_p!(point)
  rescue
    File.Error ->
      clean_leaf(point)
      File.mkdir_p!(point)
  end

  # Force-unmount + drop the mount LEAF only. Defensive; never raises, never
  # touches the parent dir (`.ecrits` is ecrits' own per-workspace store).
  defp clean_leaf(point) do
    Enum.each(Enum.uniq([point, real_path(point)]), fn p ->
      _ = System.cmd("umount", ["-f", p], stderr_to_stdout: true)
    end)

    _ = File.rmdir(point)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp rollback_failed_mount(point) do
    _ = Exfuse.umount(point)
    clean_leaf(point)
    clean_empty_parent(point)
  end

  defp clean_empty_parent(point) do
    _ = File.rmdir(Path.dirname(point))
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp real_path(point) do
    case System.cmd("realpath", [point], stderr_to_stdout: true) do
      {p, 0} -> String.trim(p)
      _ -> point
    end
  end

  defp config_enabled? do
    :ecrits
    |> Application.get_env(:doc_vfs, [])
    |> Keyword.get(:enabled, true) != false
  end

  defp port_available? do
    match?({:ok, _}, Exfuse.App.find_port!())
  rescue
    _ -> false
  end

  defp macfuse_present?, do: File.dir?(@macfuse_marker)
end
