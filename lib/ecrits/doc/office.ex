defmodule Ecrits.Doc.Office do
  @moduledoc """
  docx/pptx backend for `Ecrits.Doc`, served by the headless LibreOffice UNO NIF.

  This is the **Office server arm** of the design (§2.1, §3) — the docx/pptx
  analogue of `Ecrits.Doc.Rhwp`. It makes Word/PowerPoint documents answer the
  SAME reflective `doc.*` MCP surface as HWP, backed by the pure-UNO object-model
  bridge in `libreofficex` (`Libreofficex.LokBackend.Native.uno_*`). The office is
  booted in-process once (svp headless, no soffice subprocess, no `.uno` dispatch)
  and reached straight through `com::sun::star`.

  ## Refs are UNO-native and opaque

  Unlike the HWP backend (which encodes/decodes an `hwp:` positional grammar),
  the UNO walker issues its OWN ref strings and accepts them back verbatim:

      p<idx>                          body paragraph (Writer)
      p<idx>/r<ridx>                  run inside a paragraph
      tbl[<TableName>]/cell[<B2>]     table cell (UNO cell name)
      page[<SlideName>]/shape[<N>]    shape / text frame (Impress)

  So this backend passes refs through untouched; `Ecrits.Doc.Office.Ref` only
  *classifies* them (cell vs paragraph vs shape …) for routing and reflection.

  ## Callback → NIF mapping

    * `open/2`     -> `uno_open(install_dir, path, profile_url)`
    * `read/2`     -> `uno_elements` text, windowed (≤30 paragraphs/call, parity
      with the HWP read cap + `next_at` cursor)
    * `find/3`     -> `uno_elements`, filter nodes whose text contains the pattern
    * `outline/3`  -> `uno_elements`, top-level structural tree
    * `inspect/2`  -> reflective discovery (element type + native UNO property
      names + child refs), mirroring `XServiceInfo`/`XPropertySetInfo`
    * `get/3`      -> `uno_get(ref)` (decoded JSON props)
    * `set/4`      -> `uno_set(ref, props_json)` (UNIVERSAL property setter)
    * `edit/3`     -> op → `uno_apply(op_json)` (insert_text/replace_text/delete/
      replace_all)
    * `save/2`     -> `uno_save(path, filter)` (docx `"MS Word 2007 XML"`, pptx
      `"Impress MS PowerPoint 2007 XML"`)
    * `close/1`    -> `uno_close`

  Office is **server-only** in Phase 1 (no browser arm); the Pool routes it as
  `:server` exactly like a headless HWP doc.

  ## Install dir resolution (no hardcoded home)

  `uno_open` needs the LOK install dir (`…/LibreOffice.app/Contents/Frameworks`).
  We resolve it WITHOUT baking any developer path into source:

    1. `config :ecrits, Ecrits.Doc.Office, install_dir: …` (set in `runtime.exs`
       from the `LOK_INSTALL_DIR` env var — the SAME knob the NIF build reads);
    2. else the `LOK_INSTALL_DIR` env var directly;
    3. else discovery under `~/Desktop/core/instdir/…` via `System.user_home()`.

  When none resolves to a real `libsofficeapp.dylib`, `open/2` returns
  `{:error, {:office_unavailable, …}}` and Office docs stay unsupported.
  """

  @behaviour Ecrits.Doc

  alias Ecrits.Doc.Office.Instance
  alias Ecrits.Doc.Office.Ref
  alias Ecrits.Doc.Op
  alias Libreofficex.LokBackend.Native

  @typedoc """
  Engine handle: a STABLE token for the document plus its kind/path.

  Since Phase 3 the office NIF is owned by the single serializing
  `Ecrits.Doc.Office.Instance`; the backend no longer holds the raw UNO `session`
  resource (which the Instance may release + reopen under its LRU budget). The
  handle the Editor holds is the Instance's stable `doc` token — every op routes
  through `Instance.run/3`, which resolves the token to a live session, serialises
  the call, and transparently rematerialises an evicted doc first.
  """
  @type handle :: %{doc: reference(), kind: :docx | :pptx, path: String.t() | nil}

  # Export filter names the UNO arm needs for storeToURL (M2/M3 verified).
  @docx_filter "MS Word 2007 XML"
  @pptx_filter "Impress MS PowerPoint 2007 XML"

  # Parity with the HWP backend: a single doc.read never returns more than this
  # many paragraphs (design §4.4, the user's hard limit). Office has no native
  # windowing either, so it is enforced here in Elixir.
  @read_paragraph_cap 30

  @doc "The maximum number of paragraphs a single `read/2` (doc.read) may return."
  @spec read_paragraph_cap() :: pos_integer()
  def read_paragraph_cap, do: @read_paragraph_cap

  @impl true
  def kind, do: :office

  @impl true
  # Open a docx/pptx purely via UNO, THROUGH the single serializing governor
  # (`Ecrits.Doc.Office.Instance`). The governor boots/loads the UNO session,
  # applies its LRU budget, and returns a STABLE handle token (`%{doc, kind,
  # path}`) — the raw NIF session lives inside the governor, not on this handle,
  # so an LRU eviction never invalidates the Editor's handle. The kind (docx vs
  # pptx) is carried on the handle so `save/2` picks the right export filter; it
  # comes from `opts[:kind]` (the Pool/Tools layer) or the path extension.
  def open(path, opts \\ []) do
    Instance.open(path, opts)
  end

  @impl true
  def close(%{doc: _} = handle) do
    Instance.close(handle)
  end

  def close(_handle), do: :ok

  @impl true
  # Read a paragraph window from the document. The UNO walker returns the whole
  # element list (paragraphs + cells + shapes) in one JSON; we keep only the
  # text-bearing leaves a human would read (Writer paragraphs / cells; Impress
  # slide/shape text), then window them at the same 30-paragraph cap as HWP so
  # the agent pages through long docs.
  def read(handle, opts) do
    with {:ok, nodes} <- elements(handle) do
      {:ok, window_paragraphs(read_lines(nodes), opts)}
    end
  end

  @impl true
  # Literal search across the element list: any node whose `text` contains the
  # pattern is a hit. Returns the UNO-native ref verbatim (the agent hands it
  # straight back to get/set/edit), plus the offset/len so callers can scope.
  def find(handle, pattern, _opts) when is_binary(pattern) and pattern != "" do
    with {:ok, nodes} <- elements(handle) do
      matches =
        nodes
        |> Enum.filter(&match?(%{"text" => t} when is_binary(t) and t != "", &1))
        |> Enum.filter(fn %{"text" => t} -> String.contains?(t, pattern) end)
        |> Enum.map(&match_node(&1, pattern))

      {:ok, matches}
    end
  end

  def find(_handle, _pattern, _opts), do: {:error, :invalid_pattern}

  @impl true
  # Structural tree. `ref` scopes the subtree root (nil = whole document). The UNO
  # walker is flat, so we synthesise a one-level tree of the top-level elements
  # (paragraphs / tables / slides), or the children of a container ref.
  def outline(handle, ref, _opts) do
    with {:ok, nodes} <- elements(handle) do
      {:ok, build_outline(nodes, ref)}
    end
  end

  # Native UNO property vocabulary per element kind. `inspect` reports these so
  # the agent discovers property names (CharWeight/CharColor/…) instead of
  # hard-coding them; `set/4` passes them straight to `uno_set`. UNO-native
  # casing (these are real `com.sun.star.style.CharacterProperties` etc. names).
  @char_props ~w(CharWeight CharPosture CharColor CharHeight CharUnderline
                 CharStrikeout CharFontName CharBackColor)
  @paragraph_props ~w(ParaAdjust ParaLineSpacing ParaLeftMargin ParaRightMargin
                      ParaFirstLineIndent ParaTopMargin ParaBottomMargin
                      ParaStyleName) ++ @char_props
  @cell_props ~w(BackColor CellBackColor VertOrient) ++ @char_props
  @shape_props ~w(FillColor LineColor RotateAngle Width Height) ++ @char_props

  @doc false
  @spec native_props(Ref.kind()) :: [String.t()]
  def native_props(:run), do: @char_props
  def native_props(:paragraph), do: @paragraph_props
  def native_props(:cell), do: @cell_props
  def native_props(:shape), do: @shape_props
  def native_props(_other), do: []

  @impl true
  def inspect(handle, ref) do
    kind = Ref.classify(ref)
    {:ok, build_inspect(handle, ref, kind)}
  end

  @impl true
  # Native property read: `uno_get(ref)` returns `{ref, type, text, props}`. We
  # surface the `props` map (UNO property name -> value); `props` (a name list)
  # narrows the returned set when given.
  def get(%{doc: _} = handle, ref, props) when is_binary(ref) do
    Instance.run(handle, fn session ->
      case Native.uno_get(session, ref) do
        {:ok, json} ->
          decoded = decode_json(json)
          values = Map.get(decoded, "props", decoded)
          {:ok, narrow(values, props)}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def get(_handle, _ref, _props), do: {:error, :invalid_ref}

  @impl true
  # UNIVERSAL property edit: hand the flat property map straight to `uno_set`,
  # which calls `XPropertySet::setPropertyValue` for each entry. A `kind`
  # discriminator (when the caller embeds one, e.g. {kind:"cell", BackColor})
  # is stripped — UNO routes by the ref/object, not a kind tag.
  def set(%{doc: _} = handle, ref, props, _base_rev) when is_binary(ref) and is_map(props) do
    prop_map = props |> Map.delete("kind") |> Map.delete(:kind)

    Instance.run(
      Instance,
      handle,
      fn session ->
        case Native.uno_set(session, ref, Jason.encode!(prop_map)) do
          :ok -> {:ok, %{ref: ref, set: Map.keys(prop_map)}}
          {:error, {kind, msg}} -> {:error, %{kind: to_string(kind), message: to_string(msg)}}
          {:error, reason} -> {:error, reason}
        end
      end,
      write?: true
    )
  end

  def set(_handle, _ref, _props, _base_rev), do: {:error, :invalid_ref}

  @impl true
  # Structural verb -> `uno_apply` JSON. The normalized `Ecrits.Doc.Op` verbs map
  # onto the UNO arm's text ops:
  #
  #   replace_text  -> replace_all {find, replace}  (whole-doc XReplaceable)
  #                    OR set_text {ref, text}      (when scoped to a ref)
  #   insert_text   -> insert_text {ref, text}      (append at the element's end)
  #   delete_range  -> delete {ref}                 (clear the element's text)
  #
  # The UNO arm is text-level (no caret offsets); we operate on whole elements.
  def edit(%{doc: _} = handle, op, _base_rev) do
    with {:ok, op} <- Op.normalize(op),
         {:ok, uno_op} <- to_uno_op(op) do
      Instance.run(
        Instance,
        handle,
        fn session ->
          case Native.uno_apply(session, Jason.encode!(uno_op)) do
            :ok -> {:ok, %{op: op.op, native: uno_op}}
            {:error, {kind, msg}} -> {:error, %{kind: to_string(kind), message: to_string(msg)}}
            {:error, reason} -> {:error, reason}
          end
        end,
        write?: true
      )
    end
  end

  @impl true
  # Persist via `uno_save(path, filter)`. `format`/`path` come from the Tools
  # layer; the export filter is chosen from the doc kind (docx vs pptx). An empty
  # `path` saves to the document's own URL.
  def save(%{doc: _} = handle, opts) do
    path = Keyword.get(opts, :path) || handle.path || ""
    filter = filter_for(opts[:format] || handle.kind)

    Instance.run(handle, fn session ->
      case Native.uno_save(session, path, filter) do
        :ok ->
          {:ok, %{"path" => path, "filter" => filter}}

        {:error, {kind, msg}} ->
          {:error, %{kind: to_string(kind), message: to_string(msg)}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  The decoded element list (the UNO object-model walk). Each node is a map with
  at least `"ref"` and `"type"`, plus `"text"`/`"row"`/`"col"`/`"context"` where
  the walker provides them. Public so tests/callers can read the raw IR.
  """
  @spec elements(handle()) :: {:ok, [map()]} | {:error, term()}
  def elements(%{doc: _} = handle) do
    Instance.run(handle, fn session ->
      case Native.uno_elements(session) do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, list} when is_list(list) -> {:ok, list}
            _ -> {:ok, []}
          end

        # The UNO arm wasn't built (no LO SDK at NIF build time): surface it as a
        # capability gap so the Tools layer falls back to find/3 instead of failing
        # the whole call.
        {:error, :uno_unavailable} ->
          {:error, {:not_supported, "libreofficex UNO arm not built"}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def elements(_handle), do: {:error, :invalid_handle}

  @impl true
  # `Ecrits.Doc` callback: full-IR element enumeration (docx/pptx `doc.find all:true`
  # + table/cell/shape discovery). Delegates to the 2-arity public `elements/1` (opts
  # are unused — the UNO walker has no windowing) and maps a missing UNO arm to the
  # behaviour's `{:not_supported, _}` so callers fall back to find/3/read/2.
  def elements(handle, _opts), do: elements(handle)

  # --- edit op -> uno_apply JSON -------------------------------------------

  defp to_uno_op(%{op: "replace_text"} = op) do
    query = op[:query]
    replacement = op[:replacement]

    cond do
      is_binary(op[:ref]) and op[:ref] != "" ->
        # Ref-scoped: replace the WHOLE element's text (the UNO arm has no
        # in-element offset; set_text replaces the covered text).
        {:ok, %{"op" => "set_text", "ref" => op[:ref], "text" => replacement}}

      is_binary(query) and query != "" and is_binary(replacement) ->
        {:ok, %{"op" => "replace_all", "find" => query, "replace" => replacement}}

      true ->
        {:error, {:invalid_op, "replace_text needs a ref or (query + replacement)"}}
    end
  end

  defp to_uno_op(%{op: "insert_text", ref: ref, text: text})
       when is_binary(ref) and is_binary(text) do
    {:ok, %{"op" => "insert_text", "ref" => ref, "text" => text}}
  end

  defp to_uno_op(%{op: "delete_range", ref: ref}) when is_binary(ref) do
    {:ok, %{"op" => "delete", "ref" => ref}}
  end

  defp to_uno_op(%{op: verb}),
    do: {:error, {:not_supported, "office edit verb \"#{verb}\" is not supported by the UNO arm"}}

  # --- find / read / outline helpers ---------------------------------------

  defp match_node(%{"ref" => ref, "text" => text} = node, _pattern) do
    %{
      ref: ref,
      text: text,
      type: Map.get(node, "type"),
      context: Map.get(node, "context"),
      off: 0,
      len: String.length(text)
    }
    |> drop_nil()
  end

  defp drop_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  # The text-bearing leaves a doc.read should page through: Writer paragraphs and
  # table cells, Impress slide titles and shape text. Runs (`p0/r0`) duplicate
  # their paragraph's text, so they're excluded.
  defp read_lines(nodes) do
    nodes
    |> Enum.filter(fn n -> n["type"] in ["paragraph", "cell", "slide", "text_frame", "shape"] end)
    |> Enum.map(fn n -> n["text"] || "" end)
    |> Enum.reject(&(&1 == ""))
  end

  # Window the text leaves at the 30-paragraph cap with a continuation cursor,
  # mirroring `Ecrits.Doc.Rhwp.window_paragraphs/2` so doc.read behaves the same
  # across engines.
  defp window_paragraphs(paragraphs, opts) do
    total = length(paragraphs)
    at = opts |> Keyword.get(:at, 0) |> normalize_index(0)

    size =
      opts
      |> Keyword.get(:size, @read_paragraph_cap)
      |> normalize_index(@read_paragraph_cap)
      |> min(@read_paragraph_cap)
      |> max(1)

    window = paragraphs |> Enum.drop(at) |> Enum.take(size)
    returned = length(window)
    next_at = if at + returned < total, do: at + returned, else: nil

    %{
      text: Enum.join(window, "\n"),
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

  # One-level structural tree. For the document root (nil ref) the children are
  # the top-level elements (paragraphs/tables/slides — not nested cells/runs);
  # for a container ref the children are its direct descendants by ref prefix.
  defp build_outline(nodes, nil), do: build_outline(nodes, "")

  defp build_outline(nodes, ""), do: do_outline(nodes, "document", "", &top_level?/1)

  defp build_outline(nodes, ref) when is_binary(ref) do
    type = ref |> Ref.classify() |> Ref.type()
    do_outline(nodes, type, ref, &child_of?(&1, ref))
  end

  defp do_outline(nodes, type, ref, keep?) do
    children =
      nodes
      |> Enum.filter(keep?)
      |> Enum.map(fn n ->
        %{ref: n["ref"], type: n["type"], text: preview(n["text"])} |> drop_nil()
      end)

    %{ref: ref, type: type, children: children}
  end

  # A top-level element has no `/` in its ref (p0, tbl[..], page[..]) — but the
  # walker also emits cells whose refs DO contain `/` and runs likewise, so we
  # keep only paragraphs/tables/slides at the root.
  defp top_level?(%{"ref" => ref, "type" => type}) when is_binary(ref),
    do: type in ["paragraph", "table", "slide"] and not String.contains?(ref, "/r")

  defp top_level?(_node), do: false

  defp child_of?(%{"ref" => ref}, parent) when is_binary(ref),
    do: String.starts_with?(ref, parent <> "/") or String.starts_with?(ref, parent <> "]/")

  defp child_of?(_node, _parent), do: false

  defp preview(nil), do: nil
  defp preview(text, max \\ 80) when is_binary(text),
    do: if(String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text)

  # --- inspect helpers -----------------------------------------------------

  defp build_inspect(handle, ref, kind) do
    base = %{
      ref: ref || "",
      type: Ref.type(kind),
      kind: Atom.to_string(kind),
      interfaces: interfaces_for(kind),
      properties: native_props(kind)
    }

    case kind do
      k when k in [:document, :table, :slide] ->
        case outline(handle, ref, []) do
          {:ok, %{children: children}} -> Map.put(base, :children, child_summaries(children))
          _ -> Map.put(base, :children, [])
        end

      _ ->
        Map.put(base, :children, [])
    end
  end

  defp child_summaries(children),
    do: Enum.map(children, fn c -> %{ref: c.ref, type: c.type} end)

  defp interfaces_for(:document), do: ["Document", "Container"]
  defp interfaces_for(:paragraph), do: ["Paragraph", "Container", "CharProperties"]
  defp interfaces_for(:run), do: ["CharRun", "CharProperties"]
  defp interfaces_for(:table), do: ["Table", "Container"]
  defp interfaces_for(:cell), do: ["Cell", "Container", "CharProperties"]
  defp interfaces_for(:slide), do: ["Slide", "Container"]
  defp interfaces_for(:shape), do: ["Shape", "Positioned", "CharProperties"]
  defp interfaces_for(_other), do: []

  # --- install dir + profile resolution ------------------------------------

  @doc """
  Resolve the LOK install dir (`…/Contents/Frameworks` holding
  `libsofficeapp.dylib`). Order: app config -> `LOK_INSTALL_DIR` env ->
  `~/Desktop/core` discovery (System.user_home()-relative). Returns
  `{:error, :no_install_dir}` when none resolves to a real bundle.
  """
  @spec install_dir() :: {:ok, String.t()} | {:error, :no_install_dir}
  def install_dir do
    candidates =
      [
        Application.get_env(:ecrits, __MODULE__, [])[:install_dir],
        System.get_env("LOK_INSTALL_DIR"),
        default_install_dir()
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    case Enum.find(candidates, &lok_present?/1) do
      nil -> {:error, :no_install_dir}
      dir -> {:ok, dir}
    end
  end

  # The default discovery path, identical to the NIF build.rs default (the M1/M2/
  # M3 spike layout) but derived from System.user_home() so no developer home is
  # hardcoded in committed source.
  defp default_install_dir do
    case System.user_home() do
      home when is_binary(home) ->
        Path.join([home, "Desktop", "core", "instdir", "LibreOffice.app", "Contents", "Frameworks"])

      _ ->
        nil
    end
  end

  defp lok_present?(dir) when is_binary(dir),
    do: File.exists?(Path.join(dir, "libsofficeapp.dylib")) or File.dir?(dir)

  defp lok_present?(_dir), do: false

  # --- kind / filter helpers -----------------------------------------------
  # The UNO session lifecycle (open/reopen/save/close, install-dir + profile +
  # kind resolution) now lives in `Ecrits.Doc.Office.Native`, owned by the
  # serializing `Ecrits.Doc.Office.Instance`. The backend keeps only the export
  # filter mapping (used by `save/2` to label the result) here.

  defp filter_for(:pptx), do: @pptx_filter
  defp filter_for(:docx), do: @docx_filter
  defp filter_for(_other), do: @docx_filter

  # --- json helpers --------------------------------------------------------

  defp decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode_json(_other), do: %{}

  defp narrow(values, nil), do: values
  defp narrow(values, []), do: values

  defp narrow(values, props) when is_list(props) and is_map(values),
    do: Map.take(values, props)

  defp narrow(values, _props), do: values
end
