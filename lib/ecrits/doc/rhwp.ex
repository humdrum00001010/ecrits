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
  edit-only NIF surface — `get/set_*_properties`, `apply_style`, structural
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
      it mirrors the engine vocabulary (design §4.1).
    * `edit replace_text` -> `Ehwp.write(handle, {:replace_one, q, r})`

  Not yet (`{:not_supported}`): `get/3`, `set/4`, `apply_style/3`,
  `edit insert_text|delete_range|split|insert_node|delete_node|move_node|insert_picture`,
  `save/2`. These need the edit-only `ehwp` NIF revival (property
  getters/setters, `apply_style`, structural verbs, export); the **ref routing
  and the native-property vocabulary are already wired** here so they light up
  the moment those NIFs land.
  """

  @behaviour Ecrits.Doc

  alias Ecrits.Doc.Op
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
    type = element_type(kind)
    canonical_ref = if is_binary(ref), do: ref, else: Ref.encode(decoded)

    base = %{
      ref: canonical_ref,
      type: type,
      kind: Atom.to_string(kind),
      interfaces: interfaces_for(kind),
      properties: native_props(kind)
    }

    case kind do
      k when k in [:document, :section, :paragraph] ->
        case outline(handle, document_or_self(decoded), depth: 1) do
          {:ok, %{children: children}} -> Map.put(base, :children, child_summaries(children))
          _ -> Map.put(base, :children, [])
        end

      _ ->
        # leaf-ish element (char run, picture, shape, cell): no child enumeration
        _ = ehwp_handle
        Map.put(base, :children, [])
    end
  end

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
  # IR-direct property edit: apply_op set_properties at the ref. `kind`
  # (picture/shape/table/cell/paragraph) routes to the native setter; take it
  # from the props map if the caller embedded it, else let the engine infer.
  def set(%{ehwp: ehwp_handle}, ref, props, _base_rev) when is_map(props) do
    {kind, prop_map} = pop_kind(props)

    %{op: "set_properties", props: prop_map, kind: kind || ref_kind(ref)}
    |> Map.merge(flatten_ref(ref))
    |> apply_one(ehwp_handle)
  end

  @impl true
  # IR-direct: the normalized op IS the engine op. Flatten its `ref` into the
  # `apply_op` shape (section/paragraph/offset/control?/cell?/cell_para? at the
  # top level, the rest of the verb fields verbatim) and hand the batch straight
  # to the NIF. No per-verb translation/wrapper.
  def edit(%{ehwp: ehwp_handle}, op, _base_rev) do
    with {:ok, op} <- Op.normalize(op) do
      {bins, op} = pop_bins(op)

      case Ehwp.apply_op(ehwp_handle, expand_ops(op), bins) do
        {:ok, results} ->
          {:ok, %{op: op.op, native: decode_write(results)}}

        {:error, {index, kind, msg}} ->
          {:error, %{op_index: index, kind: to_string(kind), message: to_string(msg)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  # IR-direct: apply character formatting over the ref's run via apply_op
  # apply_char_format. `style` is a props map (Bold/FontSize/TextColor/...).
  def apply_style(%{ehwp: ehwp_handle}, ref, style) do
    props = if is_map(style), do: style, else: %{"style" => style}

    %{op: "apply_char_format", props: props, to: ref}
    |> Map.merge(flatten_ref(ref))
    |> apply_one(ehwp_handle)
  end

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

  # An `insert_text` whose text contains `\n` is authoring MULTIPLE paragraphs.
  # The engine treats `\n` as a literal char (no paragraph break) and
  # `insert_paragraph` ignores text, so expand it into the real primitive
  # sequence: insert line 0, then for each further line `split` the current
  # paragraph at its end (creating the next paragraph) and insert the line. The
  # whole batch applies atomically via one `apply_op`. Body refs only — a cell
  # ref (has :control) keeps the single literal insert.
  defp expand_ops(op) do
    ir = to_ir_op(op)
    text = ir[:text]

    if ir[:op] == "insert_text" and is_binary(text) and String.contains?(text, "\n") and
         is_nil(ir[:control]) do
      sec = ir[:section] || 0
      para = ir[:paragraph] || 0
      off = ir[:offset] || 0
      build_multi_para(sec, para, off, String.split(text, "\n"))
    else
      [ir]
    end
  end

  defp build_multi_para(sec, para0, off0, [first | rest]) do
    first_ops =
      if first == "",
        do: [],
        else: [%{op: "insert_text", section: sec, paragraph: para0, offset: off0, text: first}]

    {ops, _acc} =
      Enum.reduce(rest, {first_ops, {para0, off0 + String.length(first)}}, fn line,
                                                                              {acc, {p, end_off}} ->
        split = %{op: "split", section: sec, paragraph: p, offset: end_off}
        next_p = p + 1

        ins =
          if line == "",
            do: [],
            else: [%{op: "insert_text", section: sec, paragraph: next_p, offset: 0, text: line}]

        {acc ++ [split] ++ ins, {next_p, String.length(line)}}
      end)

    ops
  end

  defp flatten_ref(ref) when is_binary(ref) do
    # doc.find returns the canonical `hwp:s0/p6/c12+5` PositionalIndex for server
    # docs; decode it to section/paragraph/offset so a ref'd edit hits the RIGHT
    # paragraph (not the section-0/para-0 default). The browser backend uses a
    # JSON `{section,paragraph,offset,...}` ref — accept that too.
    case Ref.decode(ref) do
      {:ok, %{kind: :cell_char, sec: s, para: p, control: ct, cell: ce, cell_para: cp, off: o}} ->
        %{section: s, paragraph: p, control: ct, cell: ce, cell_para: cp, offset: o}

      {:ok, %{kind: :char, sec: s, para: p, off: o}} ->
        %{section: s, paragraph: p, offset: o}

      {:ok, %{kind: :paragraph, sec: s, para: p}} ->
        %{section: s, paragraph: p}

      {:ok, %{kind: :section, sec: s}} ->
        %{section: s}

      {:ok, %{kind: :document}} ->
        %{}

      _ ->
        case Jason.decode(ref) do
          {:ok, %{} = m} -> flatten_ref(m)
          _ -> %{}
        end
    end
  end

  defp flatten_ref(%{} = ref) do
    Enum.reduce([:section, :paragraph, :offset, :control, :cell, :cell_para], %{}, fn k, acc ->
      case Map.get(ref, k, Map.get(ref, Atom.to_string(k))) do
        nil -> acc
        v -> Map.put(acc, k, v)
      end
    end)
  end

  defp flatten_ref(_ref), do: %{}

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
  defp apply_one(op, ehwp_handle) do
    case Ehwp.apply_op(ehwp_handle, [op], []) do
      {:ok, results} ->
        {:ok, %{op: op[:op], native: decode_write(results)}}

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
      _ -> "char"
    end
  end

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
