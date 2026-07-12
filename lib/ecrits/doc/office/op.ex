defmodule Ecrits.Doc.Office.Op.Builder do
  @moduledoc """
  The `defop` macro + field encoder backing `Ecrits.Doc.Office.Op`'s wire-op
  structs (#49 O1 — the office twin of `Ehwp.Op.Builder`). A macro can't be
  invoked in the module that defines it, so it lives here.

  `defop "wire_tag", field: kind, …` generates a struct under
  `Ecrits.Doc.Office.Op.<Camelize(tag)>` plus a `to_wire/1` that emits the
  string-keyed map the libreofficex UNO NIF expects — byte-identical to the
  legacy hand-built maps in `Ecrits.Doc.Office.to_uno_op/1`. Field kinds:

    * `:req`        — required scalar; `@enforce_keys`; always emitted
    * `:opt`        — optional scalar; default nil; emitted only when non-nil
    * `{:def, v}`   — scalar with a default; not enforced; emitted when non-nil

  The office wire ops carry ONLY scalars (the NIF's flat-JSON channel), so the
  encoder drops nils and stringifies keys — exactly what `scalar_op_fields/1`
  did. The IR-direct `insert_shape` (arbitrary UNO props) is hand-written in
  `Ecrits.Doc.Office.Op` rather than via this macro.
  """

  defmacro defop(tag, fields \\ []) do
    target = Module.concat(Ecrits.Doc.Office.Op, Macro.camelize(tag))
    enforced = for {name, kind} <- fields, kind == :req, do: name

    struct_fields =
      Enum.map(fields, fn
        {name, {:def, default}} -> {name, default}
        {name, _} -> {name, nil}
      end)

    quote do
      defmodule unquote(target) do
        @op_tag unquote(tag)
        @op_fields unquote(Macro.escape(fields))
        @enforce_keys unquote(enforced)
        defstruct unquote(struct_fields)

        @doc "The wire `op` discriminator for this variant."
        def op_tag, do: @op_tag

        @doc "String-keyed wire map (scalars only, nils dropped) for the UNO NIF."
        def to_wire(%__MODULE__{} = op) do
          Enum.reduce(@op_fields, %{"op" => @op_tag}, fn {name, _kind}, acc ->
            case Map.fetch!(op, name) do
              nil ->
                acc

              v when is_binary(v) or is_number(v) or is_boolean(v) ->
                Map.put(acc, Atom.to_string(name), v)

              _non_scalar ->
                acc
            end
          end)
        end
      end
    end
  end
end

defmodule Ecrits.Doc.Office.Op do
  @moduledoc """
  Typed Elixir mirror of the office (libreofficex) UNO wire-op vocabulary
  (#49 O1 — docx/pptx twin of the ehwp `Ehwp.Op` stack). One struct per WIRE op
  (the `"op"` the cpp `uno_apply` dispatches on); `@enforce_keys` makes a missing
  required field a construction-time error instead of a deep NIF rejection.

  `Ecrits.Doc.Office.to_uno_op/1` classifies an agent IR op (handling the
  conditional dispatch — replace_text→set_text/replace_all, insert_picture→
  insert_shape, …), builds the matching struct here, and serialises it with
  `to_wire/1`. The maps are byte-identical to the legacy hand-built ones, so the
  NIF + the browser `unoApply` are unchanged.
  """

  import Ecrits.Doc.Office.Op.Builder

  # ── text / paragraph ──────────────────────────────────────────────────────
  defop("set_text", ref: :req, text: :req)
  defop("replace_all", find: :req, replace: :req)
  defop("insert_text", ref: :req, text: :req)
  defop("insert_paragraph", ref: {:def, "end"}, text: :opt, style: :opt)
  defop("delete", ref: :req)
  defop("delete_node", ref: :req)
  defop("delete_paragraph", ref: :req)
  defop("split", ref: :req, at: :opt)
  defop("merge", ref: :req)
  defop("set_geometry", ref: :req, x: :opt, y: :opt, w: :opt, h: :opt)

  # ── tables ────────────────────────────────────────────────────────────────
  defop("insert_table", ref: {:def, "end"}, rows: :opt, cols: :opt, name: :opt)

  defop("insert_table_row",
    ref: :req,
    row: :opt,
    col: :opt,
    count: :opt,
    below: :opt,
    right: :opt
  )

  defop("delete_table_row",
    ref: :req,
    row: :opt,
    col: :opt,
    count: :opt,
    below: :opt,
    right: :opt
  )

  defop("insert_table_column",
    ref: :req,
    row: :opt,
    col: :opt,
    count: :opt,
    below: :opt,
    right: :opt
  )

  defop("delete_table_column",
    ref: :req,
    row: :opt,
    col: :opt,
    count: :opt,
    below: :opt,
    right: :opt
  )

  defop("merge_cells", ref: :req, start_row: :opt, start_col: :opt, end_row: :opt, end_col: :opt)
  defop("split_cell", ref: :req, row: :opt, col: :opt, rows: :opt, cols: :opt)

  # ── notes / equation / columns ────────────────────────────────────────────
  defop("insert_footnote", ref: :opt, text: :opt)
  defop("insert_endnote", ref: :opt, text: :opt)
  defop("insert_equation", ref: {:def, "end"}, script: :opt)
  defop("set_columns", ref: :opt, count: :opt, from: :opt, to: :opt, name: :opt, gap: :opt)

  # ── pictures / slides ─────────────────────────────────────────────────────
  defop("insert_picture", ref: {:def, "end"}, src: :req, w: :opt, h: :opt, name: :opt)
  defop("insert_slide", name: :opt, index: :opt)

  # ── insert_shape (IR-direct: typed geometry + arbitrary UNO props) ─────────
  defmodule InsertShape do
    @moduledoc """
    IR-direct slide shape op: the office arm passes ANY UNO property through
    verbatim, so the struct types the slide-frame fields and carries the rest in
    `props` (raw key→value). `to_wire/1` applies the same scalar-filter + UNO
    property normalisation + fill/line style pairing the legacy path did.
    """
    @enforce_keys [:page]
    defstruct page: nil,
              name: nil,
              service: nil,
              x: nil,
              y: nil,
              w: nil,
              h: nil,
              text: nil,
              props: %{}

    alias Ecrits.Doc.Office.Props

    def to_wire(%__MODULE__{} = op) do
      frame = %{
        page: op.page,
        name: op.name,
        service: op.service,
        x: op.x,
        y: op.y,
        w: op.w,
        h: op.h,
        text: op.text
      }

      %{"op" => "insert_shape"}
      |> Map.merge(Props.scalar_props(frame))
      |> Map.merge(Props.scalar_props(op.props))
      |> Props.pair_fill_styles()
      |> Props.default_no_outline()
    end
  end
