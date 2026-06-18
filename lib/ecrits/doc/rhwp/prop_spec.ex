defmodule Ecrits.Doc.Rhwp.PropSpec do
  @moduledoc """
  One property translation: the engine `key` to emit and the `cast` that coerces
  the agent's value to what the engine's parser expects.

  Agents send the design's PascalCase (`Bold`, `Alignment`) or Office UNO names
  (`CharWeight`, `CharHeight`); the rhwp engine reads lowercase/camelCase keys
  (`bold`, `alignment`, `fontSize`). A `PropSpec` is the typed mapping for one
  such alias. `Rhwp.translate/2` consumes a `%{source_key => t()}` table;
  `Rhwp.cast/2` implements each `cast`.
  """

  @typedoc """
  The value coercion to apply (implemented by `Rhwp.cast/2`):

    * `:bool`             — truthiness (`Bold: true`)
    * `:weight_threshold` — Office `CharWeight` ≥ 150 ⇒ bold
    * `:font_weight`      — `"bold"` or ≥ 600 ⇒ bold
    * `:positive`         — `> 0` (Office `CharPosture`/`CharUnderline`)
    * `:verbatim`         — pass the value through (colors, font names)
    * `:font_size`        — points → 1/100 pt (10pt = 1000)
    * `:int`              — rounded integer (margins, spacing)
    * `:align`            — normalize to an engine alignment token
  """
  @type cast ::
          :bool
          | :weight_threshold
          | :font_weight
          | :positive
          | :verbatim
          | :font_size
          | :int
          | :align

  @type t :: %__MODULE__{key: String.t(), cast: cast()}

  @enforce_keys [:key, :cast]
  defstruct [:key, :cast]
end
