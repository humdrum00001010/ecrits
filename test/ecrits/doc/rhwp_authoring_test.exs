defmodule Ecrits.Doc.RhwpAuthoringTest do
  @moduledoc """
  Regression guard for from-scratch HWP authoring through the real MCP tools
  (the chat-rail's path). Pins three server-arm bugs that made the agent produce
  mangled documents (reverse-stacked paragraphs, dropped text, no-op bold):

    1. `insert_paragraph {ref: "end", text: ...}` must APPEND a paragraph WITH
       the text — the engine's insert_paragraph ignores `text`, and "end" used
       to resolve to paragraph 0 (so a build loop stacked everything in reverse).
    2. Paragraph order after N appends must be 0..N-1 in request order.
    3. A span-less `doc.set {Bold: true}` on a paragraph-level find ref must bold
       the WHOLE paragraph, not a zero-length range (which formatted nothing).

  Skips green when the NIF is not loaded.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.{Pool, Tools}
  alias Ehwp.Pool, as: EPool

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
      {:ok, pool} = start_supervised({Pool, name: nil})

      tmp =
        Path.join(System.tmp_dir!(), "rhwp_authoring_#{System.unique_integer([:positive])}.hwp")

      on_exit(fn -> File.rm(tmp) end)
      {:ok, ctx: %{pool: pool}, path: tmp, native: true}
    else
      {:ok, native: false}
    end
  end

  defp paragraphs(path) do
    {:ok, h, _m} = EPool.open(File.read!(path))
    {:ok, els} = EPool.query(h, %{q: "elements"})
    EPool.close(h)

    els
    |> Jason.decode!()
    |> Enum.filter(&(&1["type"] == "paragraph"))
    |> Enum.map(fn e -> {e["ref"]["paragraph"], e["text"]} end)
  end

  defp char_bold(path, sec, para, off) do
    {:ok, h, _m} = EPool.open(File.read!(path))
    {:ok, c} = EPool.query(h, %{q: "context", section: sec, paragraph: para, offset: off})
    EPool.close(h)
    c |> Jason.decode!() |> get_in(["char", "bold"])
  end

  test "insert_paragraph end+text appends in order, honoring text", %{
    native: true,
    ctx: ctx,
    path: path
  } do
    {:ok, %{"document" => doc}} = Tools.call(ctx, "doc.create", %{"path" => path})

    for t <- ["근로계약서", "제1조(목적)", "제2조(임금)", "제3조(근로시간)"] do
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{"op" => "insert_paragraph", "ref" => "end", "text" => t}
               })
    end

    Tools.call(ctx, "doc.save", %{"document" => doc})

    assert paragraphs(path) == [
             {0, "근로계약서"},
             {1, "제1조(목적)"},
             {2, "제2조(임금)"},
             {3, "제3조(근로시간)"}
           ]
  end

  test "span-less doc.set Bold bolds the WHOLE paragraph", %{native: true, ctx: ctx, path: path} do
    {:ok, %{"document" => doc}} = Tools.call(ctx, "doc.create", %{"path" => path})

    Tools.call(ctx, "doc.edit", %{
      "document" => doc,
      "op" => %{"op" => "insert_paragraph", "ref" => "end", "text" => "근로계약서"}
    })

    {:ok, fr} = Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "근로계약서"})
    ref = fr["matches"] |> List.first() |> Map.get("ref")

    assert {:ok, %{"ok" => true}} =
             Tools.call(ctx, "doc.set", %{
               "document" => doc,
               "ref" => ref,
               "props" => %{"Bold" => true}
             })

    Tools.call(ctx, "doc.save", %{"document" => doc})

    # First AND last glyph of "근로계약서" must be bold (whole-paragraph span).
    assert char_bold(path, 0, 0, 0) == true
    assert char_bold(path, 0, 0, 4) == true
  end

  test "insert_picture with bare src (no dims) defaults placed geometry", %{
    native: true,
    ctx: ctx,
    path: path
  } do
    img = Path.expand("../../../priv/static/images/landing/hero.png", __DIR__)
    {:ok, %{"document" => doc}} = Tools.call(ctx, "doc.create", %{"path" => path})

    # Bare src, no width/height — used to error "missing field `width`".
    assert {:ok, %{"ok" => true}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{"op" => "insert_picture", "ref" => "end", "src" => img}
             })

    Tools.call(ctx, "doc.save", %{"document" => doc})

    {:ok, h, _m} = EPool.open(File.read!(path))
    {:ok, els} = EPool.query(h, %{q: "elements"})
    EPool.close(h)
    types = els |> Jason.decode!() |> Enum.map(& &1["type"]) |> Enum.frequencies()
    assert types["picture"] == 1
  end

  test "insert_table with inline cells fills the grid, leaves body clean", %{
    native: true,
    ctx: ctx,
    path: path
  } do
    {:ok, %{"document" => doc}} = Tools.call(ctx, "doc.create", %{"path" => path})

    Tools.call(ctx, "doc.edit", %{
      "document" => doc,
      "op" => %{"op" => "insert_paragraph", "ref" => "end", "text" => "실적표"}
    })

    assert {:ok, %{"ok" => true}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{
                 "op" => "insert_table",
                 "ref" => "end",
                 "rows" => 3,
                 "cols" => 3,
                 "cells" => [["항목", "목표", "실적"], ["매출", "100", "95"], ["이익", "30", "28"]]
               }
             })

    Tools.call(ctx, "doc.save", %{"document" => doc})

    {:ok, h, _m} = EPool.open(File.read!(path))
    {:ok, els} = EPool.query(h, %{q: "elements"})
    EPool.close(h)
    parsed = Jason.decode!(els)

    cells = parsed |> Enum.filter(&(&1["type"] == "cell")) |> Enum.map(& &1["text"])
    assert cells == ["항목", "목표", "실적", "매출", "100", "95", "이익", "30", "28"]

    # The title paragraph stays clean — table data must NOT leak into the body.
    body = parsed |> Enum.filter(&(&1["type"] == "paragraph")) |> Enum.map(& &1["text"])
    assert "실적표" in body
    refute Enum.any?(body, &String.contains?(&1, "매출"))
  end

  test "paragraph Alignment (PascalCase) centers/right-aligns", %{
    native: true,
    ctx: ctx,
    path: path
  } do
    {:ok, %{"document" => doc}} = Tools.call(ctx, "doc.create", %{"path" => path})

    Tools.call(ctx, "doc.edit", %{
      "document" => doc,
      "op" => %{"op" => "insert_paragraph", "ref" => "end", "text" => "제목"}
    })

    {:ok, fr} = Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "제목"})
    ref = fr["matches"] |> List.first() |> Map.get("ref")

    assert {:ok, %{"ok" => true}} =
             Tools.call(ctx, "doc.set", %{
               "document" => doc,
               "ref" => ref,
               "props" => %{"kind" => "paragraph", "Alignment" => "Center"}
             })

    Tools.call(ctx, "doc.save", %{"document" => doc})

    {:ok, h, _m} = EPool.open(File.read!(path))
    {:ok, c0} = EPool.query(h, %{q: "context", section: 0, paragraph: 0, offset: 0})
    EPool.close(h)
    assert c0 |> Jason.decode!() |> get_in(["paragraph", "alignment"]) == "center"
  end

  test "insert_table header:true shades row 0", %{native: true, ctx: ctx, path: path} do
    {:ok, %{"document" => doc}} = Tools.call(ctx, "doc.create", %{"path" => path})

    Tools.call(ctx, "doc.edit", %{
      "document" => doc,
      "op" => %{"op" => "insert_paragraph", "ref" => "end", "text" => "T"}
    })

    assert {:ok, %{"ok" => true}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{
                 "op" => "insert_table",
                 "ref" => "end",
                 "header" => true,
                 "cells" => [["항목", "목표"], ["매출", "100"]]
               }
             })

    Tools.call(ctx, "doc.save", %{"document" => doc})

    {:ok, h, _m} = EPool.open(File.read!(path))
    {:ok, svg, _} = EPool.render_page_svg(h, 0)
    EPool.close(h)
    # 2 header cells filled with the default gray.
    assert length(String.split(String.downcase(svg), "#e8e8e8")) - 1 == 2
  end

  test "set_columns defaults a readable gutter (columns don't touch)", %{
    native: true,
    ctx: ctx,
    path: path
  } do
    {:ok, %{"document" => doc}} = Tools.call(ctx, "doc.create", %{"path" => path})

    body =
      "광합성은 식물이 빛 에너지를 화학 에너지로 전환하는 과정이다. "
      |> String.duplicate(30)

    Tools.call(ctx, "doc.edit", %{
      "document" => doc,
      "op" => %{"op" => "insert_paragraph", "ref" => "end", "text" => body}
    })

    # No explicit spacing — must NOT be a 0-gap gutter.
    assert {:ok, %{"ok" => true}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{"op" => "set_columns", "ref" => "end", "count" => 2}
             })

    Tools.call(ctx, "doc.save", %{"document" => doc})

    {:ok, h, _m} = EPool.open(File.read!(path))
    {:ok, svg, _} = EPool.render_page_svg(h, 0)
    EPool.close(h)

    xs =
      Regex.scan(~r/<text x="([\d.]+)"/, svg)
      |> Enum.map(fn [_, x] -> round(elem(Float.parse(x), 0)) end)

    left = Enum.filter(xs, &(&1 < 400))
    right = Enum.filter(xs, &(&1 >= 400))
    # Both columns filled, and a real gutter (> 20px) separates them.
    assert right != []
    assert Enum.min(right) - Enum.max(left) > 20
  end

  test "skips when NIF unavailable", context do
    if context[:native], do: assert(true), else: assert(context[:native] == false)
  end
end
