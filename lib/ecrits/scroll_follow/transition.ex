defmodule Ecrits.ScrollFollow.Transition do
  @moduledoc false

  import Ecto.Changeset

  alias Ecrits.ScrollFollow

  def observe(%ScrollFollow{} = state, attrs) do
    changeset = ScrollFollow.distance_changeset(attrs)

    if changeset.valid? do
      distance = changeset |> get_change(:distance) |> round()
      transition(state, %{pinned?: distance <= state.threshold, threshold: state.threshold})
    else
      state
    end
  end

  defp transition(state, attrs) do
    changeset = ScrollFollow.changeset(state, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: state
  end
end
