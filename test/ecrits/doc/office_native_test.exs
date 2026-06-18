defmodule Ecrits.Doc.OfficeNativeTest do
  @moduledoc """
  Integration test against the *real* headless LibreOffice UNO NIF (no fake
  runtime), proving the docx/pptx Office backend is wired to the genuine engine
  through the full `Ecrits.Doc` layer (Tools -> Pool -> Editor -> Office), not
  the raw NIF.

  Skips automatically (green) when the UNO arm is unavailable — the NIF wasn't
  built with the LibreOffice SDK, or there is no LOK install dir on this machine
  — exactly like `rhwp_native_test.exs` does for the ehwp NIF. So the default
  suite stays toolchain-free.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Office
  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Tools

  @fixture Path.expand("../../fixtures/office/table.docx", __DIR__)
  @pptx_fixture Path.expand("../../fixtures/office/slides.pptx", __DIR__)

  setup do
    if uno_available?() do
      {:ok, pool} = start_supervised({Pool, name: nil})

      # Edit throwaway copies so doc.save never mutates the committed fixtures.
      tmp =
        Path.join(
          System.tmp_dir!(),
          "ecrits_office_test_#{System.unique_integer([:positive])}.docx"
        )

      File.cp!(@fixture, tmp)

      tmp_pptx =
        Path.join(
          System.tmp_dir!(),
          "ecrits_office_test_#{System.unique_integer([:positive])}.pptx"
        )

      File.cp!(@pptx_fixture, tmp_pptx)

      on_exit(fn ->
        File.rm(tmp)
        File.rm(tmp_pptx)
      end)

      {:ok, ctx: %{pool: pool}, doc_path: tmp, pptx_path: tmp_pptx, native: true}
    else
      {:ok, native: false}
    end
  end

  test "real UNO NIF (pptx): doc.read on a slide ref aggregates the whole slide in ONE read (#56)",
       %{} = context do
    unless context[:native] do
      IO.puts("\n[skip] LibreOffice UNO arm unavailable; skipping pptx slide-read test")
    else
      ctx = context.ctx

      assert {:ok, %{"document" => pptx}} =
               Tools.call(ctx, "doc.open", %{"path" => context.pptx_path})

      # any match → its slide ancestor ref `page[<name>]`
      assert {:ok, %{"matches" => [%{"ref" => shape_ref} | _]}} =
               Tools.call(ctx, "doc.find", %{
                 "document" => pptx,
                 "pattern" => "ECRITS_PPTX_ORIGINAL"
               })

      assert [slide_ref] = Regex.run(~r/^page\[[^\]]+\]/, shape_ref)

      assert {:ok, read} = Tools.call(ctx, "doc.read", %{"document" => pptx, "ref" => slide_ref})

      # Whole-slide aggregate: target.text carries the slide content (not the bare
      # slide name), equal to the joined read text; and run fragments (…/pN/rM)
      # never leak into the read window.
      assert read["target"]["type"] == "slide"
      assert read["text"] =~ "ECRITS_PPTX_ORIGINAL"
      assert read["target"]["text"] == read["text"]
      refute Enum.any?(read["elements"], &(&1["type"] == "run"))
    end
  end

  test "real UNO NIF: open -> find/elements -> set -> apply -> save -> reopen persists",
       %{} = context do
    unless context[:native] do
      IO.puts("\n[skip] LibreOffice UNO arm unavailable; skipping real Office integration test")
    else
      ctx = context.ctx
      path = context.doc_path

      # open through the Tools layer (proves docx registers + routes to Office)
      assert {:ok, %{"document" => doc, "kind" => "docx"}} =
               Tools.call(ctx, "doc.open", %{"path" => path, "kind" => "docx"})

      # doc.list shows the office doc as server-backed
      assert {:ok, %{"documents" => docs}} = Tools.call(ctx, "doc.list", %{})
      entry = Enum.find(docs, &(&1["document"] == doc))
      assert entry["kind"] == "docx"
      assert entry["backing"] == "server"

      # doc.find -> cells with UNO-native refs + context
      assert {:ok, %{"matches" => matches}} =
               Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "Region"})

      assert matches != []
      cell = Enum.find(matches, &(&1["type"] == "cell"))
      assert cell, "expected a table-cell match for \"Region\""
      assert is_binary(cell["ref"])
      assert cell["ref"] =~ ~r/^tbl\[.*\]\/cell\[.*\]$/
      assert is_binary(cell["context"])

      IO.puts(
        "\n[office] doc.find {type:cell} -> ref=#{cell["ref"]} context=#{inspect(cell["context"])}"
      )

      # doc.get on the cell ref -> reflective type + settable property names + values
      assert {:ok, got} = Tools.call(ctx, "doc.get", %{"document" => doc, "ref" => cell["ref"]})
      assert got["type"] == "cell"
      assert is_list(got["settable"])
      assert "CharWeight" in got["settable"]

      # doc.set a cell property (universal setter -> uno_set)
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.set", %{
                 "document" => doc,
                 "ref" => cell["ref"],
                 "props" => %{"CharWeight" => 150.0}
               })

      # doc.edit set_text on the cell (replace_text scoped to the ref -> set_text)
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{
                   "op" => "replace_text",
                   "query" => "Region",
                   "replacement" => "ECRITS_OFFICE_MCP_TOKEN",
                   "ref" => cell["ref"]
                 }
               })

      # doc.find sees the edited cell text.
      assert {:ok, %{"matches" => [_ | _]}} =
               Tools.call(ctx, "doc.find", %{
                 "document" => doc,
                 "pattern" => "ECRITS_OFFICE_MCP_TOKEN"
               })

      # doc.save (-> uno_save with the docx export filter)
      assert {:ok, %{"ok" => true}} = Tools.call(ctx, "doc.save", %{"document" => doc})

      # close + reopen a FRESH pool/editor -> the edit persisted to disk
      assert :ok = Pool.close(ctx.pool, doc)
      {:ok, pool2} = start_supervised({Pool, name: nil}, id: :pool2)
      ctx2 = %{pool: pool2}

      assert {:ok, %{"document" => doc2}} =
               Tools.call(ctx2, "doc.open", %{"path" => path, "kind" => "docx"})

      assert {:ok, %{"matches" => reopened}} =
               Tools.call(ctx2, "doc.find", %{
                 "document" => doc2,
                 "pattern" => "ECRITS_OFFICE_MCP_TOKEN"
               })

      assert reopened != [], "the saved cell edit did not persist across reopen"
    end
  end

  test "real UNO NIF (pptx): open -> elements -> set shape prop -> edit text -> save -> reopen persists",
       %{} = context do
    unless context[:native] do
      IO.puts(
        "\n[skip] LibreOffice UNO arm unavailable; skipping real Office pptx integration test"
      )
    else
      ctx = context.ctx
      path = context.pptx_path

      # open the pptx through the Tools layer (proves pptx registers + routes to Office)
      assert {:ok, %{"document" => doc, "kind" => "pptx"}} =
               Tools.call(ctx, "doc.open", %{"path" => path, "kind" => "pptx"})

      # doc.list shows the pptx as server-backed
      assert {:ok, %{"documents" => docs}} = Tools.call(ctx, "doc.list", %{})
      entry = Enum.find(docs, &(&1["document"] == doc))
      assert entry["kind"] == "pptx"
      assert entry["backing"] == "server"

      # doc.find -> the Impress shape via the walk_impress path; UNO-native shape ref
      assert {:ok, %{"matches" => matches}} =
               Tools.call(ctx, "doc.find", %{
                 "document" => doc,
                 "pattern" => "ECRITS_PPTX_ORIGINAL"
               })

      assert matches != []
      shape = Enum.find(matches, &(&1["type"] in ["text_frame", "shape"]))
      assert shape, "expected an Impress shape/text_frame match"
      assert is_binary(shape["ref"])
      # Impress refs are page[<SlideName>]/shape[<ShapeName>]
      assert shape["ref"] =~ ~r/^page\[.*\]\/shape\[.*\]$/
      IO.puts("\n[office] pptx doc.find {type:#{shape["type"]}} -> ref=#{shape["ref"]}")

      # doc.get on the shape ref -> reflective type + settable property names + values
      assert {:ok, got} = Tools.call(ctx, "doc.get", %{"document" => doc, "ref" => shape["ref"]})
      assert got["type"] == "shape"
      assert is_list(got["settable"])
      assert "FillColor" in got["settable"]

      # doc.set a shape property (universal setter -> uno_set)
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.set", %{
                 "document" => doc,
                 "ref" => shape["ref"],
                 "props" => %{"FillColor" => 16_711_680}
               })

      # doc.edit replace_text scoped to the shape ref -> set_text on the text frame
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{
                   "op" => "replace_text",
                   "query" => "ECRITS_PPTX_ORIGINAL",
                   "replacement" => "ECRITS_PPTX_MCP_TOKEN",
                   "ref" => shape["ref"]
                 }
               })

      # doc.find sees the edited shape text.
      assert {:ok, %{"matches" => [_ | _]}} =
               Tools.call(ctx, "doc.find", %{
                 "document" => doc,
                 "pattern" => "ECRITS_PPTX_MCP_TOKEN"
               })

      # doc.save (-> uno_save with the pptx export filter)
      assert {:ok, %{"ok" => true}} = Tools.call(ctx, "doc.save", %{"document" => doc})

      # close + reopen in a FRESH pool -> the slide-shape edit persisted to disk
      assert :ok = Pool.close(ctx.pool, doc)
      {:ok, pool2} = start_supervised({Pool, name: nil}, id: :pool2_pptx)
      ctx2 = %{pool: pool2}

      assert {:ok, %{"document" => doc2}} =
               Tools.call(ctx2, "doc.open", %{"path" => path, "kind" => "pptx"})

      assert {:ok, %{"matches" => reopened}} =
               Tools.call(ctx2, "doc.find", %{
                 "document" => doc2,
                 "pattern" => "ECRITS_PPTX_MCP_TOKEN"
               })

      assert reopened != [], "the saved slide-shape edit did not persist across reopen"
    end
  end

  test "real backends: hwp docx pptx stay open together and read/edit independently",
       %{} = context do
    unless context[:native] do
      IO.puts(
        "\n[skip] LibreOffice UNO arm unavailable; skipping cross-format document integration test"
      )
    else
      ctx = context.ctx

      hwp_path =
        Path.join(System.tmp_dir!(), "ecrits_cross_#{System.unique_integer([:positive])}.hwp")

      on_exit(fn -> File.rm(hwp_path) end)

      assert {:ok, %{"document" => hwp, "kind" => "hwp"}} =
               Tools.call(ctx, "doc.create", %{"path" => hwp_path, "kind" => "hwp"})

      assert {:ok, %{"document" => docx, "kind" => "docx"}} =
               Tools.call(ctx, "doc.open", %{"path" => context.doc_path})

      assert {:ok, %{"document" => pptx, "kind" => "pptx"}} =
               Tools.call(ctx, "doc.open", %{"path" => context.pptx_path})

      assert hwp != docx
      assert docx != pptx
      assert hwp != pptx

      assert {:ok, %{"documents" => docs}} = Tools.call(ctx, "doc.list", %{})
      open_docs = MapSet.new(Enum.map(docs, & &1["document"]))
      assert MapSet.subset?(MapSet.new([hwp, docx, pptx]), open_docs)

      assert {:ok, %{"matches" => [%{"ref" => docx_ref} | _]}} =
               Tools.call(ctx, "doc.find", %{"document" => docx, "pattern" => "Region"})

      assert {:ok, %{"text" => docx_text}} =
               Tools.call(ctx, "doc.read", %{"document" => docx, "ref" => docx_ref})

      assert docx_text =~ "Region"

      assert {:ok, %{"matches" => [%{"ref" => pptx_ref} | _]}} =
               Tools.call(ctx, "doc.find", %{
                 "document" => pptx,
                 "pattern" => "ECRITS_PPTX_ORIGINAL"
               })

      assert {:ok, %{"text" => pptx_text}} =
               Tools.call(ctx, "doc.read", %{"document" => pptx, "ref" => pptx_ref})

      assert pptx_text =~ "ECRITS_PPTX_ORIGINAL"

      edits = [
        Task.async(fn ->
          Tools.call(ctx, "doc.edit", %{
            "document" => hwp,
            "op" => %{"op" => "insert_text", "ref" => "hwp:s0/p0", "text" => "HWP_CROSS_TOKEN"}
          })
        end),
        Task.async(fn ->
          Tools.call(ctx, "doc.edit", %{
            "document" => docx,
            "op" => %{
              "op" => "replace_text",
              "query" => "Region",
              "replacement" => "DOCX_CROSS_TOKEN",
              "ref" => docx_ref
            }
          })
        end),
        Task.async(fn ->
          Tools.call(ctx, "doc.edit", %{
            "document" => pptx,
            "op" => %{
              "op" => "replace_text",
              "query" => "ECRITS_PPTX_ORIGINAL",
              "replacement" => "PPTX_CROSS_TOKEN",
              "ref" => pptx_ref
            }
          })
        end)
      ]

      assert [{:ok, _}, {:ok, _}, {:ok, _}] = Task.await_many(edits, :infinity)

      assert_find(ctx, hwp, "HWP_CROSS_TOKEN")
      assert_find(ctx, docx, "DOCX_CROSS_TOKEN")
      assert_find(ctx, pptx, "PPTX_CROSS_TOKEN")

      for doc <- [hwp, docx, pptx] do
        assert {:ok, %{"ok" => true}} = Tools.call(ctx, "doc.save", %{"document" => doc})
      end

      assert :ok = Pool.close(ctx.pool, docx)
      assert :ok = Pool.close(ctx.pool, pptx)

      {:ok, pool2} = start_supervised({Pool, name: nil}, id: :pool_cross_format_reopen)
      ctx2 = %{pool: pool2}

      assert {:ok, %{"document" => docx2}} =
               Tools.call(ctx2, "doc.open", %{"path" => context.doc_path})

      assert {:ok, %{"document" => pptx2}} =
               Tools.call(ctx2, "doc.open", %{"path" => context.pptx_path})

      assert_find(ctx2, docx2, "DOCX_CROSS_TOKEN")
      assert_find(ctx2, pptx2, "PPTX_CROSS_TOKEN")

      assert :ok = Pool.close(ctx.pool, hwp)
      assert :ok = Pool.close(pool2, docx2)
      assert :ok = Pool.close(pool2, pptx2)
    end
  end

  test "real UNO NIF (pptx): doc.create deck creates a designed pptx from scratch",
       %{} = context do
    unless context[:native] do
      IO.puts("\n[skip] LibreOffice UNO arm unavailable; skipping scratch PPTX create test")
    else
      ctx = context.ctx

      path =
        Path.join(System.tmp_dir!(), "ecrits_scratch_#{System.unique_integer([:positive])}.pptx")

      on_exit(fn -> File.rm(path) end)

      deck = %{
        "title" => "FinMate AI",
        "subtitle" => "AI financial copilot MVP",
        "slides" => [
          %{
            "title" => "FinMate AI",
            "subtitle" => "고객 금융 생활을 진단하고 맞춤 실행 계획을 추천하는 AI 서비스",
            "section" => "JB Fin:AI MVP",
            "metrics" => [
              %{"label" => "상담 준비", "value" => "30%", "delta" => "down"},
              %{"label" => "추천 정확도", "value" => "18%", "delta" => "up"},
              %{"label" => "리스크 탐지", "value" => "2.4x", "delta" => "lift"}
            ]
          },
          %{
            "title" => "Problem",
            "subtitle" => "금융 상담은 데이터가 많을수록 느려진다",
            "cards" => [
              %{"title" => "분산된 고객 맥락", "body" => "거래, 상품, 민원 이력이 여러 시스템에 흩어져 있음"},
              %{"title" => "설명 가능한 추천 부족", "body" => "추천 근거를 즉시 제시하기 어려움"},
              %{"title" => "사후 관리 누락", "body" => "상담 이후 실행 여부가 다음 액션으로 연결되지 않음"}
            ]
          },
          %{
            "title" => "Solution",
            "subtitle" => "고객 맥락을 실행 가능한 금융 플랜으로 전환",
            "roadmap" => ["수집", "요약", "추천", "검증", "후속관리"]
          },
          %{
            "title" => "Impact",
            "subtitle" => "6주 MVP로 생산성, 추천 품질, 리스크 탐지를 검증",
            "metrics" => [
              %{"label" => "MVP 기간", "value" => "6주", "delta" => "plan"},
              %{"label" => "핵심 여정", "value" => "3개", "delta" => "scope"},
              %{"label" => "파일럿", "value" => "50명", "delta" => "target"}
            ],
            "roadmap" => ["Week 1", "Week 2", "Week 4", "Week 6"]
          }
        ]
      }

      assert {:ok, %{"document" => doc, "kind" => "pptx", "path" => ^path}} =
               Tools.call(ctx, "doc.create", %{"path" => path, "kind" => "pptx", "deck" => deck})

      assert {:ok, "PK" <> _} = File.read(path)
      assert_find(ctx, doc, "FinMate AI")
      assert_find(ctx, doc, "리스크 탐지")

      assert {:ok, %{"ok" => true}} = Tools.call(ctx, "doc.save", %{"document" => doc})
      assert :ok = Pool.close(ctx.pool, doc)

      {:ok, pool2} = start_supervised({Pool, name: nil}, id: :pool_scratch_pptx_reopen)
      ctx2 = %{pool: pool2}

      assert {:ok, %{"document" => reopened}} =
               Tools.call(ctx2, "doc.open", %{"path" => path})

      assert_find(ctx2, reopened, "FinMate AI")
      assert_find(ctx2, reopened, "리스크 탐지")
      assert :ok = Pool.close(pool2, reopened)
    end
  end

  test "real UNO NIF (pptx): IR-direct from-scratch authoring — blank create, insert_slide, insert_shape",
       %{} = context do
    unless context[:native] do
      IO.puts("\n[skip] LibreOffice UNO arm unavailable; skipping IR-direct authoring test")
    else
      ctx = context.ctx

      path =
        Path.join(System.tmp_dir!(), "ecrits_irdirect_#{System.unique_integer([:positive])}.pptx")

      on_exit(fn -> File.rm(path) end)

      # No deck: a LibreOffice factory-blank presentation, not a template.
      assert {:ok, %{"document" => doc, "kind" => "pptx"}} =
               Tools.call(ctx, "doc.create", %{"path" => path, "kind" => "pptx"})

      assert {:ok, "PK" <> _} = File.read(path)

      # New named slide -> deterministic ref page[hero].
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{"op" => "insert_slide", "name" => "hero"}
               })

      # IR-direct shapes: raw UNO service + 1/100 mm geometry + raw UNO props.
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{
                   "op" => "insert_shape",
                   "page" => "hero",
                   "service" => "com.sun.star.drawing.RectangleShape",
                   "name" => "accent",
                   "x" => 1000,
                   "y" => 1000,
                   "w" => 20_000,
                   "h" => 3000,
                   "FillColor" => 0x2563EB
                 }
               })

      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{
                   "op" => "insert_shape",
                   "page" => "hero",
                   "service" => "com.sun.star.drawing.TextShape",
                   "name" => "title",
                   "x" => 1500,
                   "y" => 1400,
                   "w" => 18_000,
                   "h" => 2000,
                   "text" => "Aria IR direct",
                   "CharHeight" => 32,
                   "CharWeight" => 150,
                   "CharColor" => 0x111827
                 }
               })

      # HWP-arm alias + CSS hex (what agents actually send, schema documents both
      # arms): fillColor "#RRGGBB" must normalize to UNO FillColor int, never
      # silently drop (the silent drop rendered live decks in default green).
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{
                   "op" => "insert_shape",
                   "page" => "hero",
                   "service" => "com.sun.star.drawing.RectangleShape",
                   "name" => "css_hex",
                   "x" => 1000,
                   "y" => 5000,
                   "w" => 8000,
                   "h" => 2000,
                   "fillColor" => "#10B981",
                   "fillType" => "solid"
                 }
               })

      assert {:ok, %{"values" => hex_values}} =
               Tools.call(ctx, "doc.get", %{
                 "document" => doc,
                 "ref" => "page[hero]/shape[css_hex]"
               })

      assert round(hex_values["FillColor"]) == 0x10B981

      # The inserted text is discoverable and props read back IR-direct.
      assert_find(ctx, doc, "Aria IR direct")

      # The feedback loop: render the slide to a real PNG FILE (doc.render
      # returns paths — CLI agents view images from disk, never inline base64).
      assert {:ok,
              %{
                "ok" => true,
                "rendered" => ["hero"],
                "files" => [img],
                "slide_size" => slide_size
              }} =
               Tools.call(ctx, "doc.render", %{
                 "document" => doc,
                 "page" => "hero",
                 "width" => 480
               })

      assert <<137, ?P, ?N, ?G, _::binary>> = File.read!(img["file"])
      assert img["pixel_width"] == 480
      assert is_integer(img["pixel_height"])
      assert slide_size["coordinate_unit"] == "1/100 mm"
      assert is_integer(slide_size["width_100mm"])
      assert is_integer(slide_size["height_100mm"])

      # set_geometry moves an existing shape (the fix-up verb).
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{
                   "op" => "set_geometry",
                   "ref" => "page[hero]/shape[accent]",
                   "x" => 2500,
                   "w" => 10_000
                 }
               })

      # delete_node removes a shape entirely.
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{"op" => "delete_node", "ref" => "page[hero]/shape[css_hex]"}
               })

      # insert_picture (office form) EMBEDS an image: the saved pptx must carry
      # it under ppt/media with a blipFill reference.
      img_src =
        Path.join(System.tmp_dir!(), "ecrits_pic_#{System.unique_integer([:positive])}.png")

      # A tiny valid PNG (1x1, red) — enough for the engine to embed.
      File.write!(
        img_src,
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
        )
      )

      on_exit(fn -> File.rm(img_src) end)

      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{
                   "op" => "insert_picture",
                   "page" => "hero",
                   "name" => "logo",
                   "src" => img_src,
                   "x" => 20_000,
                   "y" => 1000,
                   "w" => 4000,
                   "h" => 4000
                 }
               })

      assert {:ok, %{"values" => rect_values}} =
               Tools.call(ctx, "doc.get", %{
                 "document" => doc,
                 "ref" => "page[hero]/shape[accent]"
               })

      assert round(rect_values["FillColor"]) == 0x2563EB

      assert {:ok, %{"values" => title_values}} =
               Tools.call(ctx, "doc.get", %{"document" => doc, "ref" => "page[hero]/shape[title]"})

      assert round(title_values["CharHeight"]) == 32

      # Persists through a real pptx save -> reopen.
      assert {:ok, %{"ok" => true}} = Tools.call(ctx, "doc.save", %{"document" => doc})
      assert :ok = Pool.close(ctx.pool, doc)

      # The EXPORTED XML must carry the solid fill explicitly. Reading FillColor
      # back from the live model is not enough: without FillStyle=SOLID the
      # OOXML exporter writes NO fill element and the theme default (green)
      # paints the shape — the live-deck regression this test pins down.
      {:ok, zip} = :zip.unzip(String.to_charlist(path), [:memory])

      slide_xmls =
        zip
        |> Enum.filter(fn {n, _} -> to_string(n) =~ ~r{^ppt/slides/slide\d+\.xml$} end)
        |> Enum.map_join("\n", fn {_n, body} -> body end)

      assert slide_xmls =~ ~r/<a:solidFill><a:srgbClr val="2563EB"/i
      # The css_hex shape was delete_node'd: its color must NOT survive the save.
      refute slide_xmls =~ ~r/<a:srgbClr val="10B981"/i
      # set_geometry moved accent to x=2500 (1/100 mm) = 900000 EMU.
      assert slide_xmls =~ ~s(<a:off x="900000")
      # insert_picture embedded the image: media part + blip reference present.
      assert Enum.any?(zip, fn {n, _} -> to_string(n) =~ ~r{^ppt/media/image\d+\.} end)
      assert slide_xmls =~ "blip"

      {:ok, pool2} = start_supervised({Pool, name: nil}, id: :pool_irdirect_reopen)
      ctx2 = %{pool: pool2}

      assert {:ok, %{"document" => reopened}} = Tools.call(ctx2, "doc.open", %{"path" => path})
      assert_find(ctx2, reopened, "Aria IR direct")
      assert :ok = Pool.close(pool2, reopened)
    end
  end

  test "twin-sync of a viewed pptx (refresh_by_path then close) never crashes the Instance",
       %{} = context do
    unless context[:native] do
      IO.puts("\n[skip] LibreOffice UNO arm unavailable; skipping office twin-sync crash test")
    else
      ctx = context.ctx
      path = context.pptx_path

      # Open the SERVER twin the way a browser-viewed pptx does.
      assert {:ok, %{"document" => doc}} =
               Tools.call(ctx, "doc.open", %{"path" => path, "kind" => "pptx"})

      instance = Process.whereis(Ecrits.Doc.Office.Instance)
      assert is_pid(instance)

      # The browser-save twin-sync feeds the saved bytes back through
      # Pool.refresh_by_path -> Editor.reload_from_bytes. The Office backend's
      # open/2 is PATH-based, so before the fix these bytes were treated as a
      # filesystem path -> NIF badarg -> KeyError crashed this singleton ->
      # cascade. It must now reopen from disk and return :ok, repeatedly.
      saved_bytes = File.read!(path)
      assert :ok = Pool.refresh_by_path(ctx.pool, path, saved_bytes)
      assert :ok = Pool.refresh_by_path(ctx.pool, path, saved_bytes)

      # The singleton governor must be the SAME live process (never crashed).
      assert Process.whereis(Ecrits.Doc.Office.Instance) == instance
      assert Process.alive?(instance)

      # And closing (the second half of "save then close") is clean.
      assert :ok = Pool.close(ctx.pool, doc)
      assert Process.alive?(instance)
    end
  end

  # Probe the UNO arm by attempting a real open of the fixture through the
  # Office backend. `{:office_unavailable, _}` (no SDK build / no install dir) or
  # an :nif_not_loaded ErlangError => the arm is absent and the test skips green.
  defp uno_available? do
    case Office.open(@fixture, kind: :docx) do
      {:ok, handle} ->
        Office.close(handle)
        true

      {:error, {:office_unavailable, _}} ->
        false

      {:error, _other} ->
        false
    end
  rescue
    _ -> false
  end

  defp assert_find(ctx, doc, pattern) do
    assert {:ok, %{"matches" => [_ | _]}} =
             Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => pattern})
  end
end
