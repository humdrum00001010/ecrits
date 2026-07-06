defmodule Ecrits.Doc.ProjectionOfficeTest do
  @moduledoc """
  Office (libre) FUSE projection + write-back.

  The office arm projects through `Libreofficex.LokBackend.Ir` (the engine's own
  IR policy in the dep): ref-addressed (no ref in the bytes), runs and derived
  fields dropped, identity carried by the nested `[section[paragraph[payload]]]`
  position. Write-back recovers the real ref — ordinal `p<idx>` OR stable name
  `tbl[..]/cell[B2]` — from the positionally-aligned live node.

  Self-skips green when the LibreOffice UNO arm is unavailable, exactly like
  `office_native_test.exs`, so the default suite stays toolchain-free.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Office
  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Projection

  @docx Path.expand("../../fixtures/office/table.docx", __DIR__)
  @pptx Path.expand("../../fixtures/office/slides.pptx", __DIR__)

  setup do
    {:ok, native: uno_available?()}
  end

  test "docx projects ref-addressed: no ref, no run, no synthetic fields", %{native: native} do
    skip_or(native, "office projection shape", fn ->
      tmp = copy(@docx)
      {:ok, bytes} = Projection.project_file(tmp)

      refute bytes =~ ~s("ref")
      refute bytes =~ ~s("run")
      refute bytes =~ ~s("context")
      refute bytes =~ ~s("row")
      refute bytes =~ ~s("col")

      # nested [section[paragraph[payload]]] — one section, each node its own paragraph
      [section] = Jason.decode!(bytes)
      types = Enum.map(section, fn [node] -> node["type"] end)
      assert "paragraph" in types
      assert "table" in types
      assert "cell" in types
      refute "run" in types

      # deterministic
      assert {:ok, ^bytes} = Projection.project_file(tmp)
      cleanup(tmp)
    end)
  end

  test "no-op write_back applies nothing", %{native: native} do
    skip_or(native, "office no-op write_back", fn ->
      tmp = copy(@docx)
      {:ok, bytes} = Projection.project_file(tmp)
      assert {:ok, %{applied: 0}} = Projection.write_back(tmp, bytes, root: Path.dirname(tmp))
      cleanup(tmp)
    end)
  end

  test "write_back persists a paragraph edit (positional ordinal ref recovered)", %{
    native: native
  } do
    skip_or(native, "office paragraph write_back", fn ->
      assert_persisted(@docx, "Intro paragraph before the table.", "INTRO ROUNDTRIP.")
    end)
  end

  test "write_back persists a cell edit (stable NAME ref recovered from live node)", %{
    native: native
  } do
    skip_or(native, "office cell write_back", fn ->
      assert_persisted(@docx, "North", "WESTROUNDTRIP")
    end)
  end

  test "pptx projects ref-addressed (slide + text_frame, run dropped)", %{native: native} do
    skip_or(native, "pptx projection shape", fn ->
      tmp = copy(@pptx)
      {:ok, bytes} = Projection.project_file(tmp)
      refute bytes =~ ~s("ref")
      refute bytes =~ ~s("run")
      [section] = Jason.decode!(bytes)
      types = Enum.map(section, fn [node] -> node["type"] end)
      assert "slide" in types
      cleanup(tmp)
    end)
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp assert_persisted(fixture, from, to) do
    tmp = copy(fixture)
    {:ok, bytes} = Projection.project_file(tmp)
    edited = String.replace(bytes, ~s("text":"#{from}"), ~s("text":"#{to}"))
    assert edited != bytes, "the edit did not change the projection bytes"

    assert {:ok, %{applied: applied}} =
             Projection.write_back(tmp, edited, root: Path.dirname(tmp))

    assert applied >= 1

    # force a TRUE on-disk reload, not the live in-memory editor
    Pool.close_by_path(tmp)
    {:ok, disk} = Projection.project_file(tmp)
    assert disk =~ to, "edited text not persisted to disk"
    refute disk =~ from, "old text still present after edit"
    cleanup(tmp)
  end

  defp skip_or(true, _msg, fun), do: fun.()
  defp skip_or(false, msg, _fun), do: IO.puts("\n[skip] LibreOffice UNO arm unavailable; #{msg}")

  defp copy(fixture) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "proj_office_#{System.unique_integer([:positive])}#{Path.extname(fixture)}"
      )

    File.cp!(fixture, tmp)
    Pool.close_by_path(tmp)
    tmp
  end

  defp cleanup(tmp) do
    Pool.close_by_path(tmp)
    File.rm(tmp)
  end

  defp uno_available? do
    case Office.open(@docx, kind: :docx) do
      {:ok, handle} ->
        Office.close(handle)
        true

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
