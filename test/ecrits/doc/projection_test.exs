defmodule Ecrits.Doc.ProjectionTest do
  @moduledoc """
  Unit tests for `Ecrits.Doc.Projection` — the exfuse doc-VFS text projection.

  The pure surface (supported?/projected_name/source_basename/supported_exts) is
  toolchain-free. The end-to-end `project_file/2` + `fingerprint/1` tests run
  against the REAL doc layer through a private `Ecrits.Doc.Pool` and the ehwp NIF;
  they self-skip green when the NIF is unavailable, so the default suite stays
  free of native deps.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Projection

  # A committed real HWP the ehwp NIF can open (used only by the guarded e2e block).
  @hwp_fixture Path.expand(
                 "../../../priv/static/assets/standard_contracts/employment_v1.hwp",
                 __DIR__
               )

  describe "supported?/1" do
    test "true for every supported extension, case-insensitive" do
      for ext <- ~w(.hwp .hwpx .docx .pptx .xlsx) do
        assert Projection.supported?("report" <> ext)
        assert Projection.supported?("REPORT" <> String.upcase(ext))
      end
    end

    test "false for unsupported extensions and non-binaries" do
      refute Projection.supported?("notes.txt")
      refute Projection.supported?("archive.zip")
      refute Projection.supported?("no_extension")
      refute Projection.supported?(nil)
      refute Projection.supported?(123)
    end

    test "matches the published supported_exts list" do
      assert Projection.supported_exts() == ~w(.hwp .hwpx .docx .pptx .xlsx)
    end
  end

  describe "projected_name/1 and source_basename/1 round-trip" do
    test "projected_name appends .md" do
      assert Projection.projected_name("report.hwp") == "report.hwp.md"
      assert Projection.projected_name("a/b/c.pptx") == "a/b/c.pptx.md"
    end

    test "source_basename strips a trailing .md" do
      assert Projection.source_basename("report.hwp.md") == "report.hwp"
      assert Projection.source_basename("workbook.xlsx.md") == "workbook.xlsx"
    end

    test "source_basename returns nil without a .md suffix" do
      assert Projection.source_basename("notes.txt") == nil
      assert Projection.source_basename("report.hwp") == nil
      assert Projection.source_basename(nil) == nil
    end

    test "the two are inverse for supported names" do
      for ext <- Projection.supported_exts() do
        name = "doc" <> ext
        assert name |> Projection.projected_name() |> Projection.source_basename() == name
      end
    end
  end

  describe "project_file/2 error handling (no NIF required)" do
    test "unsupported extension is a clean error, never a raise" do
      assert {:error, {:unsupported, ".txt"}} =
               Projection.project_file("/tmp/whatever.txt")
    end

    test "non-binary path is rejected" do
      assert {:error, :invalid_path} = Projection.project_file(:not_a_path)
    end

    test "fingerprint propagates the same error" do
      assert {:error, {:unsupported, ".txt"}} = Projection.fingerprint("/tmp/whatever.txt")
      assert {:error, :invalid_path} = Projection.fingerprint(:not_a_path)
    end
  end

  describe "project_file/2 + fingerprint/1 over the real doc layer" do
    setup do
      {:ok, ehwp: ehwp_available?()}
    end

    test "projects a real HWP to deterministic, grep-able bytes", %{ehwp: ehwp} do
      if not ehwp do
        IO.puts("\n[skip] ehwp NIF unavailable; skipping Projection e2e over a real HWP")
      else
        # Use a PRIVATE pool so the test is isolated; project_file/2 talks to the
        # default-named Pool, so name this one __MODULE__ via a start_supervised
        # is not possible (project_file uses @default_name). Instead exercise the
        # default pool the app already supervises.
        path = copy_to_tmp(@hwp_fixture, "projection_e2e", ".hwp")

        assert {:ok, bytes} = Projection.project_file(path)
        assert is_binary(bytes)
        assert byte_size(bytes) > 0
        assert String.valid?(bytes)
        # The projection IS the document IR: every line is one IR node as JSON
        # (with at least a "ref" and a "type").
        lines = bytes |> String.split("\n") |> Enum.reject(&(&1 == ""))
        assert lines != []

        assert Enum.all?(lines, fn line ->
                 match?({:ok, %{"ref" => _, "type" => _}}, Jason.decode(line))
               end)

        # Deterministic: a second projection of the same content is byte-identical.
        assert {:ok, bytes2} = Projection.project_file(path)
        assert bytes == bytes2

        # Fingerprint is stable and equals phash2 of the bytes.
        assert {:ok, fp} = Projection.fingerprint(path)
        assert fp == :erlang.phash2(bytes)
        assert {:ok, ^fp} = Projection.fingerprint(path)

        _ = Pool.close_by_path(path)
        File.rm_rf(Path.dirname(path))
      end
    end
  end

  # --- helpers --------------------------------------------------------------

  defp copy_to_tmp(src, tag, ext) do
    dir = Path.join(System.tmp_dir!(), "ecrits-#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dest = Path.join(dir, "doc" <> ext)
    File.cp!(src, dest)
    dest
  end

  # The ehwp NIF is present iff Ehwp.open succeeds on the fixture. Mirrors the
  # office tests' self-skip so the default suite never requires the native arm.
  defp ehwp_available? do
    Code.ensure_loaded?(Ehwp) and
      match?({:ok, _h, _m}, safe_ehwp_open())
  end

  defp safe_ehwp_open do
    Ehwp.open(@hwp_fixture, [])
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
