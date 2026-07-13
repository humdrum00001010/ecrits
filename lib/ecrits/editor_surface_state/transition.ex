defmodule Ecrits.EditorSurfaceState.Transition do
  @moduledoc false

  alias Ecrits.EditorSurfaceState

  def replace(%EditorSurfaceState{} = state, attrs) when is_map(attrs) do
    EditorSurfaceState.apply_attrs(state, attrs)
  end
end