end

defmodule Ecrits.Doc.Office.Props do
  @moduledoc """
  Shared UNO property normalisation for the office arm: the `set/3` property
  edit AND `insert_shape`'s IR-direct props both flow through here (#49 O1).
  The doc.edit op schema documents both arms, so agents mix HWP shape vocabulary
  into slide ops (`fillColor`, `fillType`, …); these map them onto real UNO
  property names, accept CSS hex for any *Color, and drop HWP-only keys that
  would otherwise no-op invisibly.
  """
  @hwp_only ~w(fillBgColor BackgroundColor shape_type width height)

  @doc "A map → string-keyed scalar UNO props (aliases normalised, hex→int, non-scalars dropped)."
  def scalar_props(map) do
    map
    |> Enum.flat_map(fn {k, v} ->
      if is_binary(v) or is_number(v) or is_boolean(v), do: normalize(to_string(k), v), else: []
    end)
    |> Map.new()
  end

  @doc "Normalise one prop key/value → `[{key, value}]` (or `[]` to drop it)."
  def normalize(key, _v) when key in @hwp_only, do: []
  def normalize("fillColor", v), do: normalize("FillColor", v)
  def normalize("lineColor", v), do: normalize("LineColor", v)
  def normalize("charColor", v), do: normalize("CharColor", v)
  # HWP-arm fillType maps onto UNO FillStyle (enum: 0=NONE, 1=SOLID).
  def normalize("fillType", "none"), do: [{"FillStyle", 0}]
  def normalize("fillType", "solid"), do: [{"FillStyle", 1}]
  def normalize("fillType", _), do: []

  def normalize(key, v) when is_binary(v) do
    if String.ends_with?(key, "Color") do
      case css_hex_to_int(v) do
        {:ok, int} -> [{key, int}]
        :error -> [{key, v}]
      end
    else
      [{key, v}]
    end
  end

  def normalize(key, v), do: [{key, v}]

  @doc """
  A bare FillColor/LineColor doesn't make the fill/line visible — the style enum
  stays default and the OOXML exporter writes no fill (theme green paints it). So
  pair the color with style=SOLID and ColorTheme=-1 (clear the theme binding)
  unless the caller already set them.
  """
  def pair_fill_styles(fields) do
    fields
    |> maybe_pair("FillColor", "FillStyle", 1)
    |> maybe_pair("LineColor", "LineStyle", 1)
    |> maybe_pair("FillColor", "FillColorTheme", -1)
    |> maybe_pair("LineColor", "LineColorTheme", -1)
  end

  @doc "A shape with no Line* keys gets NO outline (else LibreOffice draws a default green border)."
  def default_no_outline(fields) do
    if Enum.any?(Map.keys(fields), &String.starts_with?(&1, "Line")),
      do: fields,
      else: Map.put(fields, "LineStyle", 0)
  end

  defp maybe_pair(fields, color_key, style_key, solid) do
    if Map.has_key?(fields, color_key) and not Map.has_key?(fields, style_key),
      do: Map.put(fields, style_key, solid),
      else: fields
  end

  defp css_hex_to_int("#" <> hex), do: css_hex_to_int(hex)

  defp css_hex_to_int(hex) when byte_size(hex) == 6 do
    case Integer.parse(hex, 16) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp css_hex_to_int(_), do: :error
end
