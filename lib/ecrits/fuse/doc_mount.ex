defmodule Ecrits.Fuse.DocMount do
  @moduledoc """
  Stateless facade over `Exfuse` for the per-workspace document VFS mount.

  One mount per workspace, living at `<workspace_root>/.ecrits/mount`, serving
  `Ecrits.Fuse.DocFs` over the workspace root. There is NO GenServer here — this
  module only holds the `ensure`/`teardown` bookkeeping; `exfuse`'s own
  `Exfuse.MountSup` owns the port processes.

  `ensure/1` and `teardown/1` are defensive: they run from the workspace
  `Ecrits.Workspace.Session` GenServer (and a LiveView Task), so a mount failure
  (missing native backend, VFS backend error) must NEVER crash the caller. Both
  rescue/catch and log via `Logger`.

  Mount mechanics live in `exfuse`: per-point exclusive servers, dead-mount
  healing, busy retry, serving verification with rollback, and idempotent
  force-unmount. This module only decides WHEN to (re)mount — `Exfuse.serving?/1`
  is the health gate (a mount left by a beam crash lingers in the kernel table
  but EIOs fast, so `ensure/1` remounts it instead of reporting `:already`).

  Gated by `enabled?/0`: the `:doc_vfs` config flag (default ON) and a usable
  native backend. The backend is determined by the OS alone — macOS mounts
  through FSKit and every other Unix through the FUSE/libfuse Rust port.
  There is no macFUSE path: when FSKit is not mountable the status explains
  why instead of falling back. See
  `docs/plans/2026-06-23-exfuse-doc-vfs-migration.md`.
  """

  require Logger

  @fskit_extension_id "org.exfuse.fskit.extension"
  @fskit_settings_url "x-apple.systempreferences:com.apple.ExtensionsPreferences?extension-points"

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
  used by tools/prompts to explain why the selected doc VFS backend is not mountable.
  """
  @spec status() :: %{
          enabled?: boolean(),
          backend: :fskit | :fuse,
          reason: atom() | nil,
          message: String.t() | nil,
          settings_url: String.t() | nil
        }
  def status do
    if config_enabled?() do
      backend_status(backend())
    else
      unavailable(backend(), :config_disabled)
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

  def status_message(%{reason: reason}), do: "Doc VFS unavailable: #{inspect(reason)}."

  @doc false
  @spec settings_url() :: String.t()
  def settings_url, do: @fskit_settings_url

  @doc "Whether the workspace's mount point is mounted and serving requests."
  @spec mounted?(String.t()) :: boolean()
  def mounted?(root), do: root |> mount_point() |> Exfuse.serving?()

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
        mounted?(root) -> {:ok, :already}
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
  raises. `Exfuse.unmount/1` handles the native detach; the workspace filesystem
  runtime is stopped after its mount process is gone.
  """
  @spec teardown(String.t()) :: :ok | {:error, term()}
  def teardown(root) do
    point = mount_point(root)

    with_mount_lock(fn -> unmount_point(point) end)
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

  # Several LiveViews or tests can ask for the same workspace mount concurrently.
  # Serialize mount attempts so half-started FSKit/exfuse lifecycles do not race
  # each other while we decide whether the existing mount can be shared.
  defp with_mount_lock(fun) when is_function(fun, 0) do
    :global.trans({__MODULE__, :mount}, fun)
  end

  defp do_mount(root, backend) do
    root = canonical_root(root)
    point = mount_point(root)
    # Clear any lingering/half-stopped server first; exfuse owns the rest of
    # the mechanics (exclusivity, dead-mount healing, busy retry, and the
    # `verify: :serving` gate that rolls back a mount that never serves).
    _ = unmount_point(point)

    case Exfuse.start_fs(Ecrits.Fuse.DocFs, %{root: root}) do
      {:ok, fs} ->
        mount_fs(fs, point, backend)

      {:error, reason} ->
        mount_error(point, reason)
    end
  end

  defp mount_fs(fs, point, backend) do
    case Exfuse.mount(fs, point, backend: backend, verify: :serving) do
      {:ok, _mount} ->
        Logger.info("[DocMount] mounted doc VFS at #{point}")
        {:ok, :mounted}

      {:error, {:already_mounted, _pid}} ->
        Exfuse.stop_fs(fs)
        {:ok, :already}

      {:error, reason} ->
        Exfuse.stop_fs(fs)
        mount_error(point, reason)
    end
  end

  defp mount_error(point, reason) do
    # Exfuse rolled the mount back; just don't leave an empty `.ecrits`
    # skeleton behind (rmdir refuses a non-empty parent, so a real workspace
    # store is never touched).
    clean_empty_parent(point)
    Logger.error("[DocMount] mount failed at #{point}: #{inspect(reason)}")
    {:error, reason}
  end

  defp unmount_point(point) do
    point
    |> mounts_at()
    |> Enum.each(fn {mount, %{fs: fs}} ->
      :ok = Exfuse.unmount(mount)
      Exfuse.stop_fs(fs)
    end)

    :ok
  end

  defp mounts_at(point) do
    Enum.filter(Exfuse.list(), fn {_mount, status} -> status.mount_point == point end)
  end

  defp clean_empty_parent(point) do
    _ = File.rmdir(Path.dirname(point))
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp private_tmp_path("/tmp/" <> rest), do: "/private/tmp/" <> rest
  defp private_tmp_path(_point), do: nil

  defp config_enabled? do
    :ecrits
    |> Application.get_env(:doc_vfs, [])
    |> Keyword.get(:enabled, true) != false
  end

  # The backend is determined by the OS alone: macOS mounts through FSKit,
  # every other Unix through the FUSE/libfuse port. There is no macFUSE path
  # and no config/env override — when FSKit is not mountable the status
  # explains why (with the settings URL) instead of reaching for a fallback.
  @doc false
  @spec backend() :: :fskit | :fuse
  def backend do
    case :os.type() do
      {:unix, :darwin} -> :fskit
      _ -> :fuse
    end
  end

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
    if port_available?() do
      available(:fuse)
    else
      unavailable(:fuse, :fuse_port_unavailable)
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
