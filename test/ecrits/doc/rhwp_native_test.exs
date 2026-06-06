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
        clone = Path.join(System.tmp_dir!(), "ecrits_clone_#{System.unique_integer([:positive])}.hwp")
        on_exit(fn -> File.rm_rf(clone) end)

        # 1. Read the template's structure directly (open it, page every paragraph).
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
        target = hd(matches)
        assert target["ref"] =~ ~r{/tbl\d+/cell\d+/cp\d+}, "expected a cell-addressed ref"

        # replace_text scoped to that cell ref swaps the text IN PLACE.
        assert {:ok, %{"ok" => true, "revision" => 1}} =
                 Tools.call(ctx, "doc.edit", %{
                   "document" => clone_doc,
                   "op" => %{
                     "op" => "replace_text",
                     "query" => "Vocabulary",
                     "replacement" => "CLONE_EDIT_TOKEN",
                     "ref" => target["ref"]
                   },
                   "base_revision" => 0
                 })

        # The original cell text is gone and the replacement is present, STILL inside
        # a cell-addressed ref (hwp:.../tbl.../cell.../cp...) — the cell kept its
        # table structure through the in-place edit (format preserved on edit).
        {:ok, %{"matches" => still_old}} =
          Tools.call(ctx, "doc.find", %{"document" => clone_doc, "pattern" => "Vocabulary"})

        # one fewer "Vocabulary" than before the replacement (this cell's was swapped)
        assert length(still_old) == length(matches) - 1

        {:ok, %{"matches" => [edited | _]}} =
          Tools.call(ctx, "doc.find", %{"document" => clone_doc, "pattern" => "CLONE_EDIT_TOKEN"})

        assert edited["ref"] =~ ~r{/tbl\d+/cell\d+/cp\d+}
    end
  end

  test "real NIF: doc.read is capped at 30 paragraphs with a continuation cursor", %{} = context do
    unless context[:native] do
      IO.puts("\n[skip] ehwp NIF not loaded; skipping real-NIF cap test")
    else
      ctx = context.ctx

      {:ok, %{"document" => doc}} =
        Tools.call(ctx, "doc.open", %{"path" => @fixture, "kind" => "hwpx"})

      # The real contract is a 53-page document with hundreds of paragraphs;
      # a single read must still return at most 30 of them, plus a cursor.
      assert {:ok, page0} = Tools.call(ctx, "doc.read", %{"document" => doc})
      assert page0["size"] <= 30
      assert page0["size"] == 30
      assert length(page0["paragraphs"]) == 30
      assert page0["total"] > 30
      assert page0["next_at"] == 30
      assert page0["capped"] == 30

      # Paging advances and remains within the cap.
      assert {:ok, page1} = Tools.call(ctx, "doc.read", %{"document" => doc, "at" => 30})
      assert page1["at"] == 30
      assert page1["size"] <= 30
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

  # Page through the whole document via the 30-paragraph-capped doc.read cursor and
  # rejoin the paragraphs — the agent-visible "element structure" (text per
  # paragraph, in order) of the document.
  defp read_all(ctx, doc) do
    Stream.unfold(0, fn
      nil ->
        nil

      at ->
        {:ok, page} = Tools.call(ctx, "doc.read", %{"document" => doc, "at" => at})
        {page["paragraphs"], page["next_at"]}
    end)
    |> Enum.to_list()
    |> List.flatten()
  end
end
