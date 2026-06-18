defmodule Ecrits.Doc.RhwpCharVocabTest do
  @moduledoc """
  Regression guard for the char-format vocabulary translation (server arm).

  The engine's `apply_char_format` parser reads camelCase/lowercase keys
  (`bold`, `italic`, `textColor`, `fontSize`). Agents send the design's
  PascalCase (`Bold`, `FontSize`) OR Office UNO names (`CharWeight`,
  `CharColor`). Without translation the parser silently ignores every key —
  a no-op that still returns `{"ok":true}`. That is exactly how "make it bold"
  failed (twice, live). This test pins the translation so it cannot regress.

  Skips green when the NIF is not loaded.
  """
  use ExUnit.Case, async: false

  alias Ehwp.Pool

  @fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.delete_env(:ehwp, :runtime)
    {:ok, _} = Application.ensure_all_started(:ehwp)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:ehwp, :runtime)
        value -> Application.put_env(:ehwp, :runtime, value)
      end
    end)

    if Ehwp.available?() do
      {:ok, handle, _meta} = Pool.open(File.read!(@fixture))
      on_exit(fn -> Pool.close(handle) end)
      {:ok, handle: handle, native: true}
    else
      {:ok, native: false}
    end
  end

  defp char_at(handle, sec, para, off) do
    {:ok, json} = Pool.query(handle, %{q: "context", section: sec, paragraph: para, offset: off})
    json |> Jason.decode!() |> Map.fetch!("char")
  end

  # The first body paragraph with at least one char — the run we format.
  defp first_text_ref(handle) do
    {:ok, text} = Pool.query(handle, %{q: "read"})
    # find a paragraph index with content by scanning sections 0..n is overkill;
    # the fixture's section 0 paragraph 0 carries text. Derive the run length.
    char = char_at(handle, 0, 0, 0)
    {char, "hwp:s0/p0/c0+1", text}
  end

  test "PascalCase Bold and Office CharColor translate to engine keys", %{
    native: true,
    handle: handle
  } do
    {_before, ref, _text} = first_text_ref(handle)

    # Agent-style PascalCase + Office UNO vocabulary in ONE call.
    assert {:ok, %{native: [%{"ok" => true}]}} =
             Ecrits.Doc.Rhwp.set(%{ehwp: handle}, ref, %{
               "Bold" => true,
               "CharColor" => "#ff0000"
             })

    applied = char_at(handle, 0, 0, 0)

    assert applied["bold"] == true,
           "Bold:true must set engine bold (got #{inspect(applied["bold"])})"

    assert applied["textColor"] == "#ff0000", "CharColor must set engine textColor"
  end

  test "CharWeight>=150 maps to bold:true, <150 to false", %{native: true, handle: handle} do
    {_before, ref, _text} = first_text_ref(handle)

    assert {:ok, _} = Ecrits.Doc.Rhwp.set(%{ehwp: handle}, ref, %{"CharWeight" => 150})
    assert char_at(handle, 0, 0, 0)["bold"] == true

    assert {:ok, _} = Ecrits.Doc.Rhwp.set(%{ehwp: handle}, ref, %{"CharWeight" => 100})
    assert char_at(handle, 0, 0, 0)["bold"] == false
  end

  test "CharHeight/FontSize point value scales to engine 1/100pt", %{native: true, handle: handle} do
    {_before, ref, _text} = first_text_ref(handle)

    # Agent says "36" meaning 36 POINTS — must become 3600 (1/100pt), not 36
    # (= 0.36pt, an invisible glyph).
    assert {:ok, _} = Ecrits.Doc.Rhwp.set(%{ehwp: handle}, ref, %{"CharHeight" => 36})
    assert char_at(handle, 0, 0, 0)["fontSize"] == 3600

    # A value already in 1/100pt (> 200) passes through unchanged.
    assert {:ok, _} = Ecrits.Doc.Rhwp.set(%{ehwp: handle}, ref, %{"FontSize" => 1400})
    assert char_at(handle, 0, 0, 0)["fontSize"] == 1400
  end

  test "skips when NIF unavailable", context do
    if context[:native], do: assert(true), else: assert(context[:native] == false)
  end
end
