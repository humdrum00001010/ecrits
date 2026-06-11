defmodule Ecrits.Doc.PptxBuilderTest do
  @moduledoc """
  PptxBuilder is the doc.create scratch-deck engine. A generated deck must never
  fabricate content the caller didn't supply: a slide that OMITS metrics / cards /
  roadmap must render that section empty, not seed plausible-but-false placeholder
  numbers (observed: a cover with no metrics rendered "Speed 30% / Accuracy 18% /
  Coverage 2.4x"). The whole-deck default template (no slides at all) keeps its
  demo content — that is an explicit fallback, not fabrication.
  """

  use ExUnit.Case, async: true

  alias Ecrits.Doc.PptxBuilder

  defp slide_xml(deck, index) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ecrits-pptx-builder-#{System.unique_integer([:positive])}.pptx"
      )

    on_exit(fn -> File.rm(path) end)
    assert :ok = PptxBuilder.write(path, deck)
    {:ok, zip} = :zip.unzip(String.to_charlist(path), [:memory])

    {_name, body} =
      Enum.find(zip, fn {name, _} -> to_string(name) == "ppt/slides/slide#{index}.xml" end)

    body
  end

  test "a cover slide that omits metrics renders no fabricated metric placeholders" do
    deck = %{
      "title" => "Aria",
      "subtitle" => "AI study planner",
      "slides" => [
        %{"title" => "Aria", "subtitle" => "Plan smarter.", "section" => "Pitch deck"}
      ]
    }

    xml = slide_xml(deck, 1)

    # The hardcoded metrics/1 fallback must not leak onto a real authored slide.
    refute xml =~ "Speed"
    refute xml =~ "Accuracy"
    refute xml =~ "Coverage"
    # The agent's actual content is still present.
    assert xml =~ "Aria"
    assert xml =~ "Pitch deck"
  end

  test "supplied metrics ARE rendered" do
    deck = %{
      "title" => "Aria",
      "slides" => [
        %{
          "title" => "Aria",
          "metrics" => [%{"label" => "GPA lift", "value" => "34%", "delta" => "up"}]
        }
      ]
    }

    xml = slide_xml(deck, 1)
    assert xml =~ "GPA lift"
    assert xml =~ "34%"
  end

  test "a card slide that omits cards renders no fabricated card placeholders" do
    deck = %{
      "title" => "Aria",
      "slides" => [
        # index 2 → card template
        %{"title" => "Cover", "metrics" => [%{"label" => "x", "value" => "1"}]},
        %{"title" => "The problem", "subtitle" => "Real subtitle"}
      ]
    }

    xml = slide_xml(deck, 2)
    refute xml =~ "Clear goal"
    refute xml =~ "Focused execution"
    refute xml =~ "Measurable result"
    assert xml =~ "The problem"
  end

  test "a flow slide that omits roadmap renders no fabricated step placeholders" do
    deck = %{
      "title" => "Aria",
      "slides" => [
        %{"title" => "Cover", "metrics" => [%{"label" => "x", "value" => "1"}]},
        %{"title" => "Cards", "cards" => [%{"title" => "c", "body" => "b"}]},
        # index 3 → flow template
        %{"title" => "How it works", "subtitle" => "Flow"}
      ]
    }

    xml = slide_xml(deck, 3)
    refute xml =~ "Discover"
    refute xml =~ "Design"
    refute xml =~ "Build"
    refute xml =~ "Verify"
    assert xml =~ "How it works"
  end

  test "a deck with no slides builds a single cover from the caller's title — never a fabricated demo deck" do
    {:ok, zip} =
      (fn ->
         path =
           Path.join(System.tmp_dir!(), "ecrits-pptx-#{System.unique_integer([:positive])}.pptx")

         on_exit(fn -> File.rm(path) end)
         assert :ok = PptxBuilder.write(path, %{"title" => "Aria", "subtitle" => "Study planner"})
         :zip.unzip(String.to_charlist(path), [:memory])
       end).()

    slide_files =
      zip
      |> Enum.map(fn {n, _} -> to_string(n) end)
      |> Enum.filter(&String.match?(&1, ~r{^ppt/slides/slide\d+\.xml$}))

    # Exactly one cover slide — NOT a fabricated multi-slide FinMate deck.
    assert length(slide_files) == 1

    {_n, xml} = Enum.find(zip, fn {n, _} -> to_string(n) == "ppt/slides/slide1.xml" end)
    assert xml =~ "Aria"
    assert xml =~ "Study planner"
    # No invented branding / placeholder content from the old default_slides.
    refute xml =~ "FinMate"
    refute xml =~ "Prep time"
    refute xml =~ "Scattered context"
  end
end
