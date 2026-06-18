defmodule Ecrits.Doc.PptxFlattenTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.PptxFlatten

  @ns ~s(xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" ) <>
        ~s(xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main")

  defp slide_xml do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sld #{@ns}><p:cSld><p:spTree>
      <p:sp><p:nvSpPr><p:cNvPr id="2" name="old"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
        <p:txBody><a:bodyPr/><a:p><a:r><a:t>OLDVALUE</a:t></a:r></a:p></p:txBody></p:sp>
      <p:sp><p:nvSpPr><p:cNvPr id="3" name="new"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
        <p:txBody><a:bodyPr/><a:p><a:r><a:t>NEWVALUE</a:t></a:r></a:p></p:txBody></p:sp>
      <p:sp><p:nvSpPr><p:cNvPr id="4" name="static"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
        <p:txBody><a:bodyPr/><a:p><a:r><a:t>STATICVALUE</a:t></a:r></a:p></p:txBody></p:sp>
    </p:spTree></p:cSld>
    <p:timing><p:tnLst><p:par><p:cTn presetClass="exit"><p:childTnLst>
      <p:set><p:cBhvr><p:tgtEl><p:spTgt spid="2"/></p:tgtEl></p:cBhvr></p:set>
    </p:childTnLst></p:cTn></p:par></p:tnLst></p:timing>
    </p:sld>
    """
  end

  describe "flatten_slide_xml/1" do
    test "drops the exit-targeted shape and the timing, keeps the rest" do
      {out, removed} = PptxFlatten.flatten_slide_xml(slide_xml())

      assert removed == 1
      refute String.contains?(out, "OLDVALUE"), "exit-targeted shape should be gone"
      assert String.contains?(out, "NEWVALUE"), "entrance/new shape stays"
      assert String.contains?(out, "STATICVALUE"), "un-animated shape stays"
      refute String.contains?(out, "<p:timing>"), "timing block removed"
      # still well-formed: re-parse must succeed
      assert {_doc, _} = :xmerl_scan.string(:erlang.binary_to_list(out))
    end

    test "is fail-safe on malformed xml (returns original, 0)" do
      assert {"<p:sld>oops", 0} = PptxFlatten.flatten_slide_xml("<p:sld>oops")
    end
  end

  describe "flatten_animations/1" do
    test ":unchanged when the deck has no <p:timing>" do
      fixture = Path.join([__DIR__, "..", "..", "e2e", "fixtures", "office", "picture.pptx"])

      if File.exists?(fixture) do
        assert :unchanged = PptxFlatten.flatten_animations(File.read!(fixture))
      end
    end

    test "{:error, _} on non-zip bytes (caller falls back to original)" do
      assert {:error, _} = PptxFlatten.flatten_animations("not a zip at all")
    end
  end
end
