defmodule Ecrits.Doc.McpScenarioTest do
  @moduledoc """
  Acceptance scenarios from the design's §7 "agent uses MCP" example, scoped to
  the HWP portion (the pptx/office steps are deferred). Drives the *public* MCP
  tool surface (`Ecrits.Doc.Tools`) exactly as an agent would — server-side,
  no browser, no live server.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Tools
  alias Ecrits.Test.FakeEhwpRuntime

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)
    {:ok, pool} = start_supervised({Pool, name: nil})
    on_exit(fn -> restore(:ehwp, :runtime, prev) end)
    {:ok, ctx: %{pool: pool}}
  end

  test "agent locates '제2조', inspects it, and edits it (find -> get -> edit)", %{ctx: ctx} do
    # employment_v1.hwp opened into the pool (backing: server / headless)
    {:ok, %{"document" => doc}} =
      Tools.call(ctx, "doc.open", %{
        "path" => "employment_v1.hwp",
        "open_opts" => [__text__: "제1조 (목적)\n제2조 (계약기간) 본 계약의 기간\n제3조 (대금지급)"]
      })

    # doc.list shows it
    {:ok, %{"documents" => docs}} = Tools.call(ctx, "doc.list", %{})
    assert Enum.any?(docs, &(&1["document"] == doc and &1["kind"] == "hwp"))

    # 1) find the paragraph
    {:ok, %{"matches" => [match | _]}} =
      Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "제2조"})

    assert match["text"] =~ "제2조"
    ref = match["ref"]

    # 2) get its reflective properties.
    assert {:ok, info} =
             Tools.call(ctx, "doc.get", %{"document" => doc, "ref" => ref, "props" => ["Bold"]})

    assert info["type"] == "char_run"
    assert "Bold" in info["settable"]
    assert Map.has_key?(info, "values")

    # 3) the supported edit: replace the article text.
    assert {:ok, %{"ok" => true}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{
                 "op" => "replace_text",
                 "query" => "제2조 (계약기간)",
                 "replacement" => "제2조 (기간)"
               }
             })

    assert_doc_has(ctx, doc, "제2조 (기간)")

    # property-style edit path reaches the runtime and reports its precise gap.
    assert {:error, %{kind: "unsupported", message: msg}} =
             Tools.call(ctx, "doc.set", %{
               "document" => doc,
               "ref" => ref,
               "props" => %{"Bold" => false}
             })

    assert msg =~ "fake apply_op"
  end

  test "two HWP documents edit in parallel through independent editors", %{ctx: ctx} do
    {:ok, %{"document" => a}} =
      Tools.call(ctx, "doc.open", %{"path" => "a.hwp", "open_opts" => [__text__: "제2조 A문서"]})

    {:ok, %{"document" => b}} =
      Tools.call(ctx, "doc.open", %{"path" => "b.hwp", "open_opts" => [__text__: "제2조 B문서"]})

    refute a == b

    tasks =
      for {doc, repl} <- [{a, "DOC_A"}, {b, "DOC_B"}] do
        Task.async(fn ->
          Tools.call(ctx, "doc.edit", %{
            "document" => doc,
            "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => repl}
          })
        end)
      end

    assert [{:ok, %{"ok" => true}}, {:ok, %{"ok" => true}}] = Task.await_many(tasks)

    assert_doc_has(ctx, a, "DOC_A")
    assert_doc_has(ctx, b, "DOC_B")
  end

  test "serial edits target the current document state", %{ctx: ctx} do
    {:ok, %{"document" => doc}} =
      Tools.call(ctx, "doc.open", %{"path" => "c.hwp", "open_opts" => [__text__: "제2조 본문 내용"]})

    assert {:ok, %{"ok" => true}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "USER"}
             })

    assert {:ok, %{"ok" => true}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{"op" => "replace_text", "query" => "USER", "replacement" => "AGENT"}
             })

    assert_doc_has(ctx, doc, "AGENT")
  end

  test "non-overlapping serial edits both apply", %{ctx: ctx} do
    {:ok, %{"document" => doc}} =
      Tools.call(ctx, "doc.open", %{
        "path" => "d.hwp",
        "open_opts" => [__text__: "제2조 둘째\n제7조 일곱째"]
      })

    assert {:ok, %{"ok" => true}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "SECOND"}
             })

    assert {:ok, %{"ok" => true}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{"op" => "replace_text", "query" => "제7조", "replacement" => "SEVENTH"}
             })

    assert_doc_has(ctx, doc, "SECOND")
    assert_doc_has(ctx, doc, "SEVENTH")
  end

  defp assert_doc_has(ctx, doc, pattern) do
    assert {:ok, %{"matches" => [_ | _]}} =
             Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => pattern})
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
