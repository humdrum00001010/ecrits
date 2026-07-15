defmodule Ecrits.Fuse.DocMountTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Projection
  alias Ecrits.Fuse.DocMount
  alias Ecrits.Fuse.OpenDocs

  @hwpx_fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)

  setup do
    prev_config = Application.get_env(:ecrits, :doc_vfs)
    prev_backend = System.get_env("EXFUSE_BACKEND")

    on_exit(fn ->
      restore_env(prev_config)
      restore_backend_env(prev_backend)
    end)

    :ok
  end

  test "backend is determined by the OS alone" do
    Application.put_env(:ecrits, :doc_vfs, enabled: true)
    System.delete_env("EXFUSE_BACKEND")

    expected =
      case :os.type() do
        {:unix, :darwin} -> :fskit
        _ -> :fuse
      end

    assert DocMount.backend() == expected
  end

  test "there is no macFUSE path: config and env cannot select FUSE on macOS" do
    Application.put_env(:ecrits, :doc_vfs, enabled: true, backend: :fuse)
    System.put_env("EXFUSE_BACKEND", "fuse")

    case :os.type() do
      {:unix, :darwin} ->
        assert DocMount.backend() == :fskit
        assert DocMount.status().backend == :fskit

      _ ->
        assert DocMount.backend() == :fuse
    end
  end

  test "FSKit availability gate requires the FSKit extension, not macFUSE" do
    Application.put_env(:ecrits, :doc_vfs, enabled: true, backend: :fskit)

    expected =
      :os.type() == {:unix, :darwin} and is_binary(System.find_executable("mount")) and
        fskit_extension_enabled_for_test?() and
        fskit_extension_launch_signed_for_test?()

    assert DocMount.enabled?() == expected
  end

  test "status explains selected backend availability" do
    Application.put_env(:ecrits, :doc_vfs, enabled: true, backend: :fskit)

    status = DocMount.status()

    assert status.backend == :fskit
    assert status.enabled? == DocMount.enabled?()

    if status.enabled? do
      assert status.reason == nil
      assert is_binary(status.message)
      assert status.settings_url == nil
    else
      assert is_atom(status.reason)
      assert is_binary(status.message)

      if status.reason in [:fskit_extension_disabled, :fskit_extension_not_registered] do
        assert status.settings_url == DocMount.settings_url()
      end
    end
  end

  test "teardown invalidates a same-path projection after the native document is restored" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-doc-mount-same-path-#{System.unique_integer([:positive])}"
      )

    source = Path.join(root, "doc.hwpx")
    original = File.read!(@hwpx_fixture)
    File.mkdir_p!(root)
    File.write!(source, original)

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      DocMount.teardown(root)
      Pool.close_by_path(source)
      File.rm_rf(root)
    end)

    assert {:ok, first_projection} = Projection.project_file(source)
    edited_projection = String.replace(first_projection, "계약", "변조", global: false)
    assert edited_projection != first_projection
    assert {:ok, _result} = Projection.write_back(source, edited_projection)
    assert File.read!(source) != original

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.close(root, "doc.hwpx")
    File.write!(source, original)

    assert :ok = DocMount.teardown(root)
    assert {:ok, remounted_projection} = Projection.project_file(source)
    assert remounted_projection == first_projection
    refute remounted_projection =~ "변조"
  end

  defp fskit_extension_enabled_for_test? do
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
             "org.exfuse.fskit.extension"
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line = String.trim_leading(line)

          String.starts_with?(line, "+") and
            String.contains?(line, "org.exfuse.fskit.extension")
        end)

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp fskit_extension_launch_signed_for_test? do
    with path when is_binary(path) <- fskit_extension_path_for_test(),
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

  defp fskit_extension_path_for_test do
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
             "org.exfuse.fskit.extension"
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          if String.contains?(line, "org.exfuse.fskit.extension") do
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

  defp restore_env(nil), do: Application.delete_env(:ecrits, :doc_vfs)
  defp restore_env(value), do: Application.put_env(:ecrits, :doc_vfs, value)

  defp restore_backend_env(nil), do: System.delete_env("EXFUSE_BACKEND")
  defp restore_backend_env(value), do: System.put_env("EXFUSE_BACKEND", value)
end
