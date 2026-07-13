defmodule Ecrits.Doc.PptxFlatten do
  @moduledoc """
  Flatten a pptx to its animation FINAL state for the read-only office viewer.

  PowerPoint "build" slides (cache tables, step-by-step diagrams) store every
  animation state as overlapping shapes shown/hidden by `<p:timing>` — e.g. a
  cell with an *exit* effect on its old value (`Mem[0]`) and an *entrance* on the
  new one (`Mem[8]`). The LibreOffice→WASM viewer renders a slide statically
  (no animation playback), so it paints ALL build states at once → superimposed
  glyphs (`Mem[0]`/`Mem[8]`, `00010`/`00011`, doubled V/tag digits). This is
  inherent to a static render — a PDF export shows the same overlap (#57, symptom
  D, originally mis-filed as a tile-clear bug).

  `flatten_animations/1` approximates the post-animation state by dropping the
  shapes that the slide's *exit* effects make disappear, then removing the
  `<p:timing>` block (no animations left to drive). Entrance-only and un-animated
  shapes are untouched, so the table reads as it does at the end of the build.

  Heuristic (good enough for lecture builds, NOT a full animation engine): "a
  shape targeted by an exit effect is hidden at the end". A shape whose LAST
  effect is an entrance after an exit would be wrongly dropped; such patterns are
  rare in build decks. The transform is FAIL-SAFE: any parse/zip error returns the
  ORIGINAL bytes unchanged, so a malformed deck never yields corrupt output.

  This is a VIEW transform applied at the bytes-load path
  (`WorkspaceDocumentBytesController`). The wasm model therefore reflects the flattened
  deck; an edit+save would persist it (animations lost). Acceptable for the
  read-mostly lecture decks this targets; the on-disk file is untouched until an
  explicit save.
  """

  require Record
  Record.defrecordp(:xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl"))

  Record.defrecordp(
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  @shape_tags [:"p:sp", :"p:pic", :"p:graphicFrame", :"p:grpSp"]

  @doc """
  Return the pptx with animation builds flattened to their final state.

    * `{:ok, bytes}` — at least one slide was flattened
    * `:unchanged`   — the deck has no `<p:timing>` (nothing to do)
    * `{:error, reason}` — unzip/zip failed (caller should fall back to original)

  Never raises: a per-slide transform error keeps that slide's ORIGINAL xml.
  """
  @spec flatten_animations(binary) :: {:ok, binary} | :unchanged | {:error, term}
  def flatten_animations(pptx_bytes) when is_binary(pptx_bytes) do
    with {:ok, files} <- safe_unzip(pptx_bytes) do
      {out, changed?} =
        Enum.map_reduce(files, false, fn {name, content}, changed? ->
          if slide_with_timing?(name, content) do
            case flatten_slide_xml(content) do
              {xml, removed} when removed >= 0 and xml != content ->
                {{name, xml}, true}

              _ ->
                {{name, content}, changed?}
            end
          else
            {{name, content}, changed?}
          end
        end)

      if changed? do
        case :zip.create(~c"flattened.pptx", out, [:memory]) do
          {:ok, {_n, bytes}} -> {:ok, bytes}
          {:error, reason} -> {:error, reason}
        end
      else
        :unchanged
      end
    end
  end

  @doc """
  Flatten ONE slide xml: drop exit-targeted shapes + the `<p:timing>` block.
  Returns `{new_xml, removed_shape_count}`; on any error returns `{original, 0}`.
  """
  @spec flatten_slide_xml(binary) :: {binary, non_neg_integer}
  def flatten_slide_xml(xml) when is_binary(xml) do
    {doc, _rest} = :xmerl_scan.string(:erlang.binary_to_list(xml), namespace_conformant: false)
    exits = exit_spids(doc, MapSet.new())

    if MapSet.size(exits) == 0 and not has_timing?(doc) do
      {xml, 0}
    else
      {filtered, removed} = filter(doc, exits, 0)

      out =
        filtered
        |> List.wrap()
        |> :xmerl.export(:xmerl_xml)
        |> :unicode.characters_to_binary(:utf8)

      {out, removed}
    end
  rescue
    _ -> {xml, 0}
  catch
    _, _ -> {xml, 0}
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp slide_with_timing?(name, content) do
    String.match?(to_string(name), ~r{^ppt/slides/slide\d+\.xml$}) and
      String.contains?(content, "<p:timing>")
  end

  defp safe_unzip(bytes) do
    case :zip.unzip(bytes, [:memory]) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp child_els(el),
    do: Enum.filter(xmlElement(el, :content), &Record.is_record(&1, :xmlElement))

  defp attr(el, name) do
    Enum.find_value(xmlElement(el, :attributes), fn a ->
      if xmlAttribute(a, :name) == name, do: xmlAttribute(a, :value)
    end)
  end

  defp find_first(el, name) do
    if xmlElement(el, :name) == name,
      do: el,
      else: Enum.find_value(child_els(el), &find_first(&1, name))
  end

  defp own_id(el) do
    case find_first(el, :"p:cNvPr") do
      nil -> nil
      cnv -> attr(cnv, :id) |> to_string()
    end
  end

  defp has_timing?(el) do
    xmlElement(el, :name) == :"p:timing" or Enum.any?(child_els(el), &has_timing?/1)
  end

  defp collect(el, name, acc) do
    acc = if xmlElement(el, :name) == name, do: [el | acc], else: acc
    Enum.reduce(child_els(el), acc, &collect(&1, name, &2))
  end

  defp exit_spids(el, acc) do
    acc =
      if xmlElement(el, :name) == :"p:cTn" and attr(el, :presetClass) == ~c"exit" do
        Enum.reduce(collect(el, :"p:spTgt", []), acc, fn spt, a ->
          case attr(spt, :spid) do
            nil -> a
            id -> MapSet.put(a, to_string(id))
          end
        end)
      else
        acc
      end

    Enum.reduce(child_els(el), acc, &exit_spids(&1, &2))
  end

  # Returns {filtered_element | :drop, removed_count}
  defp filter(el, exits, removed) do
    cond do
      xmlElement(el, :name) == :"p:timing" ->
        {:drop, removed}

      xmlElement(el, :name) in @shape_tags and MapSet.member?(exits, own_id(el)) ->
        {:drop, removed + 1}

      true ->
        {kids, removed} =
          Enum.map_reduce(xmlElement(el, :content), removed, fn node, removed ->
            if Record.is_record(node, :xmlElement) do
              case filter(node, exits, removed) do
                {:drop, r} -> {:drop, r}
                {kept, r} -> {kept, r}
              end
            else
              {node, removed}
            end
          end)

        {xmlElement(el, content: Enum.reject(kids, &(&1 == :drop))), removed}
    end
  end
end
