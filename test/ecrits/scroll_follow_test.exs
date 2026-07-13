defmodule Ecrits.ScrollFollowTest do
  use ExUnit.Case, async: true

  alias Ecrits.ScrollFollow

  test "viewport measurements are cast and validated before changing pinned state" do
    follow = ScrollFollow.new()
    assert follow.pinned?

    refute follow |> ScrollFollow.observe(%{"distance" => 81.2}) |> Map.fetch!(:pinned?)
    assert follow |> ScrollFollow.observe(%{"distance" => "79"}) |> Map.fetch!(:pinned?)
    assert ScrollFollow.observe(follow, %{"distance" => "invalid"}) == follow
  end
end
