defmodule Ecrits.Fuse.DocMount do
  @moduledoc """
  Stateless facade over `Exfuse` for the per-workspace document VFS mount.

  One mount per workspace, living at `<workspace_root>/.ecrits/mount`, serving
  `Ecrits.Fuse.DocFs` over the workspace root. There is NO GenServer here — this
  module only holds the `ensure`/`teardown` bookkeeping; `exfuse`'s own
  `Exfuse.MountSup` owns the port processes.

  `ensure/1` and `teardown/1` are defensive: they run from the workspace
  `Ecrits.Workspace.Session` GenServer (and a LiveView Task), so a mount failure
  (missing native backend, FUSE/FSKit error) must NEVER crash the caller. Both
  rescue/catch and log via `Logger`.

  Truth about "is it mounted?" comes from the OS mount table, not `Exfuse.list/0`
  (the Elixir side can lag / linger a stopping server). `Exfuse.umount/1` already
  does a clean kernel unmount (`umount` then `diskutil unmount force`) and stops
  the server normally, so `teardown/1` just trusts it.

  Gated by `enabled?/0`: the `:doc_vfs` config flag (default ON) and a usable
  native backend. macOS auto mode is FSKit ONLY — when FSKit is not mountable
  the status explains why instead of silently falling back to the legacy
  macFUSE kext; FUSE on macOS is opt-in via `backend: :fuse` config or
  `EXFUSE_BACKEND=fuse`. Linux/other Unix defaults to the FUSE/libfuse Rust
  port. See `docs/plans/2026-06-23-exfuse-doc-vfs-migration.md`.
  """

  require Logger

  @fskit_extension_id "org.exfuse.fskit.extension"
  @fskit_settings_url "x-apple.systempreferences:com.apple.ExtensionsPreferences?extension-points"
  @macfuse_marker "/Library/Filesystems/macfuse.fs"

  @doc "The mount point for a workspace root: `<root>/.ecrits/mount` (root realpathed)."
  @spec mount_point(String.t()) :: String.t()
  def mount_point(root), do: Path.join(canonical_root(root), ".ecrits/mount")

  @doc false
  @spec canonical_root(String.t()) :: String.t()
  def canonical_root(root) when is_binary(root) do
    root = Path.expand(root)
    private_tmp_path(root) || root
  end

  @doc """
  Whether the doc VFS can be mounted on this machine: `:doc_vfs` config not
  disabled (default ON) and the selected backend has the local executables and
  OS extension enablement it needs.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    status().enabled?
  end

  @doc """
  Full local availability status for the selected doc VFS backend.

  `enabled?/0` intentionally stays boolean for fast gates, while this function is
  used by tools/prompts to explain why FSKit/FUSE is not mountable.
  """
  @spec status() :: %{
          enabled?: boolean(),
          backend: :fskit | :fuse,
          reason: atom() | nil,
          message: String.t() | nil,
          settings_url: String.t() | nil
        }
  def status do
    {mode, selected} = backend_choice()

    if config_enabled?() do
      status_for_choice(mode, selected)
    else
      unavailable(selected, :config_disabled)
    end
  end

  @doc false
  @spec status_message(map()) :: String.t()
  def status_message(%{reason: nil, backend: backend}),
    do: "Doc VFS #{backend} backend is available."

  def status_message(%{reason: :config_disabled}),
    do: "Doc VFS is disabled by :doc_vfs configuration."

  def status_message(%{reason: :fskit_requires_macos}),
    do: "FSKit backend is only available on macOS."

  def status_message(%{reason: :missing_mount}),
    do: "FSKit backend requires the macOS mount executable."

  def status_message(%{reason: :fskit_extension_not_registered}),
    do:
      "FSKit extension #{@fskit_extension_id} is not registered. Run exfuse.fskit.install first."

  def status_message(%{reason: :fskit_extension_disabled}),
    do:
      "FSKit extension #{@fskit_extension_id} is registered but disabled. Enable exfuse in System Settings > General > Login Items & Extensions > File System Extensions."

  def status_message(%{reason: :fskit_extension_unsigned}),
    do:
      "FSKit extension #{@fskit_extension_id} is registered but ad-hoc signed with the restricted FSKit entitlement; sign it with a trusted code-signing identity and reinstall it."

  def status_message(%{reason: :fuse_port_unavailable}),
    do: "FUSE backend port executable is unavailable."

  def status_message(%{reason: :fuse_backend_missing}),
    do: "FUSE backend is unavailable on this machine."

  def status_message(%{reason: reason}), do: "Doc VFS unavailable: #{inspect(reason)}."

  @doc false
  @spec settings_url() :: String.t()
  def settings_url, do: @fskit_settings_url

  @doc "Whether the workspace's mount point is mounted and serving requests."
  @spec mounted?(String.t()) :: boolean()
  def mounted?(root), do: mounted_and_live?(root)

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
    root = canonical_root(root)

    with_mount_lock(fn ->
      status = status()

      cond do
        not status.enabled? -> :disabled
        mounted_and_live?(root) -> {:ok, :already}
        true -> do_mount(root, status.backend)
      end
    end)
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
    root = canonical_root(root)
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

  # FSKit currently uses a single backend listener port, and several LiveViews or
  # tests can ask for the same workspace mount concurrently. Serialize mount
  # attempts so failed FSKit startups do not race into :eaddrinuse.
  defp with_mount_lock(fun) when is_function(fun, 0) do
    :global.trans({__MODULE__, :mount}, fun)
  end

  defp do_mount(root, backend) do
    root = canonical_root(root)
    point = mount_point(root)
    # Clear any lingering/half-stopped server for this point (e.g. a concurrent
    # mounter raced us) so we don't end up with two servers on one mount point.
    _ = Exfuse.umount(point)
    clean_dead_mount(point)
    ensure_clean_dir(point)

    mount_once(root, point, backend, 2)
  end

  defp mount_once(root, point, backend, retries) do
    case Exfuse.mount(point, Ecrits.Fuse.DocFs, %{root: root}, backend: backend) do
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

      {:error, :eaddrinuse} when retries > 0 ->
        rollback_failed_mount(point)
        Process.sleep(100)
        mount_once(root, point, backend, retries - 1)

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
    targets = mount_path_candidates(point)

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
    if mounted_point_live?(point) do
      true
    else
      Process.sleep(250)
      mount_serving?(point, tries - 1)
    end
  end

  defp mounted_point_live?(point), do: in_mount_table?(point) and live?(point)

  defp clean_dead_mount(point) do
    if in_mount_table?(point) and not live?(point), do: clean_leaf(point)
    :ok
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
    Enum.each(mount_path_candidates(point), fn p ->
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

  defp mount_path_candidates(point) do
    [point, real_path(point), private_tmp_path(point)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp private_tmp_path("/tmp/" <> rest), do: "/private/tmp/" <> rest
  defp private_tmp_path(_point), do: nil

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

  @doc false
  @spec backend() :: :fskit | :fuse
  def backend do
    {_mode, backend} = backend_choice()
    backend
  end

  defp backend_choice do
    config =
      :ecrits
      |> Application.get_env(:doc_vfs, [])
      |> Keyword.get(:backend, :auto)

    case normalize_backend(config) || normalize_backend(System.get_env("EXFUSE_BACKEND")) do
      :fskit -> {:explicit, :fskit}
      :fuse -> {:explicit, :fuse}
      _auto -> {:auto, default_backend()}
    end
  end

  defp normalize_backend(value) when value in [:fskit, :fuse], do: value

  defp normalize_backend(value) when value in ["fskit", "fuse"],
    do: String.to_existing_atom(value)

  defp normalize_backend(_value), do: nil

  defp default_backend do
    case :os.type() do
      {:unix, :darwin} -> :fskit
      _ -> :fuse
    end
  end

  # No silent macFUSE fallback: on macOS, auto means FSKit or nothing. When
  # FSKit is not mountable, the status carries the FSKit reason (and settings
  # URL) so the user can fix the extension, instead of quietly landing on the
  # legacy kext backend. FUSE on macOS is strictly opt-in via
  # `config :ecrits, :doc_vfs, backend: :fuse` or `EXFUSE_BACKEND=fuse`.
  defp status_for_choice(:explicit, backend), do: backend_status(backend)
  defp status_for_choice(:auto, backend), do: backend_status(backend)

  defp backend_status(:fskit) do
    cond do
      :os.type() != {:unix, :darwin} -> unavailable(:fskit, :fskit_requires_macos)
      not executable?("mount") -> unavailable(:fskit, :missing_mount)
      not fskit_extension_registered?() -> unavailable(:fskit, :fskit_extension_not_registered)
      not fskit_extension_enabled?() -> unavailable(:fskit, :fskit_extension_disabled)
      not fskit_extension_launch_signed?() -> unavailable(:fskit, :fskit_extension_unsigned)
      true -> available(:fskit)
    end
  end

  defp backend_status(:fuse) do
    cond do
      not port_available?() -> unavailable(:fuse, :fuse_port_unavailable)
      not fuse_present?() -> unavailable(:fuse, :fuse_backend_missing)
      true -> available(:fuse)
    end
  end

  defp available(backend) do
    %{
      enabled?: true,
      backend: backend,
      reason: nil,
      message: status_message(%{reason: nil, backend: backend}),
      settings_url: nil
    }
  end

  defp unavailable(backend, reason) do
    status = %{enabled?: false, backend: backend, reason: reason}

    %{
      enabled?: false,
      backend: backend,
      reason: reason,
      message: status_message(status),
      settings_url: settings_url_for(reason)
    }
  end

  defp settings_url_for(reason)
       when reason in [:fskit_extension_disabled, :fskit_extension_not_registered],
       do: @fskit_settings_url

  defp settings_url_for(_reason), do: nil

  defp port_available? do
    match?({:ok, _}, Exfuse.App.find_port!())
  rescue
    _ -> false
  end

  defp fuse_present? do
    case :os.type() do
      {:unix, :darwin} -> File.dir?(@macfuse_marker)
      _ -> true
    end
  end

  defp fskit_extension_enabled? do
    case System.cmd(
           "pluginkit",
           [
             "-m",
             "-A",
             "-D",
             "-v",
             "-p",
             "com.apple.fskit.fsmodule",
             "-i",
             @fskit_extension_id
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} -> fskit_extension_elected?(out)
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp fskit_extension_elected?(pluginkit_output) do
    pluginkit_output
    |> String.split("\n")
    |> Enum.any?(fn line ->
      line = String.trim_leading(line)
      String.starts_with?(line, "+") and String.contains?(line, @fskit_extension_id)
    end)
  end

  defp fskit_extension_registered? do
    case System.cmd(
           "pluginkit",
           ["-m", "-A", "-D", "-v", "-p", "com.apple.fskit.fsmodule"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.contains?(out, @fskit_extension_id)
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp fskit_extension_launch_signed? do
    with path when is_binary(path) <- fskit_extension_path(),
         {out, 0} <- System.cmd("codesign", ["-dv", path], stderr_to_stdout: true) do
      not String.contains?(out, "Signature=adhoc")
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp fskit_extension_path do
    case System.cmd(
           "pluginkit",
           [
             "-m",
             "-A",
             "-D",
             "-v",
             "-p",
             "com.apple.fskit.fsmodule",
             "-i",
             @fskit_extension_id
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          if String.contains?(line, @fskit_extension_id) do
            case Regex.run(~r{(/.+ExfuseFSKitExtension\.appex)}, line) do
              [_, path] -> String.trim(path)
              _ -> nil
            end
          end
        end)

      _ ->
        nil
    end
  end

  defp executable?(name), do: is_binary(System.find_executable(name))
end
