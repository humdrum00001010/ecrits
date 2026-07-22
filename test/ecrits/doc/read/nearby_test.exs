defmodule Ecrits.Doc.Read.NearbyTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.Read.Nearby

  test "casts defaults and clamps counts" do
    assert {:ok, %Nearby{} = nearby} =
             Nearby.cast(%{"before" => 20, "after" => -1, "column" => true})

    assert Nearby.dump(nearby) == %{
             "before" => 10,
             "after" => 2,
             "row" => true,
             "column" => true,
             "headers" => true
           }
  end

  test "non-map input receives the canonical defaults" do
    assert {:ok, nearby} = Nearby.cast(nil)
    assert Nearby.dump(nearby)["before"] == 2
  end
end
