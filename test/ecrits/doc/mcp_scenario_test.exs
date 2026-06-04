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

    # 2) get its properties — honestly not supported by the headless NIF yet
    assert {:error, %{"not_supported" => true}} =
             Tools.call(ctx, "doc.get", %{"document" => doc, "ref" => ref, "props" => ["Bold"]})

    # 3) the supported edit: replace the article text, base_revision 0
    assert {:ok, %{"ok" => true, "revision" => 1}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{
                 "op" => "replace_text",
                 "query" => "제2조 (계약기간)",
                 "replacement" => "제2조 (기간)"
               },
               "base_revision" => 0
             })

    {:ok, %{"text" => text}} = Tools.call(ctx, "doc.read", %{"document" => doc})
    assert text =~ "제2조 (기간)"

    # property-style edit path is wired but honestly reports the NIF gap
    assert {:error, %{"not_supported" => true}} =
             Tools.call(ctx, "doc.set", %{
               "document" => doc,
               "ref" => ref,
               "props" => %{"Bold" => false},
               "base_revision" => 1
             })
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
            "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => repl},
            "base_revision" => 0
          })
        end)
      end

    assert [{:ok, %{"ok" => true}}, {:ok, %{"ok" => true}}] = Task.await_many(tasks)

    {:ok, %{"text" => ta}} = Tools.call(ctx, "doc.read", %{"document" => a})
    {:ok, %{"text" => tb}} = Tools.call(ctx, "doc.read", %{"document" => b})
    assert ta =~ "DOC_A"
    assert tb =~ "DOC_B"
  end

  test "conflict scenario from §7: stale base_revision on the same span yields a snapshot", %{
    ctx: ctx
  } do
    {:ok, %{"document" => doc}} =
      Tools.call(ctx, "doc.open", %{"path" => "c.hwp", "open_opts" => [__text__: "제2조 본문 내용"]})

    # user/other writer advances rev 0 -> 1 on the same span
    {:ok, %{"revision" => 1}} =
      Tools.call(ctx, "doc.edit", %{
        "document" => doc,
        "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "USER"},
        "base_revision" => 0
      })

    # agent arrives with stale base_revision 0 targeting the same span -> conflict
    assert {:error, %{"conflict" => true, "current_revision" => 1, "snapshot" => snap}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "AGENT"},
               "base_revision" => 0
             })

    # agent retries against the current revision shown in the snapshot
    retry_rev = snap["revision"]
    assert retry_rev == 1

    assert {:ok, %{"ok" => true, "revision" => 2}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{"op" => "replace_text", "query" => "USER", "replacement" => "AGENT"},
               "base_revision" => retry_rev
             })

    {:ok, %{"text" => text}} = Tools.call(ctx, "doc.read", %{"document" => doc})
    assert text =~ "AGENT"
  end

  test "non-overlapping concurrent edits rebase cleanly (§6.5 common case)", %{ctx: ctx} do
    {:ok, %{"document" => doc}} =
      Tools.call(ctx, "doc.open", %{
        "path" => "d.hwp",
        "open_opts" => [__text__: "제2조 둘째\n제7조 일곱째"]
      })

    # writer at para 2
    {:ok, %{"revision" => 1}} =
      Tools.call(ctx, "doc.edit", %{
        "document" => doc,
        "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "SECOND"},
        "base_revision" => 0
      })

    # agent edits a *different* span with a now-stale base_revision -> rebased
    assert {:ok, %{"ok" => true, "revision" => 2, "rebased" => true}} =
             Tools.call(ctx, "doc.edit", %{
               "document" => doc,
               "op" => %{"op" => "replace_text", "query" => "제7조", "replacement" => "SEVENTH"},
               "base_revision" => 0
             })

    {:ok, %{"text" => text}} = Tools.call(ctx, "doc.read", %{"document" => doc})
    assert text =~ "SECOND"
    assert text =~ "SEVENTH"
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
