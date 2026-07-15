defmodule Ecrits.Doc.Rhwp do
  @moduledoc """
  HWP/HWPX backend for `Ecrits.Doc`, served by the headless `ehwp` server NIF.

  This is the **server arm** of the design (§2.1, §3): the authoritative model
  for documents that are *not* currently open in a browser. Rendering is the
  browser's job; this backend only opens, reads, finds, and edits the in-memory
  model through the `Ehwp` facade.

  ## Capability honesty

  The current `ehwp` NIF exposes `open`/`read`/`find`/`write({:replace_one})`
  (plus `page_count`/`render_page_svg`/`profile`). The design's richer
  edit-only NIF surface — `get/set_*_properties`, `apply_char_format`, structural
  verbs, and `save`/export — is a *future* `ehwp` revival (design §8 "다음" #1,
  #6). Until those NIFs land, the corresponding callbacks return
  `{:error, {:not_supported, reason}}` rather than silently faking success.

  Mapped today:

    * `read/2`            -> `Ehwp.read/2`, **capped at 30 paragraphs/call**
      with a continuation cursor (`next_at`) so the agent pages through a long
      document instead of ever pulling the whole thing (design §4.4, the user's
      hard limit). The `ehwp` NIF returns the *entire* document text in one
      string with no native windowing, so the cap and pagination are enforced
      here, in Elixir, in `read/2`.
    * `find/3`            -> `Ehwp.find/3`
    * `outline/3`         -> synthesised from `read` text (paragraph tree)
    * `inspect/2`         -> reflective discovery: element type + the *native*
      property names (`Bold`/`Italic`/`FontSize`/`Width`/…) that `get`/`set`
      understand for that element kind + child refs. This needs no new NIF —
      it mirrors the engine vocabulary (design §4.1). Surfaced to the agent
      through `doc.get` (the standalone `doc.inspect` tool was folded in).
    * `edit replace_text` -> `Ehwp.write(handle, {:replace_one, q, r})`

  `set/3` is the UNIVERSAL property setter: char-run formatting
  (Bold/Italic/FontSize/TextColor/…) routes to the range-oriented
  `apply_char_format` op, while picture/shape/table/cell (incl. cell
  `BackgroundColor`) and paragraph properties route to
  `set_properties kind:<k>`. The NIF also accepts `set_properties kind:char`
  for IR-direct callers carrying `offset`/`length`.
  """

  @behaviour Ecrits.Doc

  alias Ecrits.Doc.Op
  alias Ecrits.Doc.Rhwp.Image
  alias Ecrits.Doc.Rhwp.PropSpec
  alias Ecrits.Doc.Rhwp.Ref

  @typedoc "Engine handle: the `Ehwp.Handle` plus cached paragraph offsets."
  @type handle :: %{ehwp: Ehwp.Handle.t() | term(), sec: non_neg_integer()}

  @impl true
  def kind, do: :hwp

  @impl true
  def open(path, opts \\ []) do
    case Ehwp.open(path, opts) do
      {:ok, ehwp_handle, _metadata} -> {:ok, %{ehwp: ehwp_handle, sec: 0}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  # Create a NEW blank document from the engine's embedded blank2010 template
  # (`Ehwp.new/0`). The agent authors content into it via `edit` and persists it
  # with `save` (which needs a target path). No path is bound to the handle.
  def new(_opts \\ []) do
    case Ehwp.new() do
      {:ok, ehwp_handle, _metadata} -> {:ok, %{ehwp: ehwp_handle, sec: 0}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def close(%{ehwp: ehwp_handle}), do: Ehwp.close(ehwp_handle)
  def close(_handle), do: :ok

  @doc false
  def render_preview(%{ehwp: ehwp_handle}, target, opts),
    do: Ehwp.render_preview(ehwp_handle, target, opts)

  # Hard cap on `doc.read`: a single call NEVER returns more than this many
  # paragraphs (the user's explicit limit, design §4.4). The agent pages
  # through long documents via the returned `next_at` cursor. Enforced below
  # in `read/2` and mirrored in the tool's inputSchema/description.
  @read_paragraph_cap 30

  @doc "The maximum number of paragraphs a single `read/2` (doc.read) may return."
  @spec read_paragraph_cap() :: pos_integer()
  def read_paragraph_cap, do: @read_paragraph_cap

  @impl true
  def read(%{ehwp: ehwp_handle}, opts) do
    case Ehwp.read(ehwp_handle, Keyword.take(opts, [:case_sensitive])) do
      {:ok, result} ->
        {:ok, window_paragraphs(normalize_text(result), opts)}

      {:error, _reason} = error ->
        error
    end
  end

  # Page through the document by paragraph. `at` is the 0-based paragraph index
  # to start from; `size` is the *requested* paragraph count, clamped to the
  # 30-paragraph cap. The returned chunk text rejoins the windowed paragraphs;
  # `next_at` is the cursor for the following page (nil once the end is reached).
  defp window_paragraphs(text, opts) do
    paragraphs = split_paragraphs(text)
    total = length(paragraphs)

    at = opts |> Keyword.get(:at, 0) |> normalize_index(0)

    size =
      opts
      |> Keyword.get(:size, @read_paragraph_cap)
      |> normalize_index(@read_paragraph_cap)
      # HARD CAP: never exceed @read_paragraph_cap paragraphs in one read.
      |> min(@read_paragraph_cap)
      |> max(1)

    window = paragraphs |> Enum.drop(at) |> Enum.take(size)
    returned = length(window)
    next_at = if at + returned < total, do: at + returned, else: nil
    chunk = Enum.join(window, "\n")

    %{
      text: chunk,
      at: at,
      size: returned,
      paragraphs: window,
      total: total,
      next_at: next_at,
      capped: @read_paragraph_cap
    }
  end

  defp normalize_index(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_index(_value, default), do: default

  @impl true
  def find(%{ehwp: ehwp_handle} = handle, pattern, opts) when is_binary(pattern) do
    case Ehwp.find(ehwp_handle, pattern, Keyword.take(opts, [:case_sensitive])) do
      {:ok, result} ->
        sec = handle.sec
        matches = result |> decode_matches() |> Enum.map(&match_to_ref(&1, sec, pattern))
        {:ok, matches}

      {:error, _reason} = error ->
        error
    end
  end

  def find(_handle, _pattern, _opts), do: {:error, :invalid_pattern}

  @impl true
  # Full-IR element enumeration via the ehwp NIF `{"q":"elements"}` verb (the
  # shared core enumerator, identical JSON to the browser's `enumerateElements`).
  #
  # Returns `{:ok, nodes}` with each node carrying `ref`/`type`/`text`
  # (+`row`/`col` for cells) plus a per-cell `context` breadcrumb
  # ("<table caption> › <column header> / <row label>"). Guarded for backward
  # compatibility: if the DEPLOYED NIF lacks the `elements` verb, `Ehwp.query`
  # errors and we surface `{:error, {:not_supported, _}}` so the Tools layer
  # falls back to `find/3`/`read/2`.
  def elements(%{ehwp: ehwp_handle}, _opts) do
    # A NIF predating the `elements` verb may not just return an error — it can
    # raise (UndefinedFunctionError) or exit. Treat EVERY non-`{:ok, list/json}`
    # outcome as a capability gap so the Tools layer cleanly falls back to
    # find/read instead of crashing the owning Editor process.
    case safe_query(ehwp_handle, %{q: "elements"}) do
      {:ok, json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, nodes} when is_list(nodes) ->
            {:ok, nodes |> attach_context() |> enrich_picture_nodes(ehwp_handle)}

          _ ->
            {:error, {:not_supported, "elements query returned non-array"}}
        end

      {:ok, nodes} when is_list(nodes) ->
        {:ok, nodes |> attach_context() |> enrich_picture_nodes(ehwp_handle)}

      {:error, reason} ->
        {:error, {:not_supported, inspect(reason)}}

      other ->
        {:error, {:not_supported, inspect(other)}}
    end
  end

  def elements(_handle, _opts), do: {:error, {:not_supported, "no ehwp handle"}}

  @projected_picture_props ~w(width height treatAsChar
                              vertRelTo vertAlign horzRelTo horzAlign
                              vertOffset horzOffset textWrap restrictInPage allowOverlap sizeProtect
                              brightness contrast effect transparency description
                              rotationAngle horzFlip vertFlip originalWidth originalHeight
                              cropLeft cropTop cropRight cropBottom
                              paddingLeft paddingTop paddingRight paddingBottom
                              outerMarginLeft outerMarginTop outerMarginRight outerMarginBottom
                              borderColor borderWidth
                              hasCaption captionDirection captionVertAlign captionWidth
                              captionSpacing captionMaxWidth captionIncludeMargin externalPath)

  defp enrich_picture_nodes(nodes, ehwp_handle) do
    Enum.map(nodes, fn
      %{"type" => "picture", "ref" => ref} = node when is_map(ref) ->
        case get(%{ehwp: ehwp_handle}, ref, @projected_picture_props) do
          {:ok, props} when is_map(props) ->
            Map.merge(node, Map.take(props, @projected_picture_props))

          _ ->
            node
        end

      node ->
        node
    end)
  end

  # Run an ehwp read query, converting a raise/exit (older NIF without the verb,
  # crashed session) into an `{:error, _}` so the caller never propagates it.
  defp safe_query(ehwp_handle, query) do
    Ehwp.query(ehwp_handle, query)
  rescue
    e -> {:error, {:query_raised, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:query_exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  # Walk the DFS-ordered enumerator nodes and attach a `context` breadcrumb to
  # every in-table BODY cell. Cells arrive grouped after their `table` node, so a
  # first pass indexes, per table, the row-0 cells (column headers) and col-0
  # cells (row labels). A body cell at (r,c) with r>0,c>0 is then annotated
  # "<column header> / <row label>", letting the agent see WHICH column/row a
  # match sits in (e.g. "5월 / 품질관리협의체 운영계획 수립"). Header/label cells
  # (row 0 or col 0) are their OWN context, so they are left unannotated rather
  # than self-referencing.
  defp attach_context(nodes) do
    {headers, labels} = index_table_axes(nodes)

    nodes
    |> Enum.map_reduce(nil, fn node, current_table ->
      table_key = table_key_of(node, current_table)
      annotated = node |> embed_ref_type() |> annotate_node(table_key, headers, labels)
      {annotated, table_key}
    end)
    |> elem(0)
  end

  # Make a non-cell IR control ref SELF-DESCRIBING: the enumerator emits the
  # element `type` ("picture"/"shape"/…) as a SIBLING of the ref object, not
  # inside it — so once a `doc.find` hands the bare ref back, the type is lost and
  # `doc.get`/`doc.set` route it as a generic char run (returning char formatting,
  # not the object's geometry, and rejecting geometry sets). Copy `type` INTO the
  # ref map for control-bearing refs (those with a top-level `control` index) so
  # `Ref.decode` yields `kind: :control, type: "picture"` and get/set hit the
  # picture/shape native handlers. Cells (control nested under `cell`) and plain
  # body refs are untouched.
  defp embed_ref_type(%{} = node) do
    type = node["type"] || node[:type]
    ref = node["ref"] || node[:ref]

    case {type, ref} do
      {t, %{} = r} when is_binary(t) ->
        if control_ref?(r) and is_nil(r["type"]) do
          put_node_ref(node, Map.put(r, "type", t))
        else
          node
        end

      _ ->
        node
    end
  end

  defp embed_ref_type(node), do: node

  # A non-cell control ref carries a TOP-LEVEL integer `control` and no nested
  # `cell` object (a table cell nests its control index under `cell`).
  defp control_ref?(%{} = ref) do
    is_integer(ref["control"] || ref[:control]) and
      not is_map(ref["cell"] || ref[:cell])
  end

  defp put_node_ref(node, ref) do
    cond do
      Map.has_key?(node, "ref") -> Map.put(node, "ref", ref)
      Map.has_key?(node, :ref) -> Map.put(node, :ref, ref)
      true -> node
    end
  end

  # Per-table axis index: column headers by col index (row-0 cells) and row
  # labels by row index (col-0 cells), keyed by the owning `table` node's ref.
  defp index_table_axes(nodes) do
    {headers, labels, _cur} =
      Enum.reduce(nodes, {%{}, %{}, nil}, fn node, {h, l, cur} ->
        type = node["type"] || node[:type]
        text = node["text"] || node[:text] || ""

        case type do
          "table" ->
            {h, l, node["ref"] || node[:ref]}

          "cell" ->
            row = node["row"] || node[:row]
            col = node["col"] || node[:col]

            h2 = if row == 0 and is_integer(col), do: deep_put(h, cur, col, text), else: h
            l2 = if col == 0 and is_integer(row), do: deep_put(l, cur, row, text), else: l
            {h2, l2, cur}

          _ ->
            {h, l, cur}
        end
      end)

    {headers, labels}
  end

  defp deep_put(map, nil, _k, _v), do: map
  defp deep_put(map, table, k, v), do: Map.update(map, table, %{k => v}, &Map.put(&1, k, v))

  # The owning-table identity for a node: a `table` node IS its own table; a
  # `cell` (or anything until the next table) keeps the current table. A
  # top-level paragraph between tables clears the scope so a later cell can't
  # borrow a stale table.
  defp table_key_of(node, current_table) do
    case node["type"] || node[:type] do
      "table" -> node["ref"] || node[:ref]
      "cell" -> current_table
      "paragraph" -> nil
      _ -> current_table
    end
  end

  defp annotate_node(node, table_key, headers, labels)
       when not is_nil(table_key) do
    case node["type"] || node[:type] do
      "cell" ->
        row = node["row"] || node[:row]
        col = node["col"] || node[:col]

        # Only body cells (past BOTH the header row and the label column) get a
        # breadcrumb; the row-0 headers and col-0 labels are self-evident.
        if is_integer(row) and is_integer(col) and row > 0 and col > 0 do
          ctx = [table_axis(headers, table_key, col), table_axis(labels, table_key, row)]

          case build_breadcrumb(ctx) do
            "" -> node
            breadcrumb -> Map.put(node, "context", breadcrumb)
          end
        else
          node
        end

      _ ->
        node
    end
  end

  defp annotate_node(node, _table_key, _headers, _labels), do: node

  # Look up an axis label (column header / row label) for `index` within the
  # given table's axis map. `table_key` is the table's ref (a map or string), so
  # fetch the per-table map first, then the index.
  defp table_axis(axis_map, table_key, index) do
    case Map.get(axis_map, table_key) do
      %{} = per_table -> Map.get(per_table, index)
      _ -> nil
    end
  end

  # "<column header> / <row label>": the header/label pair joined by " / ",
  # dropping blank segments so a header-only or label-only cell still reads well.
  defp build_breadcrumb([header, label]) do
    [header, label]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" / ")
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  @impl true
  def outline(%{ehwp: ehwp_handle} = handle, ref, _opts) do
    with {:ok, scope} <- scope_ref(ref),
         {:ok, text} <- read_text(ehwp_handle) do
      {:ok, build_outline(text, handle.sec, scope)}
    end
  end

  # Native property vocabulary per element kind (HWP/UNO model, design §4.1,
  # §4.5). `inspect` reports these so the agent discovers property names instead
  # of hard-coding them; `get`/`set` accept exactly these names (once the
  # property NIFs land). HWP-native casing, mirroring the design's `Bold`/`Width`.
  @char_props ~w(Bold Italic Underline StrikeOut FontName FontSize TextColor
                 ShadeColor SuperScript SubScript)
  @paragraph_props ~w(Alignment LineSpacing IndentLeft IndentRight IndentFirst
                      SpaceBefore SpaceAfter StyleName) ++ @char_props
  @picture_props ~w(Width Height PosX PosY TreatAsChar Caption)
  @shape_props ~w(Width Height PosX PosY FillColor LineColor Rotation)
  @cell_props ~w(Width Height BackgroundColor BorderType VerticalAlign) ++ @char_props

  @doc false
  @spec native_props(atom()) :: [String.t()]
  def native_props(:char), do: @char_props
  def native_props(:paragraph), do: @paragraph_props
  def native_props(:picture), do: @picture_props
  def native_props(:shape), do: @shape_props
  def native_props(:cell), do: @cell_props
  # A doc.find cell ref is a char run INSIDE a cell; for inspect/get/set surface
  # the cell's settable names (incl. BackgroundColor) so the agent can read/fill
  # table fields straight from the find ref.
  def native_props(:cell_char), do: @cell_props
  def native_props(_other), do: []

  @impl true
  def inspect(%{ehwp: ehwp_handle} = handle, ref) do
    with {:ok, decoded} <- decode_or_document(ref) do
      {:ok, build_inspect(handle, ehwp_handle, ref, decoded)}
    end
  end

  defp decode_or_document(nil), do: {:ok, %{kind: :document}}
  defp decode_or_document(ref) when is_binary(ref), do: Ref.decode(ref)
  defp decode_or_document(_ref), do: {:error, :invalid_ref}

  # Reflective description of `ref`: its element type, the native property names
  # `get`/`set` understand for it, the interfaces it conceptually supports, and
  # (for container refs) its immediate children. This is the rhwp analogue of
  # Office's `XServiceInfo`/`XPropertySetInfo`/children discovery (design §4.4).
  defp build_inspect(handle, ehwp_handle, ref, %{kind: kind} = decoded) do
    # A non-cell IR control ref (`kind: :control`) carries the concrete element
    # type ("picture"/"shape"/"field"/…) in `:type`; resolve it to the atom the
    # type/interface/property vocabulary is keyed on so e.g. a picture ref reports
    # picture props. Other kinds map straight through.
    eff_kind = effective_kind(decoded)
    type = element_type(eff_kind)
    canonical_ref = if is_binary(ref), do: ref, else: Ref.encode(decoded)

    base = %{
      ref: canonical_ref,
      type: type,
      kind: Atom.to_string(eff_kind),
      interfaces: interfaces_for(eff_kind),
      properties: native_props(eff_kind)
    }

    case kind do
      k when k in [:document, :section, :paragraph] ->
        case outline(handle, document_or_self(decoded), depth: 1) do
          {:ok, %{children: children}} -> Map.put(base, :children, child_summaries(children))
          _ -> Map.put(base, :children, [])
        end

      _ ->
        # leaf-ish element (char run, picture, shape, cell, field, …): no child
        # enumeration.
        _ = ehwp_handle
        Map.put(base, :children, [])
    end
  end

  # The concrete element-type atom a decoded ref reports. For a `:control` ref
  # the enumerator's `:type` string (e.g. "picture") is the real kind; fall back
  # to `:control` when it is missing/unknown. Every other decoded ref keeps its
  # own `:kind`.
  defp effective_kind(%{kind: :control, type: type}) when is_binary(type) do
    case type do
      "picture" -> :picture
      "shape" -> :shape
      "cell" -> :cell
      "paragraph" -> :paragraph
      other -> safe_kind_atom(other)
    end
  end

  defp effective_kind(%{kind: kind}), do: kind

  # Map an enumerator type string to an atom WITHOUT minting new atoms at runtime
  # (avoids atom-table exhaustion from untrusted input): only known IR kinds are
  # converted; anything else stays the generic `:control`.
  @ir_control_kinds ~w(table field form equation header footer footnote endnote
                       bookmark hyperlink ruby char_overlap auto_number new_number
                       page_number_pos page_hide hidden_comment section_def
                       column_def unknown)
  defp safe_kind_atom(type) when type in @ir_control_kinds, do: String.to_atom(type)
  defp safe_kind_atom(_type), do: :control

  defp document_or_self(%{kind: :document}), do: nil
  defp document_or_self(decoded), do: Ref.encode(decoded)

  defp child_summaries(children) do
    Enum.map(children, fn child ->
      %{ref: child.ref, type: child.type}
    end)
  end

  defp element_type(:document), do: "document"
  defp element_type(:section), do: "section"
  defp element_type(:paragraph), do: "paragraph"
  defp element_type(:char), do: "char_run"
  defp element_type(:picture), do: "picture"
  defp element_type(:shape), do: "shape"
  defp element_type(:cell), do: "cell"
  defp element_type(:cell_char), do: "cell"
  # Every other IR control kind (table/field/form/equation/header/footer/…)
  # reports its own snake_case name; `:control` is the generic fallback.
  defp element_type(other), do: Atom.to_string(other)

  # Conceptual interface set, mirroring how Office reports XServiceInfo. For
  # rhwp these are advisory tags telling the agent which verbs apply.
  defp interfaces_for(:document), do: ["Document", "Container"]
  defp interfaces_for(:section), do: ["Section", "Container"]
  defp interfaces_for(:paragraph), do: ["Paragraph", "Container", "CharProperties"]
  defp interfaces_for(:char), do: ["CharRun", "CharProperties"]
  defp interfaces_for(:picture), do: ["Picture", "Positioned"]
  defp interfaces_for(:shape), do: ["Shape", "Positioned"]
  defp interfaces_for(:cell), do: ["Cell", "Container", "CharProperties"]
  # New full-IR control kinds surfaced by the element enumerator.
  defp interfaces_for(:table), do: ["Table", "Container"]
  defp interfaces_for(:field), do: ["Field"]
  defp interfaces_for(:form), do: ["Form"]
  defp interfaces_for(:equation), do: ["Equation"]
  defp interfaces_for(:header), do: ["Header", "Container"]
  defp interfaces_for(:footer), do: ["Footer", "Container"]
  defp interfaces_for(:footnote), do: ["Footnote", "Container"]
  defp interfaces_for(:endnote), do: ["Endnote", "Container"]
  defp interfaces_for(:control), do: ["Control"]
  defp interfaces_for(_other), do: []

  @impl true
  # IR-direct property read: query get_properties at the ref. `props` (a name
  # list) narrows the returned set when given.
  def get(%{ehwp: ehwp_handle}, ref, props) do
    q =
      %{q: "get_properties", kind: ref_kind(ref)}
      |> Map.merge(flatten_ref(ref))
      |> maybe_put(:props, present_list(props))

    case Ehwp.query(ehwp_handle, q) do
      {:ok, json} -> {:ok, decode_write(json)}
      {:error, reason} -> {:error, query_error(reason)}
    end
  end

  @impl true
  # IR-direct property edit. `set` is the UNIVERSAL property setter for every
  # element kind, so it must route to the right native op:
  #
  #   * char-run formatting (Bold/Italic/Underline/FontName/FontSize/TextColor/…)
  #     goes through the range-oriented `apply_char_format` op. The NIF also
  #     accepts `set_properties kind:char` for lower-level IR callers.
  #   * picture/shape/table/cell/paragraph properties (incl. cell BackgroundColor,
  #     paragraph Alignment/LineSpacing) go through `set_properties kind:<k>`,
  #     which the NIF accepts.
  #
  # `kind` comes from the props map if the caller embedded it (e.g. {kind:"cell",
  # BackgroundColor}), else it is inferred from the ref.
  #
  # ── Property translation specs ───────────────────────────────────────────
  # The engine's char/para parsers read camelCase/lowercase keys; agents send
  # the design's PascalCase or Office UNO names. Each spec maps a source key to a
  # typed `%PropSpec{key, cast}` (the engine key + how to coerce the value).
  # `translate/2` is the single eval: for every prop, look up its spec and
  # `cast/2` the value by its `cast` type; a key with no spec is already an
  # engine key (or unknown) and passes through verbatim. Adding a vocabulary
  # alias is one row, not another `case` arm.
  @char_prop_spec %{
    # Office UNO vocabulary
    "CharWeight" => %PropSpec{key: "bold", cast: :weight_threshold},
    "FontWeight" => %PropSpec{key: "bold", cast: :font_weight},
    "CharPosture" => %PropSpec{key: "italic", cast: :positive},
    "CharUnderline" => %PropSpec{key: "underline", cast: :positive},
    "CharColor" => %PropSpec{key: "textColor", cast: :verbatim},
    "CharHeight" => %PropSpec{key: "fontSize", cast: :font_size},
    # Design PascalCase → engine
    "Bold" => %PropSpec{key: "bold", cast: :bool},
    "Italic" => %PropSpec{key: "italic", cast: :bool},
    "Underline" => %PropSpec{key: "underline", cast: :bool},
    "StrikeOut" => %PropSpec{key: "strikethrough", cast: :bool},
    "Strikethrough" => %PropSpec{key: "strikethrough", cast: :bool},
    "TextColor" => %PropSpec{key: "textColor", cast: :verbatim},
    "ShadeColor" => %PropSpec{key: "shadeColor", cast: :verbatim},
    "FontSize" => %PropSpec{key: "fontSize", cast: :font_size},
    "SuperScript" => %PropSpec{key: "superscript", cast: :bool},
    "SubScript" => %PropSpec{key: "subscript", cast: :bool},
    "fontSize" => %PropSpec{key: "fontSize", cast: :font_size}
  }

  @para_prop_spec %{
    "Alignment" => %PropSpec{key: "alignment", cast: :align},
    "alignment" => %PropSpec{key: "alignment", cast: :align},
    "LineSpacing" => %PropSpec{key: "lineSpacing", cast: :int},
    "IndentLeft" => %PropSpec{key: "marginLeft", cast: :int},
    "IndentRight" => %PropSpec{key: "marginRight", cast: :int},
    "IndentFirst" => %PropSpec{key: "indent", cast: :int},
    "SpaceBefore" => %PropSpec{key: "spacingBefore", cast: :int},
    "SpaceAfter" => %PropSpec{key: "spacingAfter", cast: :int}
  }

  @picture_prop_spec %{
    "Width" => %PropSpec{key: "width", cast: :int},
    "Height" => %PropSpec{key: "height", cast: :int},
    "PosX" => %PropSpec{key: "horzOffset", cast: :int},
    "PosY" => %PropSpec{key: "vertOffset", cast: :int},
    "TreatAsChar" => %PropSpec{key: "treatAsChar", cast: :bool},
    "Caption" => %PropSpec{key: "caption", cast: :verbatim},
    "width" => %PropSpec{key: "width", cast: :int},
    "height" => %PropSpec{key: "height", cast: :int},
    "x" => %PropSpec{key: "horzOffset", cast: :int},
    "y" => %PropSpec{key: "vertOffset", cast: :int},
    "horzOffset" => %PropSpec{key: "horzOffset", cast: :int},
    "vertOffset" => %PropSpec{key: "vertOffset", cast: :int},
    "treatAsChar" => %PropSpec{key: "treatAsChar", cast: :bool}
  }

  def set(%{ehwp: ehwp_handle}, ref, props) when is_map(props) do
    {kind, prop_map} = pop_kind(props)
    resolved = kind || ref_kind(ref)

    cond do
      resolved == "char" ->
        # Agents mix PARAGRAPH props (Alignment) into a char set ({Bold, CharHeight,
        # Alignment}) — alignment is a paragraph property, so route each prop to the
        # right setter instead of dropping the misfiled ones (this is how
        # "center the bold title" silently stayed left-aligned).
        {para_props, char_props} = split_para_char(prop_map)

        char_result =
          if char_props != %{} do
            char_format_op(ehwp_handle, ref, char_props) |> apply_one(ehwp_handle)
          else
            {:ok, %{op: "noop", native: []}}
          end

        para_result =
          if para_props != %{} do
            para_format_op(ref, para_props) |> apply_one(ehwp_handle)
          else
            {:ok, %{op: "noop", native: []}}
          end

        merge_set_results(char_result, para_result)

      true ->
        %Ehwp.Op.SetProperties{
          at: Ehwp.Op.Ref.new(flatten_ref(ref)),
          kind: resolved,
          props: translate_props_for_kind(resolved, prop_map)
        }
        |> apply_one(ehwp_handle)
    end
  end

  # set_properties kinds: paragraph and picture accept agent-facing aliases; the
  # remaining control kinds pass native engine keys through.
  defp translate_props_for_kind("paragraph", props), do: translate(props, @para_prop_spec)
  defp translate_props_for_kind("picture", props), do: translate_picture_props(props)
  defp translate_props_for_kind(_kind, props), do: props

  defp translate_picture_props(props) do
    translated = translate(props, @picture_prop_spec)

    if picture_move_props?(props) do
      translated
      |> Map.put_new("treatAsChar", false)
      |> Map.put_new("horzRelTo", "Paper")
      |> Map.put_new("vertRelTo", "Paper")
      |> Map.put_new("horzAlign", "Left")
      |> Map.put_new("vertAlign", "Top")
    else
      translated
    end
  end

  defp picture_move_props?(props) do
    Enum.any?(Map.keys(props), &(to_string(&1) in ~w(PosX PosY x y horzOffset vertOffset)))
  end

  # The ONE eval of a translation spec: map each property through its
  # `%PropSpec{}`, casting the value by its declared type. A key absent from the
  # spec passes through verbatim (already an engine key, or unknown).
  defp translate(props, spec) when is_map(props) do
    Map.new(props, fn {k, v} ->
      case Map.get(spec, to_string(k)) do
        %PropSpec{key: key, cast: cast} -> {key, cast(cast, v)}
        nil -> {to_string(k), v}
      end
    end)
  end

  defp cast(:bool, v), do: truthy(v)
  defp cast(:weight_threshold, v), do: to_number(v) >= 150
  defp cast(:font_weight, v), do: v == "bold" or to_number(v) >= 600
  defp cast(:positive, v), do: to_number(v) > 0
  defp cast(:verbatim, v), do: v
  defp cast(:font_size, v), do: font_size_hu(v)
  defp cast(:int, v), do: round(to_number(v))
  defp cast(:align, v), do: downcase_align(v)

  # Paragraph-scoped property keys an agent might mix into a char set. Split them
  # out so a `doc.set {Bold, Alignment}` applies BOTH (char + paragraph).
  @para_prop_keys ~w(Alignment alignment LineSpacing IndentLeft IndentRight
                     IndentFirst SpaceBefore SpaceAfter)
  defp split_para_char(props) do
    Enum.split_with(props, fn {k, _v} -> to_string(k) in @para_prop_keys end)
    |> then(fn {para, char} -> {Map.new(para), Map.new(char)} end)
  end

  defp para_format_op(ref, prop_map) do
    %Ehwp.Op.SetProperties{
      at: Ehwp.Op.Ref.new(flatten_ref(ref)),
      kind: "paragraph",
      props: translate(prop_map, @para_prop_spec)
    }
  end

  defp merge_set_results({:error, _} = e, _), do: e
  defp merge_set_results(_, {:error, _} = e), do: e

  defp merge_set_results({:ok, a}, {:ok, b}),
    do: {:ok, %{op: "set", native: List.wrap(a[:native]) ++ List.wrap(b[:native])}}

  # Alignment value normalized to the engine's lowercase tokens.
  defp downcase_align(v) do
    case v |> to_string() |> String.downcase() do
      a when a in ~w(left right center justify distribute) -> a
      _ -> "justify"
    end
  end

  # Build the `apply_char_format` op for a char/cell-char ref. `at` is the
  # flattened start position; `to` is a nested Ref at the run END (same
  # paragraph/cell, offset = start + len). A paragraph-level find ref (e.g.
  # "make the title bold") carries NO length, which would yield a zero-length
  # range that formats NOTHING (this is how "make it bold" silently no-op'd) —
  # so when the ref has no span, default to the WHOLE paragraph (offset 0 → its
  # text length, resolved live from the doc).
  defp char_format_op(handle, ref, prop_map) do
    at = flatten_ref(ref)
    len = ref_run_len(ref)

    to =
      if len > 0 do
        Map.update(at, :offset, len, &(&1 + len))
      else
        whole_paragraph_end(handle, at)
      end

    %Ehwp.Op.ApplyCharFormat{
      at: Ehwp.Op.Ref.new(at),
      to: Ehwp.Op.Ref.new(to),
      props: translate(prop_map, @char_prop_spec)
    }
  end

  # The end position of `at`'s paragraph: same section/paragraph (+ cell address,
  # if any), offset = that paragraph's text length. Used to expand a span-less
  # char-format ref into a whole-paragraph range.
  defp whole_paragraph_end(handle, at) do
    sec = at[:section] || 0
    para = at[:paragraph] || 0
    {_s, _p, len} = end_position(handle, body_ref(sec, para, 0))
    Map.put(at, :offset, len)
  end

  # The engine's `fontSize` is in 1/100 pt (10pt = 1000). Agents say "36" meaning
  # 36 POINTS — passing 36 verbatim renders a 0.36pt (invisible) glyph (observed:
  # a 36pt certificate title vanishing). Treat a point-scale value (≤ 200) as
  # points → ×100; a value already in 1/100 pt (> 200) passes through.
  defp font_size_hu(v) do
    n = to_number(v)

    cond do
      n <= 0 -> 1000
      n <= 200 -> round(n * 100)
      true -> round(n)
    end
  end

  defp truthy(true), do: true
  defp truthy(false), do: false
  defp truthy(v) when is_number(v), do: v > 0
  defp truthy("true"), do: true
  defp truthy("false"), do: false
  defp truthy(v) when is_binary(v), do: v != ""
  defp truthy(nil), do: false
  defp truthy(_), do: true

  defp to_number(v) when is_number(v), do: v

  defp to_number(v) when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_number(_), do: 0

  # The run length encoded in a find ref (e.g. `hwp:s0/p0/c0+5` -> 5); 0 when the
  # ref does not encode a span.
  defp ref_run_len(ref) when is_binary(ref) do
    case Ref.decode(ref) do
      {:ok, %{len: len}} when is_integer(len) -> len
      _ -> 0
    end
  end

  defp ref_run_len(%{} = ref) do
    case Map.get(ref, :len, Map.get(ref, "len")) do
      len when is_integer(len) -> len
      _ -> 0
    end
  end

  defp ref_run_len(_ref), do: 0

  @impl true
  # IR-direct: the normalized op IS the engine op. Flatten its `ref` into the
  # `apply_op` shape (section/paragraph/offset/control?/cell?/cell_para? at the
  # top level, the rest of the verb fields verbatim) and hand the batch straight
  # to the NIF. No per-verb translation/wrapper.
  def edit(%{ehwp: ehwp_handle}, op) do
    with {:ok, op} <- Op.normalize(op),
         {:ok, op} <- resolve_authoring_refs(ehwp_handle, op) do
      apply_resolved(ehwp_handle, op)
    end
  end

  # `insert_picture` → the TYPED engine op. The ref is already resolved (above), so
  # flatten it into the `at` and let `Image.resolve_src/2` produce the
  # `%Ehwp.Op.InsertPicture{}` + raw `bins`. A picture with neither src nor bins
  # falls back to the generic path (the engine reports the missing source).
  defp apply_resolved(handle, %{op: "insert_picture"} = op) do
    at = Ehwp.Op.Ref.new(flatten_ref(op[:ref]))

    case Image.resolve_src(op, at) do
      {:ok, %Ehwp.Op.InsertPicture{} = pic, bins} ->
        apply_struct(handle, "insert_picture", pic, bins)

      {:ok, op} ->
        apply_generic(handle, op)

      {:error, _} = error ->
        error
    end
  end

  defp apply_resolved(handle, op) do
    if op.op == "insert_table" and is_list(op[:cells]) and op[:cells] != [] do
      insert_table_with_cells(handle, op)
    else
      apply_generic(handle, op)
    end
  end

  # Generic IR-direct path: flatten the ref, pull the out-of-band bins, hand the
  # batch to the NIF verbatim.
  defp apply_generic(handle, op) do
    {bins, op} = pop_bins(op)
    finish(op.op, Ehwp.apply_op(handle, expand_ops(op), bins))
  end

  # A single already-typed engine op (e.g. `%Ehwp.Op.InsertPicture{}`) + its bins.
  defp apply_struct(handle, verb, struct, bins),
    do: finish(verb, Ehwp.apply_op(handle, [struct], bins))

  defp finish(verb, {:ok, results}), do: {:ok, %{op: verb, native: decode_write(results)}}

  defp finish(_verb, {:error, {index, kind, msg}}),
    do: {:error, %{op_index: index, kind: to_string(kind), message: to_string(msg)}}

  defp finish(_verb, {:error, reason}), do: {:error, reason}

  # `insert_table {ref, rows, cols, cells: [[..row..], ..]}` — create the table
  # AND fill its cells in ONE op. Per-cell ref juggling (doc.find every cell →
  # set_cell each) is where weak models corrupt the doc (the table data ends up
  # prepended to the title because a mis-formatted cell ref silently defaults to
  # para-0/offset-0). Filling cells server-side from the freshly-created table's
  # own control index is deterministic: cellIndex is row-major (r*cols + c).
  defp insert_table_with_cells(handle, op) do
    cells = coerce_cells(op[:cells])
    rows = op[:rows] || length(cells)
    cols = op[:cols] || cells |> Enum.map(&safe_len/1) |> Enum.max(fn -> 0 end)
    at = flatten_ref(op[:ref])
    section = at[:section] || 0

    # (#46) The engine fills cells ATOMICALLY at create time — `cells` rides on
    # the InsertTable op, so there's no second round-trip + no row-major
    # `r*cols + c` index math in Elixir (that lives in the Rust op handler now).
    # Header SHADING stays app-side (presentation): style row 0 after the fill.
    table_op =
      op
      |> Map.drop([:data])
      |> Map.put(:rows, rows)
      |> Map.put(:cols, cols)
      |> Map.put(:cells, cells)

    {bins, table_op} = pop_bins(table_op)

    case Ehwp.apply_op(handle, expand_ops(table_op), bins) do
      {:ok, results} ->
        case decode_write(results) do
          [%{"controlIdx" => ctrl, "paraIdx" => ppara} = meta | _] ->
            _ = maybe_style_header(handle, op, section, ppara, ctrl, cols, cells)

            {:ok,
             %{
               op: "insert_table",
               native: decode_write(results),
               rows_after: rows,
               cols_after: cols,
               cells_filled: meta["cellsFilled"] || 0,
               header_styled: header?(op)
             }}

          decoded ->
            # Table created but no control index came back — return what we have
            # rather than silently dropping the cell data.
            {:ok, %{op: "insert_table", native: decoded, cells_filled: 0}}
        end

      {:error, {index, kind, msg}} ->
        {:error, %{op_index: index, kind: to_string(kind), message: to_string(msg)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_len(l) when is_list(l), do: length(l)
  defp safe_len(_), do: 0

  # The engine's InsertTable `cells` is a row-major `[[String]]` (serde
  # `Vec<Vec<String>>`); coerce each entry to a string so a numeric/nil cell from
  # a weak model doesn't trip serde (`bad_ops_json`). A non-list row becomes a
  # single-cell row.
  defp coerce_cells(cells) when is_list(cells) do
    Enum.map(cells, fn
      row when is_list(row) -> Enum.map(row, &to_string/1)
      other -> [to_string(other)]
    end)
  end

  defp coerce_cells(_), do: []

  defp header?(op), do: op[:header] == true or is_binary(op[:header_color])

  # `insert_table {..., header: true}` styles the first row like a real document
  # header: a light-gray fill + bold + centered text. The cell control/index are
  # known (row 0 = cells 0..cols-1), so this is deterministic — no doc.find.
  defp maybe_style_header(handle, op, section, ppara, ctrl, cols, _cells) do
    if header?(op) do
      color = op[:header_color] || "#e8e8e8"

      # Shade row 0 with a light-gray fill — the primary real-document header cue.
      # (Header-text bold is intentionally omitted: a char-format applied to a cell
      # in the SAME session right after set_cell_text does not commit until a
      # save/reopen, so it would silently no-op; the shading alone reads as a
      # header.)
      fill_ops =
        for c <- 0..(cols - 1) do
          %{
            op: "set_properties",
            kind: "cell",
            section: section,
            paragraph: ppara,
            control: ctrl,
            cell: c,
            props: %{"fillColor" => color}
          }
        end

      Ehwp.apply_op(handle, fill_ops, [])
    else
      :ok
    end
  end

  # Authoring refs need the LIVE doc to resolve, so do it here (handle in scope),
  # not in the handle-less flatten_ref:
  #
  #   * `ref: "end"` — the server's flatten_ref can't turn "end" into the last
  #     paragraph, so it silently fell back to section-0/paragraph-0. A
  #     from-scratch authoring loop (`insert_paragraph end` per line) therefore
  #     stacked every paragraph at the TOP, in reverse.
  #   * `insert_paragraph {text: ...}` — the engine's `insert_paragraph` IGNORES
  #     the text arg (it only makes the break), so the text vanished while the op
  #     still replied `ok:true`. The agent then flailed (the mangled
  #     "____근로계약서" title, duplicated footnotes).
  #
  # Resolve both into the working `insert_text` primitive (which build_multi_para
  # already expands): append the text as a NEW paragraph at the document end —
  # filling the trailing empty paragraph in place, or splitting after a non-empty
  # one.
  defp resolve_authoring_refs(handle, %{op: "insert_paragraph"} = op) do
    text = Map.get(op, :text)

    if is_binary(text) and text != "" do
      {sec, para, len} = end_position(handle, Map.get(op, :ref))

      {off, text} = if len == 0, do: {0, text}, else: {len, "\n" <> text}

      {:ok,
       op
       |> Map.put(:op, "insert_text")
       |> Map.put(:ref, body_ref(sec, para, off))
       |> Map.put(:text, text)
       |> Map.delete(:count)}
    else
      {:ok, resolve_end_ref(handle, op)}
    end
  end

  # Every OTHER op (insert_text/insert_shape/insert_picture/insert_table/
  # insert_footnote/…) that targets `ref:"end"` also needs it resolved to the
  # document end — otherwise the handle-less flatten_ref defaults to para-0/off-0
  # and the object anchors at the TITLE (observed: shapes rendering by the title
  # instead of below the body).
  defp resolve_authoring_refs(handle, op), do: {:ok, resolve_end_ref(handle, op)}

  # Rewrite a bare `ref: "end"` (or missing ref) to the concrete last-body-para
  # position so an `insert_text end` appends instead of hitting para 0.
  defp resolve_end_ref(handle, op) do
    case Map.get(op, :ref) do
      ref when ref in ["end", "END", nil, ""] ->
        {sec, para, len} = end_position(handle, "end")
        Map.put(op, :ref, body_ref(sec, para, len))

      _ ->
        op
    end
  end

  # The JSON body ref doc.find emits — `{"section","paragraph","offset"}`. The
  # `hwp:` PositionalIndex char form is `cOFF+LEN`; the JSON form is unambiguous
  # for a zero-length caret, so use it for synthesized authoring positions.
  defp body_ref(sec, para, off),
    do: ~s({"section":#{sec},"paragraph":#{para},"offset":#{off}})

  # {section, paragraph, text_length} for a ref. "end"/nil → the LAST body
  # paragraph; a concrete ref → that paragraph. Length comes from the Elements
  # enumeration (the same surface doc.find reads), filtering out footnote/cell
  # sub-paragraphs (control/cell present).
  defp end_position(handle, ref) do
    body_paras =
      case Ehwp.query(handle, %{q: "elements"}) do
        {:ok, json} ->
          json
          |> Jason.decode!()
          |> Enum.filter(fn e ->
            e["type"] == "paragraph" and is_map(e["ref"]) and
              is_nil(e["ref"]["control"]) and is_nil(e["ref"]["cell"])
          end)

        _ ->
          []
      end

    target =
      case decode_concrete_ref(ref) do
        {s, p} ->
          Enum.find(body_paras, fn e ->
            e["ref"]["section"] == s and e["ref"]["paragraph"] == p
          end)

        :end ->
          Enum.max_by(
            body_paras,
            fn e -> {e["ref"]["section"] || 0, e["ref"]["paragraph"] || 0} end,
            fn -> nil end
          )
      end

    case target do
      nil -> {0, 0, 0}
      e -> {e["ref"]["section"] || 0, e["ref"]["paragraph"] || 0, String.length(e["text"] || "")}
    end
  end

  defp decode_concrete_ref(ref) when ref in ["end", "END", nil, ""], do: :end

  defp decode_concrete_ref(ref) when is_binary(ref) do
    case Ref.decode(ref) do
      {:ok, %{kind: :char, sec: s, para: p}} -> {s, p}
      {:ok, %{kind: :paragraph, sec: s, para: p}} -> {s, p}
      _ -> :end
    end
  end

  defp decode_concrete_ref(_), do: :end

  @doc """
  Rasterize one page to a PNG at `path` — the HWP arm of the doc.render visual
  feedback loop. `page` is the 1-BASED page number as a string ("1", "2", …;
  HWP pages are unnamed, unlike Impress slides). The engine rasterizes the page
  in-process at `width` px (`render_page_png`, native Skia, ~35ms/page); the
  legacy SVG + `rsvg-convert` pipeline (~196ms/page) remains only as a fallback.
  """
  @spec render_page(handle(), String.t() | integer(), String.t(), pos_integer()) ::
          :ok | {:error, term()}
  def render_page(%{ehwp: ehwp_handle}, page, path, width) do
    case Integer.parse(to_string(page)) do
      {idx, ""} when idx >= 1 ->
        case Ehwp.render_page_png(ehwp_handle, idx - 1, width) do
          {:ok, png, _meta} ->
            File.write(path, png)

          {:error, {:page_out_of_range, _}} = error ->
            error

          {:error, _reason} ->
            render_page_via_rsvg(ehwp_handle, idx - 1, path, width)
        end

      _other ->
        {:error,
         {:invalid_params,
          "HWP page must be a 1-based page NUMBER string (\"1\", \"2\", …), got: #{inspect(page)}"}}
    end
  end

  # Fallback rasterizer: engine SVG piped through the external `rsvg-convert`
  # binary. Only reached when the in-process Skia raster fails on a page.
  defp render_page_via_rsvg(ehwp_handle, page_index, path, width) do
    with {:ok, svg, _meta} <- Ehwp.render_page_svg(ehwp_handle, page_index),
         svg_path = path <> ".svg",
         :ok <- File.write(svg_path, svg) do
      try do
        case System.cmd("rsvg-convert", ["-w", to_string(width), "-o", path, svg_path],
               stderr_to_stdout: true
             ) do
          {_out, 0} -> :ok
          {out, code} -> {:error, {:render_failed, "rsvg-convert exit #{code}: #{out}"}}
        end
      rescue
        # rsvg-convert not installed on this machine.
        e in ErlangError -> {:error, {:render_failed, inspect(e.original)}}
      after
        File.rm(svg_path)
      end
    end
  end

  # Export the in-memory model to bytes, no disk write. The Editor's twin-sync
  # surface (`Editor.export_bytes/2`) uses this so a dirty SERVER copy can hand
  # its bytes to a newly-attaching browser viewer (`RhwpAdapter` reverse-sync).
  def export_bytes(%{ehwp: ehwp_handle}, format) when format in [:hwp, :hwpx] do
    Ehwp.export(ehwp_handle, format)
  end

  def export_bytes(_handle, format), do: {:error, {:bad_format, format}}

  @impl true
  # IR-direct: export the (incrementally re-serialized) bytes via the ehwp NIF and
  # write them to disk. `format`/`path` come from the Tools layer (which knows the
  # doc kind + path). Without a path we just return the byte count (caller writes).
  def save(%{ehwp: ehwp_handle}, opts) do
    format = Keyword.get(opts, :format, :hwp)
    path = Keyword.get(opts, :path)

    with {:ok, bytes} <- Ehwp.export(ehwp_handle, format) do
      if is_binary(path) do
        case File.write(path, bytes) do
          :ok -> {:ok, %{"path" => path, "bytes" => byte_size(bytes)}}
          {:error, reason} -> {:error, %{kind: "write_failed", message: inspect(reason)}}
        end
      else
        {:ok, %{"bytes" => byte_size(bytes)}}
      end
    end
  end

  # --- edit op -> IR (apply_op) shape --------------------------------------

  # The normalized op carries verb fields (query/replacement/text/count/row/col/
  # props/...) plus a `ref`. The engine `apply_op` wants the ref's positional
  # keys FLATTENED onto the op (serde `#[serde(flatten)]`), so spread them to the
  # top level and keep the rest of the fields verbatim. Atom keys throughout —
  # `Ehwp.apply_op` Jason-encodes them to the JSON the NIF expects.
  defp to_ir_op(op) do
    verb = op.op
    {ref, rest} = op |> Map.delete(:op) |> Map.pop(:ref)

    rest
    |> Map.put(:op, verb)
    |> Map.merge(flatten_ref(ref))
  end

  # Map a normalized op to the engine IR op list. Two verbs are rewritten here:
  # `set_cell` -> the engine `set_cell_text` op (whole-cell replace, format
  # preserved), and a multi-paragraph body `insert_text` -> an insert+split
  # primitive sequence. Everything else passes through 1:1 — including the creator
  # verbs (insert_equation/insert_footnote/insert_endnote/insert_shape/set_columns),
  # whose verb fields (script/font_size/color, shape_type/width/height/x/y,
  # count/column_type/same_width/spacing) are carried verbatim onto the flattened
  # IR op so the ehwp EditOp #[serde(flatten)] variant deserializes them directly.
  defp expand_ops(op) do
    ir = to_ir_op(op)
    text = ir[:text]

    cond do
      # `set_cell` REPLACES a whole table cell's content: translate to the engine's
      # `set_cell_text` op, splitting `text` on `\n` into one cell paragraph per
      # line. Each new paragraph inherits the cell's existing ParaShape/CharShape
      # (the engine clones the first paragraph's format), so the `EN ¶ 해석`
      # two-paragraph shape + fonts are preserved. The cell address (control/cell)
      # comes from the flattened cell ref. ONE op, no per-cell_para surgery.
      ir[:op] == "set_cell" ->
        lines = String.split(text || "", "\n")
        [%Ehwp.Op.SetCellText{at: Ehwp.Op.Ref.new(ir), lines: lines}]

      # An `insert_text` whose text contains `\n` is authoring MULTIPLE paragraphs.
      # The engine treats `\n` as a literal char (no paragraph break) and
      # `insert_paragraph` ignores text, so expand it into the real primitive
      # sequence (body refs only — a cell ref keeps the single literal insert).
      ir[:op] == "insert_text" and is_binary(text) and String.contains?(text, "\n") and
          is_nil(ir[:control]) ->
        sec = ir[:section] || 0
        para = ir[:paragraph] || 0
        off = ir[:offset] || 0
        build_multi_para(sec, para, off, String.split(text, "\n"))

      # Multi-column with NO inter-column gap renders the two columns nearly
      # touching (text runs together, unreadable). Default a real-document
      # gutter (~12mm = 3402 HWPUNIT) when the agent doesn't specify spacing.
      ir[:op] == "set_columns" and (is_nil(ir[:spacing]) or ir[:spacing] == 0) ->
        [Map.put(ir, :spacing, 3402)]

      true ->
        [ir]
    end
  end

  defp build_multi_para(sec, para0, off0, [first | rest]) do
    first_ops =
      if first == "",
        do: [],
        else: [
          %Ehwp.Op.InsertText{
            at: %Ehwp.Op.Ref{section: sec, paragraph: para0, offset: off0},
            text: first
          }
        ]

    {ops, _acc} =
      Enum.reduce(rest, {first_ops, {para0, off0 + String.length(first)}}, fn line,
                                                                              {acc, {p, end_off}} ->
        split = %Ehwp.Op.Split{at: %Ehwp.Op.Ref{section: sec, paragraph: p, offset: end_off}}
        next_p = p + 1

        ins =
          if line == "",
            do: [],
            else: [
              %Ehwp.Op.InsertText{
                at: %Ehwp.Op.Ref{section: sec, paragraph: next_p, offset: 0},
                text: line
              }
            ]

        {acc ++ [split] ++ ins, {next_p, String.length(line)}}
      end)

    ops
  end

  defp flatten_ref(ref) when is_binary(ref) do
    # doc.find returns the canonical `hwp:s0/p6/c12+5` PositionalIndex for server
    # docs; decode it to section/paragraph/offset so a ref'd edit hits the RIGHT
    # paragraph (not the section-0/para-0 default). The browser backend uses a
    # JSON `{section,paragraph,offset,...}` ref — accept that too.
    ref = String.trim(ref)

    if String.starts_with?(ref, "{") do
      case Jason.decode(ref) do
        {:ok, %{} = m} -> flatten_ref(m)
        _ -> %{}
      end
    else
      case Ref.decode(ref) do
        {:ok, %{kind: :cell_char, sec: s, para: p, control: ct, cell: ce, cell_para: cp, off: o}} ->
          %{section: s, paragraph: p, control: ct, cell: ce, cell_para: cp, offset: o}

        {:ok, %{kind: :char, sec: s, para: p, off: o}} ->
          %{section: s, paragraph: p, offset: o}

        # A non-cell IR control ref from the element enumerator: flatten its
        # verbatim parsed object (section/paragraph/control + any subParagraph/
        # cellPath) so a follow-up edit/get hits exactly that control.
        {:ok, %{kind: :control, fields: fields}} when is_map(fields) ->
          flatten_ref(fields)

        {:ok, %{kind: :paragraph, sec: s, para: p}} ->
          %{section: s, paragraph: p}

        {:ok, %{kind: :section, sec: s}} ->
          %{section: s}

        {:ok, %{kind: :document}} ->
          %{}

        _ ->
          %{}
      end
    end
  end

  defp flatten_ref(%{} = ref) do
    # The element enumerator / browser cell ref nests the cell address as a MAP
    # (`cell: {parentParaIndex, controlIndex, cellIndex, cellParaIndex}`), but the
    # engine ops want FLAT usizes (control/cell/cell_para + the table-holding
    # paragraph). Unnest it first; otherwise a cell-targeted edit (set_cell/
    # replace_text/…) passes a map where a usize is expected
    # (`bad_ops_json: invalid type: map, expected usize`) or loses the control index.
    ref = unnest_cell(ref)

    base =
      Enum.reduce(
        [:section, :paragraph, :offset, :length, :control, :cell, :cell_para],
        %{},
        fn k, acc ->
          case Map.get(ref, k, Map.get(ref, Atom.to_string(k))) do
            nil -> acc
            v -> Map.put(acc, k, v)
          end
        end
      )

    # The element enumerator also emits container/nested addressing keys
    # (`subParagraph`/`subControl` for header/footer/footnote nested controls,
    # `containerType` to distinguish footnote/endnote setters, `cellPath` for
    # controls/cells nested inside cells or textboxes). Pass them through so an
    # edit/get targets the nested element; absent keys are simply omitted.
    base
    |> put_if_present(:sub_paragraph, ref, "subParagraph")
    |> put_if_present(:sub_control, ref, "subControl")
    |> put_if_present(:container_type, ref, "containerType")
    |> put_if_present(:cell_path, ref, "cellPath")
    |> put_if_present(:style_id, ref, "styleId")
    |> put_if_present(:numbering_id, ref, "numberingId")
    |> put_if_present(:bullet_id, ref, "bulletId")
  end

  defp flatten_ref(_ref), do: %{}

  # Flatten a nested `cell` map ({parentParaIndex, controlIndex, cellIndex,
  # cellParaIndex}) into the flat usize keys the engine ops expect. A flat ref
  # (cell already a usize, or no cell) passes through unchanged.
  defp unnest_cell(%{} = ref) do
    case Map.get(ref, :cell, Map.get(ref, "cell")) do
      %{} = cell ->
        g = fn k -> Map.get(cell, k, Map.get(cell, Atom.to_string(k))) end

        ref
        |> Map.drop([:cell, "cell", :control, "control", :cell_para, "cell_para"])
        |> maybe_put_flat("control", g.(:controlIndex))
        |> maybe_put_flat("cell", g.(:cellIndex))
        |> maybe_put_flat("cell_para", g.(:cellParaIndex))
        |> maybe_put_flat("paragraph", g.(:parentParaIndex))

      _ ->
        ref
    end
  end

  defp maybe_put_flat(map, _k, nil), do: map
  defp maybe_put_flat(map, k, v), do: Map.put(map, k, v)

  # Copy `src_key` (camelCase JSON or its atom form) from `ref` into `acc` under
  # `dest_key` when present.
  defp put_if_present(acc, dest_key, ref, src_key) do
    case Map.get(ref, src_key, Map.get(ref, String.to_atom(src_key))) do
      nil -> acc
      v -> Map.put(acc, dest_key, v)
    end
  end

  # `insert_picture` carries image bytes as base64 in `:bins`; pull them into the
  # binary list `apply_op` takes (the op references them by `bin_index`).
  defp pop_bins(op) do
    case Map.pop(op, :bins) do
      {bins, rest} when is_list(bins) -> {Enum.map(bins, &decode_bin/1), rest}
      {_nil, rest} -> {[], rest}
    end
  end

  defp decode_bin(b) when is_binary(b) do
    case Base.decode64(b) do
      {:ok, bytes} -> bytes
      :error -> b
    end
  end

  defp decode_bin(b), do: b

  # Apply ONE already-built IR op (atom-keyed, ref pre-flattened) via the NIF.
  # The op verb, whether `op` is a typed `Ehwp.Op.*` struct (tag via op_tag/0) or
  # a legacy map (the `:op` key). Used only for the informational echo in results.
  defp op_verb(%{__struct__: mod}), do: mod.op_tag()
  defp op_verb(op) when is_map(op), do: op[:op]

  defp apply_one(op, ehwp_handle) do
    case Ehwp.apply_op(ehwp_handle, [op], []) do
      {:ok, results} ->
        {:ok, %{op: op_verb(op), native: decode_write(results)}}

      {:error, {index, kind, msg}} ->
        {:error, %{op_index: index, kind: to_string(kind), message: to_string(msg)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Pull a `kind` discriminator out of the props map (string or atom key).
  defp pop_kind(props) do
    {kind, rest} = Map.pop(props, "kind")
    {kind || Map.get(props, :kind), Map.delete(rest, :kind)}
  end

  defp query_error(reason), do: reason

  # The property `kind` the NIF needs to route get/set_properties: derive it from
  # the ref's element type (char run vs paragraph). Control-scoped kinds
  # (picture/shape/table/cell) require control refs the current Ref grammar does
  # not encode yet — the caller can override by embedding `kind` in the props.
  defp ref_kind(ref) when is_binary(ref) do
    case Ref.decode(ref) do
      {:ok, %{kind: :paragraph}} -> "paragraph"
      {:ok, %{kind: :cell_char}} -> "cell"
      # A non-cell IR control ref (picture/shape/table/…): the property kind is
      # the control's own type, so get/set_properties route to the right native
      # handler. Falls back to "char" when the enumerator gave no type.
      {:ok, %{kind: :control, type: type}} when is_binary(type) -> type
      _ -> "char"
    end
  end

  defp ref_kind(%{"type" => type}) when is_binary(type) and type != "", do: type
  defp ref_kind(%{type: type}) when is_binary(type) and type != "", do: type
  defp ref_kind(%{"styleId" => _style_id}), do: "style_def"
  defp ref_kind(%{styleId: _style_id}), do: "style_def"
  defp ref_kind(%{style_id: _style_id}), do: "style_def"
  defp ref_kind(%{"numberingId" => _numbering_id}), do: "numbering_def"
  defp ref_kind(%{numberingId: _numbering_id}), do: "numbering_def"
  defp ref_kind(%{numbering_id: _numbering_id}), do: "numbering_def"
  defp ref_kind(%{"bulletId" => _bullet_id}), do: "bullet_def"
  defp ref_kind(%{bulletId: _bullet_id}), do: "bullet_def"
  defp ref_kind(%{bullet_id: _bullet_id}), do: "bullet_def"
  defp ref_kind(%{"cell" => _cell}), do: "cell"
  defp ref_kind(%{cell: _cell}), do: "cell"
  defp ref_kind(_ref), do: "char"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present_list(list) when is_list(list) and list != [], do: list
  defp present_list(_other), do: nil

  # --- helpers -------------------------------------------------------------

  defp read_text(ehwp_handle) do
    case Ehwp.read(ehwp_handle, []) do
      {:ok, result} -> {:ok, normalize_text(result)}
      {:error, _reason} = error -> error
    end
  end

  defp scope_ref(nil), do: {:ok, %{kind: :document}}

  defp scope_ref(ref) when is_binary(ref) do
    case Ref.decode(ref) do
      {:ok, %{kind: kind} = decoded} when kind in [:document, :section, :paragraph] ->
        {:ok, decoded}

      {:ok, _other} ->
        {:error, {:invalid_ref, ref}}

      {:error, _reason} = error ->
        error
    end
  end

  defp scope_ref(_ref), do: {:error, :invalid_ref}

  defp build_outline(text, sec, scope) do
    paragraphs = split_paragraphs(text)

    children =
      paragraphs
      |> Enum.with_index()
      |> Enum.filter(fn {_para, idx} -> in_scope?(scope, sec, idx) end)
      |> Enum.map(fn {para_text, idx} ->
        %{
          ref: Ref.encode(%{kind: :paragraph, sec: sec, para: idx}),
          type: "paragraph",
          text: preview(para_text)
        }
      end)

    %{
      ref: Ref.encode(scope_to_node(scope, sec)),
      type: outline_type(scope),
      children: children
    }
  end

  defp scope_to_node(%{kind: :paragraph} = scope, _sec), do: scope
  defp scope_to_node(%{kind: :section, sec: sec}, _), do: %{kind: :section, sec: sec}
  defp scope_to_node(_scope, _sec), do: %{kind: :document}

  defp outline_type(%{kind: :paragraph}), do: "paragraph"
  defp outline_type(%{kind: :section}), do: "section"
  defp outline_type(_scope), do: "document"

  defp in_scope?(%{kind: :document}, _sec, _idx), do: true
  defp in_scope?(%{kind: :section, sec: s}, sec, _idx), do: s == sec
  defp in_scope?(%{kind: :paragraph, sec: s, para: p}, sec, idx), do: s == sec and p == idx
  defp in_scope?(_scope, _sec, _idx), do: true

  defp split_paragraphs(text) do
    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.reject(&(&1 == ""))
  end

  defp preview(text, max \\ 80) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp match_to_ref(match, sec, pattern) when is_map(match) do
    para = match["para"] || match[:para] || 0
    off = match["off"] || match["charOffset"] || match[:off] || 0
    len = match["count"] || match["length"] || match[:count] || String.length(pattern)
    text = match["text"] || match[:text] || pattern

    # A match inside a table cell carries cellContext {parentPara,ctrlIdx,cellIdx,
    # cellPara}. Encode it as a cell-addressed ref so a follow-up edit routes to
    # the cell (the in-cell native op), not the body paragraph — otherwise tables
    # (signature blocks, amount tables) are unreachable for the agent.
    decoded =
      case match["cellContext"] || match[:cellContext] do
        %{} = cc ->
          %{
            kind: :cell_char,
            sec: sec,
            para: cc["parentPara"] || cc[:parentPara] || para,
            control: cc["ctrlIdx"] || cc[:ctrlIdx] || 0,
            cell: cc["cellIdx"] || cc[:cellIdx] || 0,
            cell_para: cc["cellPara"] || cc[:cellPara] || 0,
            off: off,
            len: len
          }

        _ ->
          %{kind: :char, sec: sec, para: para, off: off, len: len}
      end

    %{ref: Ref.encode(decoded), text: text, off: off, len: len}
  end

  defp decode_matches(matches) when is_list(matches), do: Enum.map(matches, &stringify/1)

  defp decode_matches(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      {:ok, %{"matches" => list}} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_matches(%{"matches" => list}) when is_list(list), do: list
  defp decode_matches(%{matches: list}) when is_list(list), do: Enum.map(list, &stringify/1)
  defp decode_matches(_other), do: []

  defp decode_write(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> map
      _ -> %{"raw" => json}
    end
  end

  defp decode_write(other), do: other

  defp stringify(%{} = map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp stringify(other), do: other

  defp normalize_text(text) when is_binary(text), do: text

  defp normalize_text(%{} = result) do
    cond do
      is_binary(result["text"]) -> result["text"]
      is_binary(result[:text]) -> result[:text]
      is_binary(result["content"]) -> result["content"]
      is_binary(result[:content]) -> result[:content]
      true -> ""
    end
  end

  defp normalize_text(_other), do: ""
end
