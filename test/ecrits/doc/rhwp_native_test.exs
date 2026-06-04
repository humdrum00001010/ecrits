defmodule Ecrits.Doc.RhwpNativeTest do
  @moduledoc """
  Smoke test against the *real* headless `ehwp` NIF (no fake runtime), proving
  the HWP backend is wired to the genuine engine. Skips automatically if the
  Rust NIF is not loaded (so the default suite stays toolchain-free).
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Tools

  @fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)

  setup do
    # Ensure the default (native) runtime is in effect for this case.
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
      {:ok, ctx: %{pool: pool}, native: true}
    else
      {:ok, native: false}
    end
  end

  test "real NIF: open -> find -> read -> edit replace_text round-trips", %{} = context do
    unless context[:native] do
      IO.puts("\n[skip] ehwp NIF not loaded; skipping real-NIF smoke test")
    else
      ctx = context.ctx

      assert {:ok, %{"document" => doc, "kind" => "hwpx"}} =
               Tools.call(ctx, "doc.open", %{"path" => @fixture, "kind" => "hwpx"})

      assert {:ok, %{"text" => before_text}} = Tools.call(ctx, "doc.read", %{"document" => doc})
      assert is_binary(before_text)
      assert before_text =~ "전력기술관리법"

      assert {:ok, %{"matches" => matches}} =
               Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "전력기술관리법"})

      assert matches != []

      assert {:ok, %{"ok" => true, "revision" => 1}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{
                   "op" => "replace_text",
                   "query" => "전력기술관리법",
                   "replacement" => "ECRITS_DOC_MCP_TOKEN"
                 },
                 "base_revision" => 0
               })

      assert {:ok, %{"text" => after_text}} = Tools.call(ctx, "doc.read", %{"document" => doc})
      assert after_text =~ "ECRITS_DOC_MCP_TOKEN"
    end
  end
end
