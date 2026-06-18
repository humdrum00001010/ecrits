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
    * `set/3`      -> `uno_set(ref, props_json)` (UNIVERSAL property setter)
    * `edit/2`     -> op → `uno_apply(op_json)` (insert_text/replace_text/delete/
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
  # Reload the server twin from disk. UNO opens a FILE/URL, never a byte buffer,
  # so we IGNORE `bytes` and reopen the doc's own path — by the time the browser
  # save's twin-sync calls this, `Document.save` has already written those exact
  # bytes to the canonical file. (Feeding bytes to `open/2`, which treats its arg
  # as a path, is what crashed pptx save->close.) The Editor closes the old
  # handle once we hand back the new one.
  def reopen(%{path: path, kind: kind}, _bytes) when is_binary(path) do
    Instance.open(path, kind: kind)
  end

  def reopen(_handle, _bytes), do: {:error, :invalid_handle}

  @doc """
  Write a LibreOffice factory-blank document to `path` — the engine's own "new
  presentation" (`private:factory/simpress`), exported as pptx/docx. This is the
  from-scratch authoring seed: the caller opens it and builds slides/shapes via
  IR-direct `insert_slide`/`insert_shape` edit ops.
  """
  @spec create_blank_file(String.t(), :docx | :pptx) :: :ok | {:error, term()}
  def create_blank_file(path, kind) when is_binary(path) and kind in [:docx, :pptx] do
    Instance.create_blank_file(path, kind)
  end

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
  # hard-coding them; `set/3` passes them straight to `uno_set`. UNO-native
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
  def set(%{doc: _} = handle, ref, props) when is_binary(ref) and is_map(props) do
    prop_map =
      props
      |> Map.delete("kind")
      |> Map.delete(:kind)
      |> Enum.flat_map(fn {k, v} -> Ecrits.Doc.Office.Props.normalize(to_string(k), v) end)
      |> Map.new()
      |> Ecrits.Doc.Office.Props.pair_fill_styles()

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

  def set(_handle, _ref, _props), do: {:error, :invalid_ref}

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
  def edit(%{doc: _} = handle, op) do
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
  Rasterize one slide to a PNG at `path` via the engine's own
  GraphicExportFilter (`render_page` uno_apply op). Pure read — the document is
  not marked dirty. `width` is the pixel width; height follows the slide's
  aspect ratio. This is the agent's visual feedback loop: render, look, fix.
  """
  @spec render_page(handle(), String.t(), String.t(), pos_integer()) :: :ok | {:error, term()}
  # Writer (docx) arm: text documents have no Impress draw pages, so the
  # GraphicExportFilter op below can't see them. Render via the engine's PDF
  # export (writer_pdf_Export) + poppler's pdftoppm, page numbers are 1-based
  # strings ("1", "2", …) like the HWP arm.
  def render_page(%{doc: _, kind: :docx} = handle, page, path, width)
      when is_binary(page) and is_binary(path) and is_integer(width) do
    with {:ok, pageno} <- writer_page_number(page),
         {:ok, pdftoppm} <- require_pdftoppm() do
      tmp_pdf =
        Path.join(
          System.tmp_dir!(),
          "ecrits_writer_render_#{System.unique_integer([:positive])}.pdf"
        )

      try do
        Instance.run(
          Instance,
          handle,
          fn session ->
            case Native.uno_save(session, tmp_pdf, "writer_pdf_Export") do
              :ok -> rasterize_pdf_page(pdftoppm, tmp_pdf, pageno, path, width)
              {:error, reason} -> {:error, %{kind: "save_failed", message: inspect(reason)}}
            end
          end,
          write?: false
        )
      after
        File.rm(tmp_pdf)
      end
    end
  end

  def render_page(%{doc: _} = handle, page, path, width)
      when is_binary(page) and is_binary(path) and is_integer(width) do
    op = %{"op" => "render_page", "page" => page, "path" => path, "width" => width}

    Instance.run(
      Instance,
      handle,
      fn session ->
        case Native.uno_apply(session, Jason.encode!(op)) do
          :ok -> :ok
          {:error, {kind, msg}} -> {:error, %{kind: to_string(kind), message: to_string(msg)}}
          {:error, reason} -> {:error, reason}
        end
      end,
      write?: false
    )
  end

  def render_page(_handle, _page, _path, _width), do: {:error, :invalid_handle}

  defp writer_page_number(page) do
    case Integer.parse(to_string(page)) do
      {n, ""} when n >= 1 ->
        {:ok, n}

      _other ->
        {:error,
         %{
           kind: "invalid_params",
           message:
             "docx page must be a 1-based page NUMBER string (\"1\", \"2\", …), got: #{inspect(page)}"
         }}
    end
  end

  defp require_pdftoppm do
    case System.find_executable("pdftoppm") do
      nil -> {:error, %{kind: "render_failed", message: "pdftoppm (poppler) not installed"}}
      exe -> {:ok, exe}
    end
  end

  # `-singlefile` writes exactly `<prefix>.png` for the one selected page; a
  # page past the end produces no file, which we surface as no such page.
  defp rasterize_pdf_page(pdftoppm, pdf, pageno, out_path, width) do
    prefix = String.replace_suffix(out_path, ".png", "")

    args = [
      "-png",
      "-singlefile",
      "-f",
      to_string(pageno),
      "-l",
      to_string(pageno),
      "-scale-to-x",
      to_string(width),
      "-scale-to-y",
      "-1",
      pdf,
      prefix
    ]

    case System.cmd(pdftoppm, args, stderr_to_stdout: true) do
      {_out, 0} ->
        png = prefix <> ".png"

        cond do
          png == out_path and File.exists?(png) -> :ok
          File.exists?(png) -> File.rename(png, out_path)
          true -> {:error, %{kind: "render_failed", message: "no such page: #{pageno}"}}
        end

      {out, code} ->
        {:error, %{kind: "render_failed", message: "pdftoppm exit #{code}: #{out}"}}
    end
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

  # --- edit op -> typed Ecrits.Doc.Office.Op -> uno_apply wire map ----------
  # Classify the agent IR op (handling the conditional dispatch — replace_text→
  # set_text/replace_all, insert_picture→insert_shape), build the matching typed
  # Op struct (@enforce_keys validates required fields at construction), and
  # serialise it with to_wire/1 — byte-identical to the legacy maps (#49 O1).

  alias Ecrits.Doc.Office.Op

  # Verbs whose sole required field is a binary `ref` and that Op.normalize does
  # NOT field-check — when the agent omits the ref they match no value-guarded
  # to_uno_op clause and hit the catch-all, which used to mislabel them "not
  # supported by the UNO arm". They ARE supported; the ref is just missing. (#49 —
  # accurate construction errors; the rest are caught earlier in Op.normalize.)
  @office_ref_required_verbs ~w(delete_paragraph split merge merge_cells split_cell delete_node)

  @doc false
  # Test seam: the op→wire classification that edit/3 runs BEFORE touching a UNO
  # session (the IR Ecrits.Doc.Op.normalize, then to_uno_op). Pure — no LOK/session
  # needed. NB `Op` is rebound to Ecrits.Doc.Office.Op just below, so the IR
  # normaliser is fully qualified here.
  @spec classify(map()) :: {:ok, map()} | {:error, term()}
  def classify(op) do
    with {:ok, op} <- Ecrits.Doc.Op.normalize(op), do: to_uno_op(op)
  end

  defp to_uno_op(%{op: "replace_text"} = op) do
    query = op[:query]
    replacement = op[:replacement]

    cond do
      is_binary(op[:ref]) and op[:ref] != "" ->
        # Ref-scoped: the UNO arm has no in-element offset; set_text replaces the
        # whole covered element text.
        {:ok, Op.SetText.to_wire(%Op.SetText{ref: op[:ref], text: replacement})}

      is_binary(query) and query != "" and is_binary(replacement) ->
        {:ok, Op.ReplaceAll.to_wire(%Op.ReplaceAll{find: query, replace: replacement})}

      true ->
        {:error, {:invalid_op, "replace_text needs a ref or (query + replacement)"}}
    end
  end

  defp to_uno_op(%{op: "insert_text", ref: ref, text: text})
       when is_binary(ref) and is_binary(text) do
    {:ok, Op.InsertText.to_wire(%Op.InsertText{ref: ref, text: text})}
  end

  # HWP-arm verb agents reuse on office tables: set the whole cell's text.
  defp to_uno_op(%{op: "set_cell", ref: ref} = op) when is_binary(ref) do
    {:ok, Op.SetText.to_wire(%Op.SetText{ref: ref, text: op[:text] || ""})}
  end

  defp to_uno_op(%{op: "delete_range", ref: ref}) when is_binary(ref) do
    {:ok, Op.Delete.to_wire(%Op.Delete{ref: ref})}
  end

  defp to_uno_op(%{op: "insert_slide"} = op) do
    {:ok, Op.InsertSlide.to_wire(%Op.InsertSlide{name: op[:name], index: op[:index]})}
  end

  # IR-direct: typed slide-frame fields + arbitrary UNO props (FillColor,
  # CharHeight, …) carried verbatim in :props (see build_insert_shape/1).
  defp to_uno_op(%{op: "insert_shape", page: page} = op) when is_binary(page) do
    {:ok, Op.InsertShape.to_wire(build_insert_shape(op))}
  end

  # Office form of the HWP picture verb: an embedded image is a
  # GraphicObjectShape whose GraphicURL points at the source file; route through
  # the insert_shape clause. `src` is a plain path or file:// URL.
  defp to_uno_op(%{op: "insert_picture", page: page} = op) when is_binary(page) do
    src = op[:src] || op[:path]

    if is_binary(src) and src != "" do
      op
      |> Map.drop([:src, :path])
      |> Map.merge(%{
        op: "insert_shape",
        service: "com.sun.star.drawing.GraphicObjectShape",
        GraphicURL: to_file_url(src)
      })
      |> to_uno_op()
    else
      {:error,
       {:invalid_op,
        "office insert_picture requires \"src\" (image file path), plus page/name/x/y/w/h like insert_shape"}}
    end
  end

  defp to_uno_op(%{op: "set_geometry", ref: ref} = op) when is_binary(ref) do
    {:ok,
     Op.SetGeometry.to_wire(%Op.SetGeometry{ref: ref, x: op[:x], y: op[:y], w: op[:w], h: op[:h]})}
  end

  defp to_uno_op(%{op: "delete_node", ref: ref}) when is_binary(ref) do
    {:ok, Op.DeleteNode.to_wire(%Op.DeleteNode{ref: ref})}
  end

  defp to_uno_op(%{op: "insert_shape"}) do
    {:error,
     {:invalid_op,
      "office insert_shape requires \"page\" (slide name from doc.find / insert_slide), " <>
        "\"service\" (a UNO shape service, e.g. com.sun.star.drawing.RectangleShape or " <>
        ".TextShape), \"name\" (your ref becomes page[<page>]/shape[<name>]), and " <>
        "x/y/w/h in 1/100 mm; other keys are raw UNO properties applied verbatim"}}
  end

  # ── Writer (docx) structural verbs ─────────────────────────────────────
  defp to_uno_op(%{op: "insert_paragraph"} = op) do
    {:ok,
     Op.InsertParagraph.to_wire(%Op.InsertParagraph{
       ref: op[:ref] || "end",
       text: op[:text],
       style: op[:style]
     })}
  end

  defp to_uno_op(%{op: "insert_table"} = op) do
    {:ok,
     Op.InsertTable.to_wire(%Op.InsertTable{
       ref: op[:ref] || "end",
       rows: op[:rows],
       cols: op[:cols],
       name: op[:name]
     })}
  end

  defp to_uno_op(%{op: "insert_footnote"} = op) do
    {:ok, Op.InsertFootnote.to_wire(%Op.InsertFootnote{ref: op[:ref], text: op[:text]})}
  end

  # Writer inline image (no slide `page:`). `src` is a path or file:// URL.
  defp to_uno_op(%{op: "insert_picture"} = op) do
    src = op[:src] || op[:path]

    if is_binary(src) and src != "" do
      {:ok,
       Op.InsertPicture.to_wire(%Op.InsertPicture{
         ref: op[:ref] || "end",
         src: to_file_url(src),
         w: op[:w] || op[:width],
         h: op[:h] || op[:height],
         name: op[:name]
       })}
    else
      {:error,
       {:invalid_op,
        "office insert_picture requires \"src\" (image file path); Writer form takes " <>
          "ref(\"p<idx>\"|\"end\") + optional w/h in 1/100 mm, slide form takes page/name/x/y/w/h"}}
    end
  end

  defp to_uno_op(%{op: "set_columns"} = op) do
    {:ok,
     Op.SetColumns.to_wire(%Op.SetColumns{
       count: op[:count],
       from: op[:from],
       to: op[:to],
       name: op[:name]
     })}
  end

  defp to_uno_op(%{op: "delete_paragraph", ref: ref}) when is_binary(ref) do
    {:ok, Op.DeleteParagraph.to_wire(%Op.DeleteParagraph{ref: ref})}
  end

  defp to_uno_op(%{op: "split", ref: ref} = op) when is_binary(ref) do
    {:ok, Op.Split.to_wire(%Op.Split{ref: ref, at: op[:at]})}
  end

  defp to_uno_op(%{op: "merge", ref: ref}) when is_binary(ref) do
    {:ok, Op.Merge.to_wire(%Op.Merge{ref: ref})}
  end

  # Table row/col insert+delete — the 4 verbs share one field set; the verb tag
  # picks the struct (each carries @enforce_keys [:ref]).
  defp to_uno_op(%{op: verb} = op)
       when verb in ~w(insert_table_row delete_table_row insert_table_column delete_table_column) do
    case op[:ref] do
      ref when is_binary(ref) and ref != "" ->
        mod = Module.concat(Op, Macro.camelize(verb))

        wire =
          struct!(mod,
            ref: ref,
            row: op[:row],
            col: op[:col],
            count: op[:count],
            below: op[:below],
            right: op[:right]
          )

        {:ok, mod.to_wire(wire)}

      _ ->
        {:error,
         {:invalid_op,
          "office #{verb} needs a table ref: tbl[<name>] (then row/col), " <>
            "tbl[<name>]/cell[<A1>] (row/col derived), or an Impress table shape ref"}}
    end
  end

  defp to_uno_op(%{op: "merge_cells", ref: ref} = op) when is_binary(ref) do
    {:ok,
     Op.MergeCells.to_wire(%Op.MergeCells{
       ref: ref,
       start_row: op[:start_row],
       start_col: op[:start_col],
       end_row: op[:end_row],
       end_col: op[:end_col]
     })}
  end

  defp to_uno_op(%{op: "split_cell", ref: ref} = op) when is_binary(ref) do
    {:ok,
     Op.SplitCell.to_wire(%Op.SplitCell{
       ref: ref,
       row: op[:row],
       col: op[:col],
       rows: op[:rows],
       cols: op[:cols]
     })}
  end

  defp to_uno_op(%{op: "insert_endnote"} = op) do
    {:ok, Op.InsertEndnote.to_wire(%Op.InsertEndnote{ref: op[:ref], text: op[:text]})}
  end

  defp to_uno_op(%{op: "insert_equation"} = op) do
    {:ok,
     Op.InsertEquation.to_wire(%Op.InsertEquation{ref: op[:ref] || "end", script: op[:script]})}
  end

  # A SUPPORTED verb that fell through every value-guarded clause above is missing
  # its required binary `ref` — say THAT, rather than the bare catch-all's "not
  # supported" (which sends the agent hunting for a different verb instead of
  # supplying the ref it already has from doc.find). #49: accurate errors.
  defp to_uno_op(%{op: verb}) when verb in @office_ref_required_verbs do
    {:error,
     {:invalid_op,
      "office #{verb} requires a \"ref\" (from doc.find) identifying the target " <>
        "paragraph/cell/table/shape"}}
  end

  defp to_uno_op(%{op: verb}),
    do: {:error, {:not_supported, "office edit verb \"#{verb}\" is not supported by the UNO arm"}}

  # IR-direct insert_shape: typed slide-frame fields + the rest (arbitrary UNO
  # props) carried verbatim in :props; Op.InsertShape.to_wire applies the
  # scalar-filter + UNO prop normalisation + fill/line style pairing.
  defp build_insert_shape(op) do
    %Op.InsertShape{
      page: op[:page],
      name: op[:name],
      service: op[:service],
      x: op[:x],
      y: op[:y],
      w: op[:w],
      h: op[:h],
      text: op[:text],
      props: Map.drop(op, [:op, :page, :name, :service, :x, :y, :w, :h, :text])
    }
  end

  # Slide picture src → file:// URL (Op.InsertShape.to_wire owns the UNO prop
  # normalisation + scalar filtering that the legacy helpers did, now #49 O1).
  defp to_file_url("file://" <> _ = url), do: url
  defp to_file_url(path), do: "file://" <> Path.expand(path)

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
        Path.join([
          home,
          "Desktop",
          "core",
          "instdir",
          "LibreOffice.app",
          "Contents",
          "Frameworks"
        ])

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
