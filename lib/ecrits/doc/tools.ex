defmodule Ecrits.Doc.Tools do
  @moduledoc """
  Reflective MCP tool surface for the document-editing abstraction (design §4.4).

  A *small* set of generic, document-addressed tools — every tool takes a
  `document` id and operates on that document (not just the one being viewed):

  | tool             | risk  | maps to |
  |------------------|-------|---------|
  | `doc.context`    | read  | active document + cursor/selection ref |
  | `doc.list`       | read  | `Pool.list/1` |
  | `doc.open`       | read  | `Pool.open/3` |
  | `doc.create`     | write | `Pool.create/3` (blank template) |
  | `doc.read`       | read  | `Editor.read/2` (**≤30 paragraphs/call** + cursor) |
  | `doc.find`       | read  | `Editor.find/3` |
  | `doc.get`        | read  | `Editor.get/3` + `Editor.inspect_element/2` (type/values/settable/children) |
  | `doc.set`        | write | `Editor.set/4` (base_revision) — UNIVERSAL property setter |
  | `doc.edit`       | write | `Editor.apply/3` (base_revision) |
  | `doc.save`       | write | `Editor.save/2` |

  Ten tools (the former `doc.inspect` and `doc.apply_style` are folded away):
  `doc.get` now also returns the reflective discovery the standalone
  `doc.inspect` used to (element type + the settable native-property names +
  child refs) alongside the current values, and char-run formatting is just
  `doc.set` (it routes char refs to the engine's `apply_char_format`), so there
  is a single read-properties tool and a single write-properties tool.

  `doc.read` is **incremental**: a single call returns at most 30 paragraphs (a
  hard cap, design §4.4) plus a `next_at` cursor, so the agent pages through a
  document and never pulls the whole thing.

  The deep Office tools (`office.inspect`/`office.call`/`office.dispatch`,
  design §4.4 "Office 전용 심화") are intentionally **not** part of this HWP
  surface; the LibreOffice backend is a separate effort. `doc.get`'s reflective
  discovery is the engine-agnostic equivalent for the HWP backend.

  Tools run against a context map. The minimal form is `%{pool: pool}` (defaults
  to the named `Ecrits.Doc.Pool`) — the global, pre-isolation context still used
  by the bare MCP mount and by server-side tests. The **per-agent** form
  (design invariant 3) additionally carries `:agent_id` (the calling agent, from
  its `/mcp/doc-tools/<agent_id>` url) and `:active_doc` (THAT agent's own active
  document id). In an agent context:

    * `doc.context` returns the agent's OWN `active_doc`, never the global
      `Pool.active`, so two agents never see each other's doc;
    * `doc.open` FAILS with `already_open` for an already-open doc (invariant 1)
      and records per-agent ownership;
    * `doc.edit` is `:forbidden` when another agent owns the doc (invariant 2),
      while an unowned (human-opened) doc is editable and lazily claimed.

  Results are JSON-shaped maps so the layer is testable server-side without a
  browser or an MCP transport. Errors that the agent is expected to act on
  (conflict, capability gaps, already_open/forbidden) are returned as structured
  maps mirroring the design's example payloads.
  """

  alias Ecrits.Doc.Editor
  alias Ecrits.Doc.Pool

  @namespace "doc"

  # PubSub topic the workspace LiveView subscribes to so an agent file-write
  # (doc.create-clone / doc.save) refreshes the file tree LIVE — without waiting
  # for the (unreliable, fsevents-coalesced) FS watcher or the turn-end refresh.
  # The message carries the ABSOLUTE written path; each LiveView filters it to
  # paths under its own workspace root, so a write outside any open workspace
  # (a temp/scratch file) is ignored rather than spamming every tree.
  @workspace_files_topic "workspace:files"
  @workspace_files_pubsub Ecrits.PubSub

  @doc "PubSub topic the workspace LiveView subscribes to for agent file-writes."
  @spec workspace_files_topic() :: String.t()
  def workspace_files_topic, do: @workspace_files_topic

  # How long to wait for the viewing LiveView (browser WASM model) to apply an
  # agent op and report back. The browser apply is a single push_event round-trip
  # plus a WASM `replaceAll`/`insertText`, so this is generous.
  @browser_timeout_ms 15_000

  # Hard cap on `doc.read` (design §4.4, the user's explicit limit). Sourced
  # from the backend so the tool schema and the enforcement can never drift.
  @read_cap Ecrits.Doc.Rhwp.read_paragraph_cap()

  @tools [
    %{
      "namespace" => @namespace,
      "name" => "context",
      "description" =>
        "Active/focused document id + cursor/selection ref. Reads whatever active-doc " <>
          "and cursor state is currently available server-side. (Browser->server cursor " <>
          "reporting that populates the live cursor is wired by the editors; see TODO.)",
      "risk" => "read",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}},
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "list",
      "description" => "List open/available documents (id, kind, path, revision, backing).",
      "risk" => "read",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}},
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "open",
      "description" => "Load a document into the pool. Returns {document, kind}.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "minLength" => 1},
          "kind" => %{"type" => "string", "enum" => ["hwp", "hwpx", "docx", "pptx"]}
        },
        "required" => ["path"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "create",
      "description" =>
        "Create a NEW document whose save target is `path` (the file need not exist " <>
          "yet). Returns {document, kind}.\n" <>
          "• WITHOUT `from`: a blank document. Author content with doc.edit " <>
          "(insert_text/insert_paragraph/split/insert_table_*/…) and persist with doc.save.\n" <>
          "• WITH `from` (CLONE A TEMPLATE — use this when asked to make a document " <>
          "\"in the format of\" / \"같은 양식으로\" / \"…형식대로\" an existing doc): `from` is " <>
          "an existing HWP document's file PATH or an open document id. The template " <>
          "file is byte-copied to `path`, so the clone INHERITS ALL of the template's " <>
          "formatting (column widths, cell/paragraph patterns, fonts, headers, tables). " <>
          "Then REPLACE the template's content cell-by-cell (doc.find + doc.edit " <>
          "replace_text / insert_text) preserving each cell's structure, and use " <>
          "doc.edit insert_table_row to add rows that inherit the template's cell format " <>
          "— do NOT rebuild a table from scratch.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "minLength" => 1},
          "kind" => %{"type" => "string", "enum" => ["hwp", "hwpx"]},
          "from" => %{
            "type" => "string",
            "minLength" => 1,
            "description" =>
              "Optional template to clone: an existing HWP document's file path OR an " <>
                "open document id. The file is byte-copied to `path` so the new document " <>
                "inherits all of the template's formatting."
          }
        },
        "required" => ["path"]
      }
    },
    %{
      "namespace" => @namespace,
      "name" => "read",
      "description" =>
        "Read a chunk of a document's elements. INCREMENTAL: a single call returns " <>
          "AT MOST #{@read_cap} elements (a hard cap) and never the whole document. " <>
          "Start at index `at` (default 0); `size` is the requested count, clamped to " <>
          "#{@read_cap}. Each entry in `paragraphs` is `{text, ref, table_cell}` — body " <>
          "paragraphs AND every TABLE CELL (including EMPTY cells, prefixed `[cell]` in " <>
          "`text`). Use the per-element `ref` to edit it directly (e.g. insert_text into " <>
          "an empty cell, or replace_text in a filled one) — this is how you find and fill " <>
          "blank table fields a text search can't see. The result includes `next_at` " <>
          "(cursor for the next page, or null at end) and `total` — page through with it.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "at" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" => "0-based paragraph index to start the page at."
          },
          "size" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @read_cap,
            "description" =>
              "Requested paragraph count; hard-capped at #{@read_cap} per call."
          }
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "find",
      "description" =>
        "Literal search -> [{ref, text}]. With `all:true`, returns EVERY element " <>
          "including empty table cells (each with its own ref) and treats `pattern` " <>
          "as a REGULAR EXPRESSION — use it to discover blanks to fill: " <>
          "`{all:true}` lists the whole document structure; " <>
          "`{all:true, pattern:\"^\\\\s*$\"}` lists only the empty elements. " <>
          "In `all` mode `pattern` is optional (omit it to match everything). " <>
          "Pass `type` to fetch just one slice by element type — `\"empty_cell\"` " <>
          "(blank table cells to fill), `\"cell\"` (all table cells), " <>
          "`\"filled_cell\"`, `\"paragraph\"` (body), or `\"empty\"` — combinable " <>
          "with `pattern`. To FILL a form, call `{type:\"empty_cell\"}` once to get " <>
          "exactly the blanks, then insert_text into each. Every CELL match also " <>
          "carries `context` = \"<column header> / <row label>\" (e.g. " <>
          "\"지급금액 / 선급금\") plus `row`/`col`, so a blank self-describes what it is " <>
          "for — you usually do NOT need to read the table to know what to fill.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "pattern" => %{"type" => "string"},
          "case_sensitive" => %{"type" => "boolean", "default" => false},
          "all" => %{
            "type" => "boolean",
            "default" => false,
            "description" =>
              "Return EVERY addressable element (body paragraphs AND table cells, " <>
                "empty cells included) and treat `pattern` as a regex. `pattern` is " <>
                "optional in this mode."
          },
          "regex" => %{
            "type" => "boolean",
            "default" => false,
            "description" => "Treat `pattern` as a regular expression (implied by `all`)."
          },
          "type" => %{
            "type" => "string",
            "enum" =>
              ~w(empty_cell cell filled_cell paragraph empty
                 table picture shape equation field form
                 header footer footnote endnote bookmark hyperlink
                 ruby auto_number new_number section_def column_def
                 page_number_pos page_hide hidden_comment char_overlap unknown),
            "description" =>
              "Return only elements of this IR type (with refs). Cell-state filters: " <>
                "`empty_cell` = blank table cells to fill; `cell`/`filled_cell` = table " <>
                "cells; `paragraph` = body paragraphs; `empty` = any blank element. Also " <>
                "spans the FULL document taxonomy — table/picture/shape/equation/field/" <>
                "form/header/footer/footnote/endnote/… Combine with `pattern`."
          }
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "get",
      "description" =>
        "Inspect an element (ref). Returns its `type`, current property `values`, the " <>
          "`settable` property NAMES doc.set understands for that element (e.g. " <>
          "Bold/Italic/FontSize for a char run, BackgroundColor for a cell, " <>
          "Alignment/LineSpacing for a paragraph), and child `refs`. Use this to discover " <>
          "what you can set and read current values in one call. `props?` narrows the " <>
          "returned values to those names. Pass `refs:[...]` to inspect many elements in " <>
          "ONE call (best-effort, per-ref result). Supply EITHER `ref` (single) OR `refs`.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "refs" => %{
            "type" => "array",
            "description" => "Batch form: inspect every ref in this array; per-ref result.",
            "items" => %{"type" => "string"}
          },
          "props" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "set",
      "description" =>
        "Universal property edit — sets ANY element's properties (use doc.get to discover " <>
          "the settable names). Examples: a CHAR run -> {Bold:true, TextColor:\"#FF0000\", " <>
          "FontSize:12}; a TABLE CELL -> {kind:\"cell\", BackgroundColor:\"#FFFF00\"} (to fill " <>
          "a cell/column, doc.find the cells then doc.set kind:cell BackgroundColor); a " <>
          "PARAGRAPH -> {Alignment:\"center\", LineSpacing:160}; table/picture/shape props " <>
          "likewise. Routes to the right native setter automatically. Honours base_revision. " <>
          "Pass `sets:[{ref,props}, ...]` to set many elements in ONE call (best-effort, " <>
          "per-set result, one bad ref does not abort the others). Supply EITHER " <>
          "`ref`+`props` (single) OR `sets`.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "props" => %{"type" => "object"},
          "sets" => %{
            "type" => "array",
            "description" =>
              "Batch form: an array of `{ref, props}` objects, each like the single form.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "ref" => %{"type" => "string"},
                "props" => %{"type" => "object"}
              },
              "required" => ["ref", "props"]
            }
          },
          "base_revision" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "edit",
      "description" =>
        "Apply ONE structural edit (`op`), discriminated by op.op. Honours base_revision. " <>
          "Pass `ops:[...]` to apply many edits in ONE call (e.g. fill every blank cell) — " <>
          "far fewer round-trips. Best-effort: each op is applied independently and you get " <>
          "a per-op result; one bad ref does not abort the others.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ops" => %{
            "type" => "array",
            "description" =>
              "Batch form: an array of op objects (each shaped like `op`). Applied " <>
                "best-effort with a per-op result; supply EITHER `op` (single) OR `ops`.",
            "items" => %{"type" => "object"}
          },
          "op" => %{
            "type" => "object",
            "description" =>
              "The edit. Field `op` is the verb. Per verb:\n" <>
                "• replace_text {op, query, replacement, ref?, all?}: replace the literal `query` text with `replacement`. " <>
                "BOTH `query` and `replacement` are REQUIRED (the field is `replacement`, NOT `text`/`new`/`value`). " <>
                "To DELETE text use delete_range — never an empty/omitted `replacement`. " <>
                "`replacement` is SINGLE-paragraph text: do NOT put newlines in it (one paragraph per op; use `split` to add paragraphs). " <>
                "By default only the FIRST match is replaced; scope to one paragraph with `ref` (from doc.find), or pass `all:true` to replace every match. " <>
                "If `query` occurs in more than one place and neither `ref` nor `all` is given, the edit is REJECTED (so you never edit unrelated sample blocks by accident).\n" <>
                "• insert_text {op, ref, text}: `text` MAY contain `\\n` — each newline starts a NEW paragraph " <>
                  "(the body is expanded into real paragraphs). Use this to author multi-paragraph content " <>
                  "(e.g. each contract clause / 조 on its own line) in ONE call instead of one giant run-on paragraph.\n" <>
                "• set_cell {op, ref, text}: REPLACE a table CELL's entire content with `text` in ONE op. `ref` must be a " <>
                  "CELL ref (from doc.find on text inside that cell) — including a NESTED cell (a table inside a cell, whose " <>
                  "ref carries `cellPath`): set_cell replaces nested header/title cells too. `text` is split on `\\n` into one " <>
                  "cell paragraph per line, and EACH line inherits the cell's existing paragraph + character formatting " <>
                  "(font, alignment, color). Use this to fill a multi-paragraph cell (e.g. an `① English sentence\\n해석(Korean)` " <>
                  "two-line cell) without per-line replace_text/split surgery. " <>
                  "To CHANGE a cell that ALREADY has text (e.g. a header reading 'Lesson 3' → 'Lesson 4'), ALWAYS use set_cell — " <>
                  "it clears then rewrites the cell. NEVER insert_text into a non-empty cell: insert APPENDS, leaving the old text " <>
                  "behind so the two overlap/render garbled. Preferred over replace_text when you want to swap a whole cell's body.\n" <>
                "• delete_range {op, ref, count?}\n" <>
                "• insert_paragraph {op, ref} • delete_paragraph {op, ref} • split {op, ref} • merge {op, ref}\n" <>
                "• insert_table {op, ref, rows, cols}: create a NEW rows×cols table at `ref`. Returns native {paraIdx, controlIdx} — " <>
                "use it to fill cells: insert_text with a ref carrying {section, paragraph: paraIdx, control: controlIdx, cell: <0-based cell index, row-major>, cell_para: 0, offset: 0}.\n" <>
                "• insert_table_row / delete_table_row / insert_table_column / delete_table_column / merge_cells / split_cell {op, ref}: modify an EXISTING table.\n" <>
                "• delete_node {op, ref} • insert_picture {op, ref, bins}\n" <>
                "• insert_equation {op, ref, script, font_size?, color?}: insert an inline equation at `ref`; `script` is HWP equation markup (e.g. \"x^2 + y^2 = z^2\").\n" <>
                "• insert_footnote {op, ref, text?} • insert_endnote {op, ref, text?}: insert a footnote/endnote anchor at `ref` (number auto-assigned); pass `text` to fill the note's body (otherwise the note is empty — do NOT fake notes as body paragraphs).\n" <>
                "• insert_shape {op, ref, width, height, shape_type?, x?, y?}: insert a drawing shape (rectangle/ellipse/line/textbox) at `ref`; width/height in HWPUNIT.\n" <>
                "• set_columns {op, ref, count, column_type?, same_width?, spacing?}: set the section's multi-column layout — `count` is the NUMBER of columns (2 = two columns / 2단). It applies from `ref`'s paragraph ONWARD, so to make the WHOLE body multi-column, call set_columns at the FIRST body paragraph (section 0, paragraph 0) BEFORE inserting the body text. `same_width?` defaults true; `spacing?` is the inter-column gap in HWPUNIT.",
            "properties" => %{
              "op" => %{
                "type" => "string",
                "enum" =>
                  ~w(insert_text delete_range replace_text insert_paragraph delete_paragraph split merge insert_table insert_table_row delete_table_row insert_table_column delete_table_column merge_cells split_cell delete_node insert_picture set_cell insert_equation insert_footnote insert_endnote insert_shape set_columns)
              },
              "rows" => %{"type" => "integer", "description" => "insert_table: number of rows."},
              "cols" => %{"type" => "integer", "description" => "insert_table: number of columns."},
              "query" => %{"type" => "string", "description" => "replace_text: literal text to find."},
              "replacement" => %{
                "type" => "string",
                "description" => "replace_text: text to substitute in (single paragraph, no newlines). REQUIRED for replace_text."
              },
              "ref" => %{"type" => "string", "description" => "Target element ref (from doc.find). Scopes the edit to that element/paragraph."},
              "all" => %{"type" => "boolean", "description" => "replace_text: replace EVERY match (default false = first match only)."},
              "text" => %{"type" => "string", "description" => "insert_text: text to insert. set_cell: the cell's new content (\\n splits into cell paragraphs)."},
              "at" => %{"type" => "integer", "description" => "char offset within the target paragraph."},
              "count" => %{
                "type" => "integer",
                "description" =>
                  "delete_range: number of chars to delete. set_columns: number of columns."
              },
              "script" => %{
                "type" => "string",
                "description" =>
                  "insert_equation: HWP equation markup (the equation editor's source string), e.g. \"x^2 + y^2 = z^2\" or \"sqrt {a over b}\". REQUIRED for insert_equation."
              },
              "font_size" => %{
                "type" => "integer",
                "description" => "insert_equation: equation font size in HWPUNIT (point×100; 1000 = 10pt). Defaults to 1000."
              },
              "color" => %{
                "type" => "integer",
                "description" => "insert_equation: packed 0xBBGGRR color of the equation (default 0 = black)."
              },
              "shape_type" => %{
                "type" => "string",
                "description" =>
                  "insert_shape: shape kind — \"rectangle\" (default), \"ellipse\", \"line\", or \"textbox\"."
              },
              "width" => %{
                "type" => "integer",
                "description" => "insert_shape: shape width in HWPUNIT (e.g. 8504 ≈ 3cm). REQUIRED for insert_shape."
              },
              "height" => %{
                "type" => "integer",
                "description" => "insert_shape: shape height in HWPUNIT. REQUIRED for insert_shape."
              },
              "x" => %{"type" => "integer", "description" => "insert_shape: horizontal offset (HWPUNIT, default 0)."},
              "y" => %{"type" => "integer", "description" => "insert_shape: vertical offset (HWPUNIT, default 0)."},
              "column_type" => %{
                "type" => "integer",
                "description" => "set_columns: 0=normal (default), 1=distribute, 2=parallel."
              },
              "same_width" => %{
                "type" => "boolean",
                "description" => "set_columns: equal-width columns (default true)."
              },
              "spacing" => %{
                "type" => "integer",
                "description" => "set_columns: inter-column gap in HWPUNIT (default 0)."
              }
            },
            "required" => ["op"]
          },
          "base_revision" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "save",
      "description" => "Persist the document to disk (export).",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"document" => %{"type" => "string"}},
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => false}
    }
  ]

  @doc "The MCP tool catalog for the document abstraction."
  @spec tools() :: [map()]
  def tools, do: @tools

  @doc "Canonical `namespace.name` for each tool."
  @spec tool_names() :: [String.t()]
  def tool_names, do: Enum.map(@tools, &(&1["namespace"] <> "." <> &1["name"]))

  @doc """
  Dispatch an MCP tool call.

  `ctx` is `%{pool: pool}` (global, pre-isolation) or the per-agent form
  `%{pool: pool, agent_id: id, active_doc: doc_id}` (design invariant 3 — see the
  module doc for the per-agent open/ownership semantics).
  """
  @spec call(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx \\ %{}, tool_name, args)

  def call(ctx, "doc.context", _args) do
    {:ok, context_json(ctx)}
  end

  def call(ctx, "doc.list", _args) do
    {:ok, %{"documents" => Enum.map(Pool.list(pool(ctx)), &entry_json/1)}}
  end

  def call(ctx, "doc.open", args) do
    with {:ok, path} <- require_string(args, "path") do
      kind = args |> get(["kind"]) |> normalize_kind()
      open_opts = args |> get(["open_opts"]) |> List.wrap()

      # Invariant 1 ("one doc = one live model"): in an agent context, opening a
      # doc that is ALREADY open FAILS with `already_open` + who holds it, instead
      # of the legacy reuse — the agent references the existing id rather than
      # grabbing a second handle. The pre-flight check uses the Pool's stable,
      # path/kind-derived id, so it is decided BEFORE Pool.open (which would
      # otherwise reuse). A bare pool-only context keeps the legacy reuse.
      case open_preflight(ctx, path, kind) do
        :ok ->
          do_open_tool(ctx, path, kind, open_opts)

        {:error, structured} ->
          {:error, structured}
      end
    end
  end

  def call(ctx, "doc.create", args) do
    with {:ok, path} <- require_string(args, "path") do
      kind = args |> get(["kind"]) |> normalize_kind()

      case get(args, ["from"]) do
        nil -> create_blank(ctx, path, kind)
        from when is_binary(from) and from != "" -> create_from(ctx, path, kind, from)
        _ -> {:error, error_json({:invalid_params, "from must be a non-empty string"})}
      end
    end
  end

  def call(ctx, "doc.read", args) do
    route_doc(ctx, args,
      browser: fn lv -> browser_call(lv, args, :read, %{opts: take_opts(args, ["at", "size", "ref"])}) end,
      server: fn editor ->
        opts = take_opts(args, ["at", "size", "ref"])
        # Keep the windowed-text contract (≤#{@read_cap} paragraphs + cursor) and
        # ADDITIVELY enrich it with the full-IR element list (incl. per-cell
        # `context`) when the NIF `elements` verb is available — so a read surfaces
        # tables/cells/pictures/fields in the window, not just flat text. An older
        # NIF (no elements verb) simply omits `elements`.
        wrap(Editor.read(editor, opts), fn result ->
          result |> stringify() |> attach_read_elements(editor)
        end)
      end
    )
  end

  def call(ctx, "doc.find", args) do
    all = get(args, ["all"]) || false
    regex = get(args, ["regex"]) || false
    type = get(args, ["type"])

    # `pattern` is required for a literal search, but optional in discovery mode
    # (`all`/`regex`/`type`): {all:true} or {type:"empty_cell"} with no pattern
    # enumerates by structure, so default to "" rather than hard-failing.
    with {:ok, pattern} <- find_pattern(args, all || regex || (is_binary(type) and type != "")) do
      route_doc(ctx, args,
        browser: fn lv ->
          browser_call(lv, args, :find, %{
            pattern: pattern,
            case_sensitive: get(args, ["case_sensitive"]) || false,
            all: all,
            regex: regex,
            type: type
          })
        end,
        server: fn editor -> server_find(editor, pattern, type, args) end
      )
    end
  end

  # doc.get inspects a ref: its element type, current property VALUES, the
  # settable property NAMES (the native-property vocabulary), and child refs.
  # This folds the former standalone `doc.inspect` into the one read-properties
  # tool, so the agent has a single place to discover what it can set and what
  # the current values are.
  # `refs:[...]` (batch) takes precedence over `ref` (single). Server-only
  # (with_editor): inspect each ref best-effort and return a per-ref `results`.
  def call(ctx, "doc.get", args) do
    props = get(args, ["props"])

    case get(args, ["refs"]) do
      refs when is_list(refs) ->
        with_editor(ctx, args, fn editor ->
          results =
            Enum.map(refs, fn ref ->
              case inspect_one(editor, ref, props) do
                {:ok, info} -> Map.put(info, "ref", ref)
                {:error, err} -> %{"ref" => ref, "error" => err}
              end
            end)

          {:ok, %{"results" => results}}
        end)

      _ ->
        with {:ok, ref} <- require_string(args, "ref") do
          with_editor(ctx, args, fn editor ->
            case inspect_one(editor, ref, props) do
              {:ok, info} -> {:ok, info}
              {:error, err} -> {:error, err}
            end
          end)
        end
    end
  end

  # `sets:[{ref,props}, ...]` (batch) takes precedence over `ref`+`props` (single).
  def call(ctx, "doc.set", args) do
    base_rev = get(args, ["base_revision"])

    case get(args, ["sets"]) do
      sets when is_list(sets) ->
        # Batch form: set many elements in one call, best-effort per-set result.
        route_doc(ctx, args,
          browser: fn lv -> browser_set_batch(lv, args, sets) end,
          server: fn editor -> set_batch_server(editor, sets, base_rev) end
        )

      _ ->
        with {:ok, ref} <- require_string(args, "ref"),
             {:ok, props} <- require_map(args, "props") do
          route_doc(ctx, args,
            # Viewed-HWP authority is the browser WASM model (design §6.2): deliver the
            # property set to the owning LiveView -> WasmHwpEditor applies it
            # (setCellProperties / applyCharFormat) so the change RENDERS in the viewer.
            # A server-NIF set would mutate the unedited server copy the user never
            # sees — invisible — so set MUST route to the browser for an open doc.
            browser: fn lv -> browser_set(lv, args, ref, props) end,
            server: fn editor -> write_result(Editor.set(editor, ref, props, base_rev)) end
          )
        end
    end
  end

  # `ops:[...]` (batch) takes precedence over `op` (single) when present.
  def call(ctx, "doc.edit", args) do
    base_rev = get(args, ["base_revision"])

    # Invariant 2 ("one agent per doc"): in an agent context, editing a doc owned
    # by a DIFFERENT agent is :forbidden. An UNOWNED doc (e.g. the human-opened
    # viewed HWP) is editable and is lazily claimed by this agent on first edit,
    # so the common single-agent flow keeps working while a 2nd agent is fenced
    # out. A bare pool-only context skips the check entirely.
    with {:ok, document} <- require_string(args, "document"),
         :ok <- enforce_ownership(ctx, document) do
      do_edit(ctx, args, base_rev)
    end
  end

  def call(ctx, "doc.save", args) do
    with {:ok, document} <- require_string(args, "document"),
         {:ok, info} <- Pool.info(pool(ctx), document) do
      path = get(args, ["path"]) || info.path

      route_doc(ctx, args,
        # Open doc: the browser WASM model is authority — export ITS edited bytes
        # and write them to disk (the server Editor copy is unedited).
        browser: fn lv -> save_browser(lv, args, path) end,
        # Headless doc: the NIF holds the edits — export via Ehwp + write.
        server: fn editor -> save_server(editor, info, path) end
      )
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(_ctx, tool_name, _args), do: {:error, {:unknown_tool, tool_name}}

  # --- doc.edit dispatch (after the ownership gate) ------------------------

  defp do_edit(ctx, args, base_rev) do
    case get(args, ["ops"]) do
      ops when is_list(ops) ->
        # Batch form: apply many edits in one call, best-effort with a per-op
        # result. Each op is normalised per-op for the browser payload (same as
        # the single path), so a malformed op is rejected individually.
        route_doc(ctx, args,
          browser: fn lv -> browser_write_batch(lv, args, ops) end,
          server: fn editor -> edit_batch_server(editor, ops, base_rev) end
        )

      _ ->
        with {:ok, op} <- require_map(args, "op") do
          route_doc(ctx, args,
            # Viewed-HWP authority is the browser WASM model: deliver the structural
            # edit to the owning LiveView -> WasmHwpEditor hook applies it to the rhwp
            # WASM doc and reports the new revision. We do NOT touch the server NIF
            # for a browser-backed doc (design §6.2) so the two models can't diverge.
            browser: fn lv -> browser_write(lv, args, op) end,
            server: fn editor -> write_result(Editor.apply(editor, op, base_rev)) end
          )
        end
    end
  end

  # --- doc.open helpers (per-agent open + ownership) -----------------------

  # Decide whether `path`/`kind` may be opened in THIS context.
  #   * Bare pool-only context → :ok (legacy reuse path; no isolation).
  #   * Agent context, doc NOT open → :ok (it will be opened + owned).
  #   * Agent context, doc ALREADY open → {:error, already_open} naming who holds
  #     it (this agent / another agent / a human viewer), so the agent references
  #     the existing id instead of grabbing a second handle (invariant 1).
  defp open_preflight(%{agent_id: agent_id} = ctx, path, kind) do
    pool = pool(ctx)
    doc_id = Pool.document_id_for(path, kind)

    if document_open?(pool, doc_id) do
      {:error, already_open_json(pool, doc_id, agent_id)}
    else
      :ok
    end
  end

  defp open_preflight(_ctx, _path, _kind), do: :ok

  # Open the doc in the Pool and, in an agent context, claim ownership for the
  # calling agent + make it the agent's active doc context. A pool-only context
  # opens without ownership (legacy).
  defp do_open_tool(ctx, path, kind, open_opts) do
    case Pool.open(pool(ctx), path, kind: kind, open_opts: open_opts) do
      {:ok, doc_id} ->
        _ = maybe_claim_owner(ctx, doc_id)
        {:ok, %{"document" => doc_id, "kind" => Atom.to_string(kind)}}

      {:error, reason} ->
        {:error, error_json(reason)}
    end
  end

  # A doc is "open" iff the Pool has a live model for it (route resolves to a
  # server editor or an alive browser viewer).
  defp document_open?(pool, doc_id) do
    case Pool.route(pool, doc_id) do
      {:error, :not_found} -> false
      _ -> true
    end
  end

  # The `already_open` structured error: the existing document id + who holds it.
  # held_by is `self` (this agent already owns it), `{:agent, id}` (another
  # agent), or `:viewer` (a human-viewed/browser-backed doc with no agent owner).
  defp already_open_json(pool, doc_id, agent_id) do
    %{
      "error" => "already_open",
      "document" => doc_id,
      "held_by" => held_by(pool, doc_id, agent_id)
    }
  end

  defp held_by(pool, doc_id, agent_id) do
    case Pool.owner(pool, doc_id) do
      ^agent_id ->
        %{"kind" => "self", "agent_id" => agent_id}

      owner when is_binary(owner) ->
        %{"kind" => "agent", "agent_id" => owner}

      nil ->
        case Pool.route(pool, doc_id) do
          {:browser, _lv} -> %{"kind" => "viewer"}
          _ -> %{"kind" => "unowned"}
        end
    end
  end

  defp maybe_claim_owner(%{agent_id: agent_id} = ctx, doc_id) when is_binary(agent_id),
    do: Pool.claim_owner(pool(ctx), doc_id, agent_id)

  defp maybe_claim_owner(_ctx, _doc_id), do: :ok

  # --- doc.edit ownership enforcement (invariant 2) ------------------------

  # In an agent context, gate a write on ownership. `claim_owner` is the single
  # authoritative arbiter (it succeeds for the current owner OR an unowned doc,
  # and fails only when ANOTHER agent owns it), so this both enforces the fence
  # AND lazily claims an unowned doc for the editing agent. A bare pool-only
  # context (no agent_id) skips ownership entirely.
  defp enforce_ownership(%{agent_id: agent_id} = ctx, document) when is_binary(agent_id) do
    case Pool.claim_owner(pool(ctx), document, agent_id) do
      :ok ->
        :ok

      {:error, {:owned, owner}} ->
        {:error,
         %{"error" => "forbidden", "document" => document, "owned_by" => %{"agent_id" => owner}}}
    end
  end

  defp enforce_ownership(_ctx, _document), do: :ok

  # --- doc.create helpers --------------------------------------------------

  # doc.create without `from`: a blank engine template whose save target is `path`.
  defp create_blank(ctx, path, kind) do
    case Pool.create(pool(ctx), path, kind: kind) do
      {:ok, doc_id} ->
        _ = Pool.set_active(pool(ctx), doc_id)
        _ = maybe_claim_owner(ctx, doc_id)
        {:ok, %{"document" => doc_id, "kind" => Atom.to_string(kind)}}

      {:error, reason} ->
        {:error, error_json(reason)}
    end
  end

  # doc.create WITH `from`: CLONE a template. Resolve `from` (an open document id OR
  # a file path) to a source path, byte-copy it to `path` (so the clone inherits
  # EVERY bit of the template's formatting), then open the copy as an editable doc
  # whose save target is `path`. The agent then REPLACES content cell-by-cell.
  defp create_from(ctx, path, kind, from) do
    with {:ok, source} <- resolve_template_path(ctx, from),
         :ok <- copy_template(source, path) do
      # The template was byte-copied to `path`, so a NEW file now exists on disk
      # — announce it so the workspace tree shows it without a manual refresh.
      broadcast_file_written(path)

      case Pool.open(pool(ctx), path, kind: kind) do
        {:ok, doc_id} ->
          _ = Pool.set_active(pool(ctx), doc_id)
          _ = maybe_claim_owner(ctx, doc_id)
          {:ok, %{"document" => doc_id, "kind" => Atom.to_string(kind), "cloned_from" => source}}

        {:error, reason} ->
          {:error, error_json(reason)}
      end
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  # `from` may be an open document id (look its path up in the Pool) or a file path.
  defp resolve_template_path(ctx, from) do
    case Pool.info(pool(ctx), from) do
      {:ok, %{path: source}} when is_binary(source) and source != "" ->
        {:ok, source}

      _ ->
        if File.regular?(from),
          do: {:ok, from},
          else: {:error, {:template_not_found, from}}
    end
  end

  defp copy_template(source, path) do
    with :ok <- ensure_parent_dir(path),
         :ok <- File.cp(source, path) do
      :ok
    else
      {:error, reason} -> {:error, {:clone_failed, reason}}
    end
  end

  defp ensure_parent_dir(path) do
    case path |> Path.dirname() |> File.mkdir_p() do
      :ok -> :ok
      {:error, reason} -> {:error, {:clone_failed, reason}}
    end
  end

  # --- doc.read / doc.find server arms -------------------------------------

  # Layer the enumerated elements onto a read result when available. The text
  # window/cap is unchanged; we just add an `elements` array so the agent sees
  # structured content (tables/cells/pictures/fields, with per-cell `context`)
  # alongside text. Best-effort: an older NIF (no elements verb) omits it.
  defp attach_read_elements(read, editor) do
    case Editor.elements(editor) do
      {:ok, nodes} when is_list(nodes) ->
        Map.put(read, "elements", Enum.map(nodes, &element_to_match/1))

      _ ->
        read
    end
  end

  # Server-arm `doc.find`. Enumerate the full IR via the NIF `elements` verb and
  # filter by `type` and/or `pattern` (so each match carries its IR type, row/col
  # and per-cell `context`). If the verb is unavailable (older NIF) FALL BACK to
  # the literal `Editor.find`.
  defp server_find(editor, pattern, type, args) do
    case maybe_elements(editor, type) do
      {:ok, nodes} ->
        matches =
          nodes
          |> filter_by_type(type)
          |> filter_by_pattern(pattern, find_case_sensitive?(args))
          |> Enum.map(&element_to_match/1)

        {:ok, %{"pattern" => pattern, "type" => type, "matches" => matches}}

      :fallback ->
        literal_find(editor, pattern, args)
    end
  end

  # Try the full-IR enumerator. `:fallback` signals the verb is unavailable so the
  # caller uses literal find.
  defp maybe_elements(editor, _type) do
    case Editor.elements(editor) do
      {:ok, nodes} when is_list(nodes) -> {:ok, nodes}
      {:error, {:not_supported, _}} -> :fallback
      {:error, _other} -> :fallback
    end
  end

  defp literal_find(editor, pattern, args) when is_binary(pattern) and pattern != "" do
    case Editor.find(editor, pattern, take_opts(args, ["case_sensitive"])) do
      {:ok, matches} -> {:ok, %{"pattern" => pattern, "matches" => Enum.map(matches, &stringify/1)}}
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  # `type`-only query but the NIF can't enumerate: be honest rather than dumping
  # everything.
  defp literal_find(_editor, _pattern, _args),
    do: {:error, error_json({:not_supported, "element-type find needs the NIF elements verb"})}

  # Filter enumerator nodes by IR `type`. The cell-state filters (empty_cell/
  # filled_cell/empty) map onto the enumerator's `cell` shape + text; any other
  # type matches the node's own IR kind; nil/"" keeps everything.
  defp filter_by_type(nodes, nil), do: nodes
  defp filter_by_type(nodes, ""), do: nodes
  defp filter_by_type(nodes, "empty"), do: Enum.filter(nodes, &blank_node_text?/1)

  defp filter_by_type(nodes, "empty_cell"),
    do: Enum.filter(nodes, &(node_type(&1) == "cell" and blank_node_text?(&1)))

  defp filter_by_type(nodes, "filled_cell"),
    do: Enum.filter(nodes, &(node_type(&1) == "cell" and not blank_node_text?(&1)))

  defp filter_by_type(nodes, type) when is_binary(type),
    do: Enum.filter(nodes, &(node_type(&1) == type))

  defp filter_by_pattern(nodes, nil, _cs), do: nodes
  defp filter_by_pattern(nodes, "", _cs), do: nodes

  defp filter_by_pattern(nodes, pattern, case_sensitive?) do
    needle = if case_sensitive?, do: pattern, else: String.downcase(pattern)

    Enum.filter(nodes, fn node ->
      text = node_text(node)
      hay = if case_sensitive?, do: text, else: String.downcase(text)
      String.contains?(hay, needle)
    end)
  end

  # Project an enumerator node into the doc.find match shape: ref/text/type plus
  # row/col and the per-cell `context` breadcrumb when present.
  defp element_to_match(node) do
    %{
      "ref" => node_field(node, "ref"),
      "text" => node_text(node),
      "type" => node_type(node)
    }
    |> maybe_put("row", node_field(node, "row"))
    |> maybe_put("col", node_field(node, "col"))
    |> maybe_put("context", node_field(node, "context"))
  end

  defp node_type(node), do: node_field(node, "type")
  defp node_text(node), do: node_field(node, "text") || ""
  defp blank_node_text?(node), do: String.trim(node_text(node)) == ""

  # Enumerator nodes are JSON-decoded (string keys); tolerate atom keys too.
  defp node_field(node, key) when is_map(node) do
    case Map.fetch(node, key) do
      {:ok, v} -> v
      :error -> Map.get(node, safe_existing_atom(key))
    end
  end

  defp node_field(_node, _key), do: nil

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp find_case_sensitive?(args), do: get(args, ["case_sensitive"]) == true

  # --- dispatch helpers ----------------------------------------------------

  # Route a tool against a document whose authority may be the server NIF
  # (`:server`) OR the browser WASM model (`:browser`, a doc open in a viewer).
  # `opts` carries `:browser` and `:server` closures; the right one runs based on
  # `Pool.route/2`. Tools that the browser hook can apply (read/find/edit) pass
  # both; server-only tools use `with_editor/3` (which falls back to the server
  # editor even for browser-backed docs — the structure is identical on open).
  defp route_doc(ctx, args, opts) do
    with {:ok, document} <- require_string(args, "document") do
      case Pool.route(pool(ctx), document) do
        {:browser, lv} -> Keyword.fetch!(opts, :browser).(lv)
        {:server, editor} -> Keyword.fetch!(opts, :server).(editor)
        {:error, :not_found} -> {:error, error_json(:not_found)}
      end
    end
  end

  # For a browser-backed doc, deliver a structural edit op to the owning LiveView
  # and wait for the WASM apply to report the resulting revision (design §6.2).
  # The op is normalised first (validated verb, string keys) so the browser hook
  # always receives a well-formed `{"op": "<verb>", ...}` regardless of how the
  # agent keyed the map.
  defp browser_write(lv, args, op) do
    with {:ok, normalized} <- normalize_browser_op(op) do
      do_browser_write(lv, args, normalized)
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  # Re-key the validated op back to JSON string keys (Op.normalize atomises it).
  defp normalize_browser_op(op) do
    case Ecrits.Doc.Op.normalize(op) do
      {:ok, atom_op} -> {:ok, Map.new(atom_op, fn {k, v} -> {to_string(k), v} end)}
      {:error, _reason} = error -> error
    end
  end

  defp do_browser_write(lv, args, op) do
    case browser_call(lv, args, :edit, %{op: op, base_revision: get(args, ["base_revision"])}) do
      {:ok, %{} = applied} ->
        {:ok,
         %{"ok" => true, "revision" => Map.get(applied, "revision") || Map.get(applied, :revision)}
         |> maybe_put("replaced", Map.get(applied, "replaced") || Map.get(applied, :replaced))}

      {:error, _reason} = error ->
        error
    end
  end

  # Batch doc.edit for a browser-backed doc: normalise EACH op (per-op, like the
  # single path) then hand the whole `ops` array to the WASM hook's
  # applyAgentEditBatch in ONE round-trip. A normalisation failure for one op is
  # recorded as that op's result (it is NOT sent to the browser) so the rest still
  # apply. The hook applies body index-shifting ops in reverse document order and
  # cell ops order-independently, then finishes (re-renders) once.
  defp browser_write_batch(lv, args, ops) do
    # Split the ops into the ones that normalise cleanly (sent to the browser) and
    # the ones that don't (recorded as local failures), preserving order metadata
    # so the merged result keeps every op accounted for.
    {ok_ops, bad_results} =
      ops
      |> Enum.map(fn op ->
        case normalize_browser_op(op) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, reason} -> {:error, %{"ref" => op_ref(op), "error" => error_json(reason)}}
        end
      end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    normalized_ops = Enum.map(ok_ops, fn {:ok, op} -> op end)
    local_failures = Enum.map(bad_results, fn {:error, res} -> res end)

    case browser_call(lv, args, :edit, %{ops: normalized_ops, base_revision: get(args, ["base_revision"])}) do
      {:ok, %{} = applied} ->
        {:ok, merge_browser_batch(applied, local_failures)}

      {:error, _reason} = error ->
        error
    end
  end

  # Merge the browser's batch result with any locally-rejected (un-normalisable)
  # ops so `failed`/`results` account for EVERY op the agent submitted.
  defp merge_browser_batch(applied, local_failures) do
    results = (Map.get(applied, "results") || Map.get(applied, :results) || []) ++ local_failures
    applied_n = Map.get(applied, "applied") || Map.get(applied, :applied) || 0
    failed_n = (Map.get(applied, "failed") || Map.get(applied, :failed) || 0) + length(local_failures)
    revision = Map.get(applied, "revision") || Map.get(applied, :revision)

    batch_result(results, applied_n, failed_n, revision)
  end

  # doc.set for a browser-backed doc: deliver the property set to the viewer's
  # authoritative WASM model and adopt the revision it reports. The ref (doc.find's
  # positional ref, incl. cell address) is parsed browser-side by the SAME parseRef
  # the edit verbs use, so there is no ref-format round-trip mismatch with the
  # server `hwp:` grammar — the reason a server-routed set rejected find's ref.
  defp browser_set(lv, args, ref, props) do
    case browser_call(lv, args, :set, %{ref: ref, props: props}) do
      {:ok, %{} = applied} ->
        {:ok, %{"ok" => true, "revision" => Map.get(applied, "revision") || Map.get(applied, :revision)}}

      {:error, _reason} = error ->
        error
    end
  end

  # Batch doc.set for a browser-backed doc: hand the `sets` array to the hook's
  # applyAgentSetBatch in ONE round-trip (each set addresses a fixed cell/run, so
  # order is irrelevant). The hook applies all of them best-effort and finishes
  # (re-renders) once, returning {applied, failed, results, revision}.
  defp browser_set_batch(lv, args, sets) do
    case browser_call(lv, args, :set, %{sets: sets, base_revision: get(args, ["base_revision"])}) do
      {:ok, %{} = applied} ->
        {:ok, merge_browser_batch(applied, [])}

      {:error, _reason} = error ->
        error
    end
  end

  # doc.save for an open (browser) doc: round-trip the viewer for its current
  # edited bytes, then write them to `path`.
  defp save_browser(lv, args, path) do
    case browser_call(lv, args, :save, %{}) do
      {:ok, %{} = res} ->
        b64 = res["bytes_base64"] || res[:bytes_base64]

        with true <- is_binary(b64) or {:error, {:save_failed, "viewer returned no bytes"}},
             {:ok, bytes} <- Base.decode64(b64),
             :ok <- File.write(path, bytes) do
          broadcast_file_written(path)
          {:ok, %{"ok" => true, "path" => path, "bytes" => byte_size(bytes)}}
        else
          :error -> {:error, error_json({:save_failed, "viewer returned invalid base64"})}
          {:error, reason} -> {:error, error_json(reason)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # doc.save for a headless (server NIF) doc: Ehwp.export + write, via the Editor.
  defp save_server(editor, info, path) do
    case Editor.save(editor, format: save_format(info.kind), path: path) do
      :ok ->
        broadcast_file_written(path)
        {:ok, %{"ok" => true, "path" => path}}

      {:ok, %{} = saved} ->
        broadcast_file_written(path)
        {:ok, Map.merge(%{"ok" => true, "path" => path}, stringify(saved))}

      {:error, reason} ->
        {:error, error_json(reason)}
    end
  end

  # Announce a successful agent file-write so any workspace LiveView whose root
  # contains `path` refreshes its file tree. Best-effort and fire-and-forget:
  # broadcast never raises in practice, but we guard so a PubSub hiccup can never
  # fail the write the agent just completed.
  defp broadcast_file_written(path) when is_binary(path) and path != "" do
    abs_path = Path.expand(path)

    _ =
      Phoenix.PubSub.broadcast(
        @workspace_files_pubsub,
        @workspace_files_topic,
        {:workspace_file_written, abs_path}
      )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp broadcast_file_written(_path), do: :ok

  defp save_format(:hwpx), do: :hwpx
  defp save_format(:docx), do: :docx
  defp save_format(:pptx), do: :pptx
  defp save_format(_kind), do: :hwp

  # Synchronous request/reply against the viewing LiveView. The LiveView's
  # `{:doc_browser_request, ...}` handler pushes the op to the WasmHwpEditor hook,
  # the hook applies it to the WASM model and replies, and the LiveView relays the
  # result back to us as `{:doc_browser_reply, ref, result}`. Runs in the agent's
  # MCP process (NOT the LiveView), so we use a tagged send + selective receive.
  defp browser_call(lv, _args, verb, payload) when is_pid(lv) do
    ref = make_ref()
    send(lv, {:doc_browser_request, self(), ref, verb, payload})

    receive do
      {:doc_browser_reply, ^ref, {:ok, result}} -> {:ok, stringify(result)}
      {:doc_browser_reply, ^ref, {:error, reason}} -> {:error, error_json(reason)}
    after
      @browser_timeout_ms ->
        {:error, error_json({:browser_timeout, "viewer did not apply the edit in time"})}
    end
  end

  defp with_editor(ctx, args, fun) do
    with {:ok, document} <- require_string(args, "document") do
      case Pool.route(pool(ctx), document) do
        {:server, editor} ->
          fun.(editor)

        {:browser, _lv} ->
          # Browser-backed doc, but this tool (inspect/get/set/style/save)
          # has no browser apply yet. The server Editor still holds the document
          # (identical structure on open), so serve these read/meta verbs from it.
          case Pool.with_doc(pool(ctx), document, fun) do
            {:error, :not_found} -> {:error, error_json(:not_found)}
            other -> other
          end

        {:error, :not_found} ->
          {:error, error_json(:not_found)}
      end
    end
  end

  defp write_result({:ok, applied}) do
    {:ok,
     %{"ok" => true, "revision" => Map.get(applied, :revision)}
     |> maybe_put("invalidated", Map.get(applied, :invalidated))
     |> maybe_put("rebased", Map.get(applied, :rebased))
     # Native engine result (e.g. insert_table returns {paraIdx, controlIdx} —
     # the agent needs it to address the new table's cells with a follow-up edit).
     |> maybe_put("native", Map.get(applied, :native))}
  end

  defp write_result({:error, {:conflict, current_revision, snapshot}}) do
    {:error,
     %{
       "conflict" => true,
       "current_revision" => current_revision,
       "snapshot" => stringify(snapshot)
     }}
  end

  defp write_result({:error, reason}), do: {:error, error_json(reason)}

  defp wrap({:ok, value}, mapper) when is_function(mapper, 1), do: {:ok, mapper.(value)}
  defp wrap({:error, reason}, _mapper), do: {:error, error_json(reason)}

  # Inspect ONE ref for doc.get (single + batch share this). Reflective metadata
  # (type + settable property NAMES + child refs) anchors the result; live
  # property VALUES are best-effort layered on top. Returns {:ok, info_map} (the
  # merged shape) or {:error, error_json} so the batch can collect per-ref errors
  # without aborting the others.
  defp inspect_one(editor, ref, props) do
    case Editor.inspect_element(editor, ref) do
      {:ok, meta} ->
        values = best_effort_values(editor, ref, props)
        {:ok, merge_get_inspect(values, stringify(meta))}

      {:error, reason} ->
        {:error, error_json(reason)}
    end
  end

  # Server-arm batch doc.edit: apply each op via Editor.apply best-effort, collect
  # per-op results, return the same shape the browser batch does. base_revision is
  # passed unchanged to every op (the engine rebases internally); a per-op failure
  # is recorded but does NOT abort the rest. `revision` is the LAST applied op's
  # revision (or the conflict's current revision), so the agent learns where it
  # landed.
  defp edit_batch_server(editor, ops, base_rev) do
    {results, applied, failed, last_rev} =
      Enum.reduce(ops, {[], 0, 0, nil}, fn op, {acc, ok_n, bad_n, rev} ->
        op_ref = op_ref(op)

        case Editor.apply(editor, op, base_rev) do
          {:ok, applied_map} ->
            new_rev = Map.get(applied_map, :revision) || rev
            {[%{"ref" => op_ref, "ok" => true} | acc], ok_n + 1, bad_n, new_rev}

          {:error, reason} ->
            {[%{"ref" => op_ref, "error" => error_json(reason)} | acc], ok_n, bad_n + 1, rev}
        end
      end)

    {:ok, batch_result(Enum.reverse(results), applied, failed, last_rev)}
  end

  # Server-arm batch doc.set: apply each {ref, props} via Editor.set best-effort.
  defp set_batch_server(editor, sets, base_rev) do
    {results, applied, failed, last_rev} =
      Enum.reduce(sets, {[], 0, 0, nil}, fn entry, {acc, ok_n, bad_n, rev} ->
        ref = get(entry, ["ref"])
        props = get(entry, ["props"])

        case set_one_server(editor, ref, props, base_rev) do
          {:ok, applied_map} ->
            new_rev = Map.get(applied_map, :revision) || rev
            {[%{"ref" => ref, "ok" => true} | acc], ok_n + 1, bad_n, new_rev}

          {:error, reason} ->
            {[%{"ref" => ref, "error" => error_json(reason)} | acc], ok_n, bad_n + 1, rev}
        end
      end)

    {:ok, batch_result(Enum.reverse(results), applied, failed, last_rev)}
  end

  # One server set with the same ref/props validation the single path uses, so a
  # malformed entry in the batch is an :invalid_params error for THAT entry only.
  defp set_one_server(_editor, ref, _props, _base_rev) when not is_binary(ref) or ref == "",
    do: {:error, {:invalid_params, "ref (non-empty string) is required"}}

  defp set_one_server(_editor, _ref, props, _base_rev) when not is_map(props),
    do: {:error, {:invalid_params, "props (object) is required"}}

  defp set_one_server(editor, ref, props, base_rev), do: Editor.set(editor, ref, props, base_rev)

  # The ref carried on an op (for the per-op result label); nil when absent.
  defp op_ref(op) when is_map(op), do: get(op, ["ref"])
  defp op_ref(_op), do: nil

  # The shared best-effort batch result shape (browser + server use it):
  # `applied`/`failed` counts, the per-op `results`, and the landing `revision`.
  defp batch_result(results, applied, failed, revision) do
    %{"ok" => true, "applied" => applied, "failed" => failed, "results" => results}
    |> maybe_put("revision", revision)
  end

  # Live property values for doc.get, best-effort: nil when the engine can't read
  # them yet, so the reflective discovery still stands.
  defp best_effort_values(editor, ref, props) do
    case Editor.get(editor, ref, props) do
      {:ok, values} -> stringify(values)
      {:error, _reason} -> nil
    end
  end

  # Combine the property VALUES (from get) with the reflective metadata (type,
  # settable property NAMES, child refs) into the one doc.get result. `values`
  # are the live readings (nil when unreadable); `settable` is the native-prop
  # vocabulary; `properties` keeps the values map so existing callers still find
  # it.
  defp merge_get_inspect(values, meta) do
    %{
      "ref" => meta["ref"],
      "type" => meta["type"],
      "kind" => meta["kind"],
      "interfaces" => meta["interfaces"],
      "values" => values,
      "properties" => values,
      "settable" => meta["properties"],
      "children" => meta["children"] || []
    }
  end

  # Active/focused document + cursor/selection. The active document is the one
  # the user is viewing in the workspace: `WorkspaceLive` registers the open
  # document in the Pool and marks it active via `Pool.set_active/2` (and clears
  # it via `Pool.clear_active/2` when the doc is closed or a non-pooled doc like
  # Markdown is opened), so we read it back here with `Pool.active/1`.
  #
  # We resolve ONLY the explicitly-set active doc — no "first browser-backed" or
  # "sole doc" guessing. Those heuristics resurrected stale Pool entries: after
  # closing the doc (or opening a Markdown file, which has no Pool backend) the
  # active marker is nil but old hwp entries linger in the pool, so a guess would
  # wrongly report an hwp as "currently open". When nothing is active,
  # `active_document` is nil — the agent must create/open a doc rather than edit a
  # phantom.
  #
  # The `cursor`/`selection` refs still require browser->server caret reporting
  # (editors, owned separately) and remain null for now.
  defp context_json(ctx) do
    pool = pool(ctx)
    docs = Pool.list(pool)
    active_id = active_doc_id(ctx, pool)
    active = active_id && Enum.find(docs, &(&1.id == active_id))

    %{
      "active_document" => active && active.id,
      "cursor" => nil,
      "selection" => nil,
      "cursor_reporting" => "todo:browser_wiring",
      "documents" => Enum.map(docs, &entry_json/1)
    }
  end

  # The active doc for THIS call: in an agent context (the ctx carries an
  # `:agent_id`, design invariant 3) it is the agent's OWN active doc
  # (`ctx.active_doc`), so two agents never see each other's. In a bare
  # pool-only context (legacy bare MCP mount, or a direct `Tools.call(%{pool:
  # …}, …)` from a test) it falls back to the global `Pool.active`.
  defp active_doc_id(%{agent_id: _} = ctx, _pool), do: Map.get(ctx, :active_doc)
  defp active_doc_id(_ctx, pool), do: Pool.active(pool)

  defp error_json({:not_supported, reason}),
    do: %{"not_supported" => true, "reason" => to_string(reason)}

  defp error_json({:stale_revision, details}),
    do: %{"error" => "stale_revision", "details" => stringify_kw(details)}

  defp error_json(:not_found), do: %{"error" => "not_found"}

  defp error_json({:unsupported_kind, kind}),
    do: %{"error" => "unsupported_kind", "kind" => to_string(kind)}

  defp error_json({:template_not_found, from}),
    do: %{"error" => "template_not_found", "from" => from}

  defp error_json({:clone_failed, reason}),
    do: %{"error" => "clone_failed", "reason" => inspect(reason)}

  defp error_json(reason) when is_atom(reason), do: %{"error" => to_string(reason)}
  defp error_json(reason), do: %{"error" => inspect(reason)}

  defp entry_json(%{} = entry) do
    %{
      "document" => entry.id,
      "kind" => to_string(entry.kind),
      "path" => entry.path,
      "revision" => entry.revision,
      "backing" => to_string(entry.backing)
    }
  end

  defp pool(ctx), do: Map.get(ctx, :pool, Ecrits.Doc.Pool)

  defp get(args, keys), do: get_in_args(args, keys)

  defp get_in_args(args, [key]) do
    Map.get(args, key, Map.get(args, to_string(key)))
  end

  defp take_opts(args, keys) do
    keys
    |> Enum.flat_map(fn key ->
      case get(args, [key]) do
        nil -> []
        value -> [{String.to_atom(key), value}]
      end
    end)
  end

  defp require_string(args, key) do
    case get(args, [key]) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_params, "#{key} (non-empty string) is required"}}
    end
  end

  # doc.find: in discovery mode (`all`/`regex`) an empty/missing pattern is valid
  # (matches everything, including empty cells); a literal search still requires
  # a non-empty pattern.
  defp find_pattern(args, true), do: {:ok, get_string_or_empty(args, "pattern")}
  defp find_pattern(args, false), do: require_string(args, "pattern")

  defp get_string_or_empty(args, key) do
    case get(args, [key]) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp require_map(args, key) do
    case get(args, [key]) do
      %{} = value -> {:ok, value}
      _ -> {:error, {:invalid_params, "#{key} (object) is required"}}
    end
  end

  defp normalize_kind("hwpx"), do: :hwpx
  defp normalize_kind("hwp"), do: :hwp
  defp normalize_kind("docx"), do: :docx
  defp normalize_kind("pptx"), do: :pptx
  defp normalize_kind(:hwpx), do: :hwpx
  defp normalize_kind(:docx), do: :docx
  defp normalize_kind(:pptx), do: :pptx
  defp normalize_kind(_other), do: :hwp

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp stringify_kw(kw) when is_list(kw),
    do: Map.new(kw, fn {k, v} -> {to_string(k), v} end)

  defp stringify_kw(other), do: other
end
