defmodule Ecrits.Doc.ToolPayload.CompactDeckTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.ToolPayload.CompactDeck

  test "summarizes authored slides through an embedded schema" do
    assert {:ok, deck} =
             CompactDeck.cast(%{
               "title" => "Board update",
               "subtitle" => "Q2",
               "slides" => [%{"title" => "Problem"}, %{"title" => "Solution"}]
             })

    assert CompactDeck.dump(deck) == %{
             "title" => "Board update",
             "subtitle" => "Q2",
             "slides" => 2,
             "slide_titles" => ["Problem", "Solution"]
           }
  end
end
