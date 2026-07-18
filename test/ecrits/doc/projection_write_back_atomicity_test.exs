defmodule Ecrits.Doc.ProjectionWriteBackAtomicityTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.{Pool, Projection}

  @fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)

  @tag :edit_failure
  test "a stale normalized retry cannot duplicate an earlier paragraph edit" do
    if not ehwp_available?(@fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping write-back atomicity regression")
    else
      path = copy_fixture()

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        File.rm_rf(Path.dirname(path))
      end)

      {:ok, original_bytes} = Projection.project_file(path)
      original = Jason.decode!(original_bytes)
      paragraph_40 = paragraph_text(original, 0, 40)

      stale_projection =
        original
        |> replace_text_runs(0, 40, paragraph_40 <> " P40_ONCE", [
          paragraph_40 <> " P40_ONCE"
        ])
        |> replace_text_runs(0, 25, ~s(  11. "일급방식" 테스트), [
          " ",
          " 11.",
          ~s( "일급방식" 테스트)
        ])
        |> encode_projection()

      assert {:ok, %{applied: applied}} =
               Projection.write_back(path, stale_projection, edit_id: "atomicity-first")

      assert applied > 0

      {:ok, canonical_after_first} = Projection.project_file(path)
      canonical_document = Jason.decode!(canonical_after_first)
      sha_after_first = sha256(path)

      assert paragraph_text(canonical_document, 0, 40) == paragraph_40 <> " P40_ONCE"
      assert length(char_runs(canonical_document, 0, 25)) == 1

      # The stale-run reconciliation reads the replayed pre-normalization bytes
      # as a semantic no-op: nothing applies and nothing mutates. (The FSKit
      # lane still fails this replay closed as :stale_projection_replay.)
      assert {:ok, %{applied: 0}} =
               Projection.write_back(path, stale_projection, edit_id: "atomicity-stale-retry")

      assert sha256(path) == sha_after_first
      assert paragraph_text(projected_document(path), 0, 40) == paragraph_40 <> " P40_ONCE"

      # Tampering with an engine-owned id is indistinguishable from a stale
      # normalization echo, so the id delta is ignored while the legitimate
      # text edit in the same payload still applies — and the canonical id is
      # preserved.
      tampered_projection =
        canonical_document
        |> replace_text_runs(0, 40, paragraph_40 <> " P40_ONCE TAMPER_SURVIVOR", [
          paragraph_40 <> " P40_ONCE TAMPER_SURVIVOR"
        ])
        |> update_in([Access.at(0), Access.at(40)], fn nodes ->
          Enum.map(nodes, fn
            %{"type" => "char", "charShapeId" => char_shape_id} = node ->
              Map.put(node, "charShapeId", char_shape_id + 1)

            node ->
              node
          end)
        end)
        |> encode_projection()

      canonical_shape_ids =
        canonical_document |> char_runs(0, 40) |> Enum.map(& &1["charShapeId"])

      assert {:ok, %{applied: applied_tampered}} =
               Projection.write_back(path, tampered_projection,
                 edit_id: "atomicity-ignored-read-only-tamper"
               )

      assert applied_tampered > 0

      after_tamper = projected_document(path)
      assert paragraph_text(after_tamper, 0, 40) == paragraph_40 <> " P40_ONCE TAMPER_SURVIVOR"

      assert after_tamper |> char_runs(0, 40) |> Enum.map(& &1["charShapeId"]) ==
               canonical_shape_ids
    end
  end

  defp replace_text_runs(document, section_index, paragraph_index, paragraph_text, run_texts) do
    update_in(document, [Access.at(section_index), Access.at(paragraph_index)], fn nodes ->
      {updated, []} =
        Enum.map_reduce(nodes, run_texts, fn
          %{"type" => "paragraph"} = node, remaining ->
            {Map.put(node, "text", paragraph_text), remaining}

          %{"type" => "char"} = node, [text | remaining] ->
            {Map.put(node, "text", text), remaining}

          node, remaining ->
            {node, remaining}
        end)

      updated
    end)
  end

  defp paragraph_text(document, section_index, paragraph_index) do
    document
    |> get_in([Access.at(section_index), Access.at(paragraph_index)])
    |> List.flatten()
    |> Enum.find_value(fn
      %{"type" => "paragraph", "text" => text} -> text
      _node -> nil
    end)
  end

  defp char_runs(document, section_index, paragraph_index) do
    document
    |> get_in([Access.at(section_index), Access.at(paragraph_index)])
    |> List.flatten()
    |> Enum.filter(&match?(%{"type" => "char"}, &1))
  end

  defp projected_document(path) do
    {:ok, bytes} = Projection.project_file(path)
    Jason.decode!(bytes)
  end

  defp encode_projection(document), do: Jason.encode!(document) <> "\n"

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp copy_fixture do
    root =
      Path.join(
        System.tmp_dir!(),
        "projection-write-back-atomicity-#{System.unique_integer([:positive])}"
      )
      |> tap(&File.mkdir_p!/1)

    path = Path.join(root, "contract.hwpx")
    File.cp!(@fixture, path)
    path
  end

  defp ehwp_available?(_fixture) do
    path = copy_fixture()

    try do
      case Pool.open(path, kind: :hwpx) do
        {:ok, _id} ->
          _ = Pool.close_by_path(path)
          true

        _other ->
          false
      end
    rescue
      _error -> false
    catch
      _kind, _reason -> false
    after
      File.rm_rf(Path.dirname(path))
    end
  end
end
