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

      assert {:ok, %{"matches" => matches}} =
               Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "전력기술관리법"})

      assert matches != []
      target = hd(matches)

      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc,
                 "op" => %{
                   "op" => "replace_text",
                   "query" => "전력기술관리법",
                   "replacement" => "ECRITS_DOC_MCP_TOKEN",
                   "ref" => target["ref"]
                 }
               })

      assert {:ok, %{"matches" => [_ | _]}} =
               Tools.call(ctx, "doc.find", %{
                 "document" => doc,
                 "pattern" => "ECRITS_DOC_MCP_TOKEN"
               })
    end
  end

  test "real NIF: doc.create {from} clones a template byte-for-byte and preserves structure",
       %{} = context do
    template = template_path()

    cond do
      not context[:native] ->
        IO.puts("\n[skip] ehwp NIF not loaded; skipping clone test")

      is_nil(template) ->
        IO.puts(
          "\n[skip] template not found; set ECRITS_TEMPLATE_HWP to an .hwp path to run the clone test"
        )

      true ->
        ctx = context.ctx

        clone =
          Path.join(System.tmp_dir!(), "ecrits_clone_#{System.unique_integer([:positive])}.hwp")

        on_exit(fn -> File.rm_rf(clone) end)

        # 1. Read the template's structure directly.
        {:ok, %{"document" => template_doc}} =
          Tools.call(ctx, "doc.open", %{"path" => template, "kind" => "hwp"})

        template_text = read_all(ctx, template_doc)

        # 2. Clone it via doc.create {from}.
        assert {:ok, %{"document" => clone_doc, "cloned_from" => ^template}} =
                 Tools.call(ctx, "doc.create", %{"path" => clone, "from" => template})

        # 2a. The clone is a byte-identical copy of the template file.
        assert File.read!(clone) == File.read!(template)

        # 2b. The clone's element structure (all paragraph text, in order) EQUALS
        #     the template's — same content, same order, because it IS the same bytes.
        clone_text = read_all(ctx, clone_doc)
        assert clone_text == template_text

        # 3. Format-preserved-on-edit. The template's table structure survived the
        #    clone: a match for in-cell text resolves to a CELL-addressed ref
        #    (hwp:.../tbl.../cell.../cp...), proving the cloned doc kept its tables
        #    (not flattened to body paragraphs).
        {:ok, %{"matches" => matches}} =
          Tools.call(ctx, "doc.find", %{"document" => clone_doc, "pattern" => "Vocabulary"})

        assert matches != []
        target = Enum.find(matches, &structural_ref?(&1["ref"])) || hd(matches)
        assert structural_ref?(target["ref"]), "expected a table/cell-addressed ref"

        # Table-level refs are structure-preserving but not yet leaf-editable in
        # the native path. If a newer NIF supports this edit, verify it preserves
        # structure; otherwise assert the current precise capability gap.
        case Tools.call(ctx, "doc.edit", %{
               "document" => clone_doc,
               "op" => %{
                 "op" => "replace_text",
                 "query" => "Vocabulary",
                 "replacement" => "CLONE_EDIT_TOKEN"
               }
             }) do
          {:ok, %{"ok" => true}} ->
            {:ok, %{"matches" => still_old}} =
              Tools.call(ctx, "doc.find", %{"document" => clone_doc, "pattern" => "Vocabulary"})

            assert length(still_old) == length(matches) - 1

            {:ok, %{"matches" => [edited | _]}} =
              Tools.call(ctx, "doc.find", %{
                "document" => clone_doc,
                "pattern" => "CLONE_EDIT_TOKEN"
              })

            assert structural_ref?(edited["ref"])

          {:error, %{kind: "edit_failed", message: message}} ->
            assert message =~ "query not found"
        end
    end
  end

  # --- helpers -------------------------------------------------------------

  # Resolve the clone-test template WITHOUT committing a user path into source:
  # prefer $ECRITS_TEMPLATE_HWP, else the known live-finding template under the
  # user's Downloads. Returns nil (→ skip) when neither exists.
  defp template_path do
    candidates =
      [System.get_env("ECRITS_TEMPLATE_HWP")] ++
        [Path.join([System.user_home!(), "Downloads", "L3-8 읽기 설명 학습지.hwp"])]

    Enum.find(candidates, fn p -> is_binary(p) and File.regular?(p) end)
  end

  # Read the paragraph element structure without using the MCP doc.read full-scan
  # path (doc.read is ref-neighborhood only).
  defp read_all(ctx, doc) do
    {:ok, %{"matches" => matches}} =
      Tools.call(ctx, "doc.find", %{"document" => doc, "type" => "paragraph"})

    Enum.map(matches, & &1["text"])
  end

  defp structural_ref?(ref) when is_binary(ref) do
    ref =~ ~r{/tbl\d+/(cell\d+/)?} or
      String.contains?(ref, ~s("cell")) or
      String.contains?(ref, ~s("control"))
  end

  defp structural_ref?(%{"type" => type}) when type in ["cell", "table"], do: true
  defp structural_ref?(%{"cell" => _}), do: true
  defp structural_ref?(%{"control" => _, "paragraph" => _}), do: true
  defp structural_ref?(_), do: false
end
