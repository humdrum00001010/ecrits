defmodule Ecrits.Doc.Tools do
  @moduledoc """
  Reflective MCP tool surface for the document-editing abstraction (design §4.4).

  A *small* set of generic, document-addressed tools — every tool takes a
  `document` id and operates on that document (not just the one being viewed):

  | tool             | risk  | maps to |
  |------------------|-------|---------|
  | `doc.context`    | read  | current document metadata |
  | `doc.list`       | read  | `Pool.list/1` |
  | `doc.open`       | read  | `Pool.open/3` |
  | `doc.create`     | write | `Pool.create/3` (blank template) |
  | `doc.read`       | read  | one `doc.find` ref -> nearby structural context |
  | `doc.find`       | read  | `Editor.find/3` |
  | `doc.get`        | read  | `Editor.get/3` + `Editor.inspect_element/2` (type/values/settable/children) |
  | `doc.set`        | write | `Editor.set/3` — UNIVERSAL property setter |
  | `doc.edit`       | write | `Editor.apply/2` |
  | `doc.save`       | write | `Editor.save/2` |

  Ten tools (the former `doc.inspect` and `doc.apply_style` are folded away):
  `doc.get` now also returns the reflective discovery the standalone
  `doc.inspect` used to (element type + the settable native-property names +
  child refs) alongside the current values, and char-run formatting is just
  `doc.set` (it routes char refs to the engine's `apply_char_format`), so there
  is a single read-properties tool and a single write-properties tool.

  `doc.read` is an anchor clarifier: `doc.find` discovers refs, then
  `doc.read {ref, nearby: ...}` returns a tiny structural neighborhood (siblings,
  row/column/header context). Table context is compacted by common
  section/paragraph/control anchor and never dumps the whole grid by default.

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

    * `doc.context` returns only the agent's OWN current document, never the
      global `Pool.active` or the full open-document list, so two agents never
      see each other's doc;
    * `doc.open` FAILS with `already_open` for an already-open doc (invariant 1)
      and records per-agent ownership;
    * `doc.edit` is `:forbidden` when another agent owns the doc (invariant 2),
      while an unowned (human-opened) doc is editable and lazily claimed.

  Results are JSON-shaped maps so the layer is testable server-side without a
  browser or an MCP transport. Errors that the agent is expected to act on
  (capability gaps, already_open/forbidden) are returned as structured maps
  mirroring the design's example payloads.
  """

  alias Ecrits.Doc.BrowserBridge
  alias Ecrits.Doc.Editor
  alias Ecrits.Doc.Op
  alias Ecrits.Doc.Pool
  alias Ecrits.Fuse.DocMount
  alias Ecrits.Fuse.OpenDocs
  alias Ecrits.Document.ByteSpool
  alias Ecrits.Workspace.Session
  alias Ecrits.Workspace.FileIndex
  require Logger

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

  # How long to wait for the viewing LiveView (browser WASM model) to reply. Keep
  # this below ExMCP's 10s GenServer.call boundary so slow viewer replies surface
  # as structured tool errors instead of HTTP 500s.
  @viewer_state_timeout_ms 500
  @find_text_limit 48
  @office_element_metadata_fields ~w(sheet address display value value_type valueType
                                     cached_value cachedValue formula_error formulaError
                                     number_format numberFormat)

  @tools [
    %{
      "namespace" => @namespace,
      "name" => "context",
      "description" =>
        "Current document metadata only. current_document is null or has document, " <>
          "name, path, kind, backing, and active. Use doc.list when you need the " <>
          "open-document catalog.",
      "risk" => "read",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}},
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "list",
      "description" => "List open/available documents (id, name, kind, path, backing).",
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
          "kind" => %{"type" => "string", "enum" => ["hwp", "hwpx", "docx", "pptx", "xlsx"]}
        },
        "required" => ["path"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "open_doc",
      "description" => "Open a workspace document on the primary editing surface.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string", "minLength" => 1}},
        "required" => ["path"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "close_doc",
      "description" =>
        "Remove a document from the doc VFS mount (reverse of doc.open_doc): the " <>
          "projected <name>.jsonl disappears from <workspace>/.ecrits/. " <>
          "This is for explicit unmount requests only, not normal edit cleanup or " <>
          "verification; closing mid-turn removes the file the agent needs to edit. " <>
          "Returns {closed}.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string", "minLength" => 1}},
        "required" => ["path"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "create",
      "description" =>
        "Create a NEW output document at `path` (kind from extension). Use only " <>
          "when the user explicitly asks for a new/output document; never for " <>
          "read-only read/inspect/summarize tasks. doc.open never creates files. " <>
          "Optional `from` clones an existing file or open doc " <>
          "(byte-copy — inherits ALL template formatting; then replace content in " <>
          "place, don't rebuild its tables). Blank pptx/docx: " <>
          "design it yourself per this server's instructions (the design guide). " <>
          "Quick fixed-template pptx: pass `deck` {title, subtitle, slides:[...]}. " <>
          "Save with doc.save.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "minLength" => 1},
          "kind" => %{"type" => "string", "enum" => ["hwp", "hwpx", "docx", "pptx", "xlsx"]},
          "from" => %{
            "type" => "string",
            "minLength" => 1,
            "description" =>
              "Optional template to clone: an existing document file path OR an " <>
                "open document id. The file is byte-copied to `path` so the new document " <>
                "inherits all of the template's formatting."
          },
          "deck" => %{
            "type" => "object",
            "description" =>
              "PPTX-only scratch deck spec. Include slides with title/subtitle plus cards, metrics, and roadmap/steps for a designed deck.",
            "properties" => %{
              "title" => %{"type" => "string"},
              "subtitle" => %{"type" => "string"},
              "slides" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "title" => %{"type" => "string"},
                    "subtitle" => %{"type" => "string"},
                    "section" => %{"type" => "string"},
                    "bullets" => %{"type" => "array", "items" => %{"type" => "string"}},
                    "roadmap" => %{"type" => "array", "items" => %{"type" => "string"}},
                    "cards" => %{
                      "type" => "array",
                      "items" => %{
                        "type" => "object",
                        "properties" => %{
                          "title" => %{"type" => "string"},
                          "body" => %{"type" => "string"}
                        }
                      }
                    },
                    "metrics" => %{
                      "type" => "array",
                      "items" => %{
                        "type" => "object",
                        "properties" => %{
                          "label" => %{"type" => "string"},
                          "value" => %{"type" => "string"},
                          "delta" => %{"type" => "string"}
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        },
        "required" => ["path"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "read",
      "description" =>
        "Clarify one ref from doc.find. Returns nearby structural elements/table row/column context.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{
            "type" => "string",
            "description" =>
              "Document id/path. For the current/open document, call doc.context and use current_document.document."
          },
          "ref" => %{"type" => "string", "description" => "Anchor ref from doc.find."},
          "nearby" => %{
            "type" => "object",
            "description" =>
              "For text: before/after sibling count. For cell: row/column/headers booleans.",
            "properties" => %{
              "before" => %{"type" => "integer", "minimum" => 0, "maximum" => 10},
              "after" => %{"type" => "integer", "minimum" => 0, "maximum" => 10},
              "unit" => %{"type" => "string", "enum" => ["element"], "default" => "element"},
              "row" => %{"type" => "boolean"},
              "column" => %{"type" => "boolean"},
              "headers" => %{"type" => "boolean"}
            }
          },
          "include" => %{
            "type" => "array",
            "items" => %{
              "type" => "string",
              "enum" => ["text", "refs", "table_headers", "row_labels"]
            }
          }
        },
        "required" => ["document", "ref"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "find",
      "description" =>
        "Find text or elements. Use type:\"fillable\" for writable blanks/cells/inline gaps; " <>
          "type:\"formula_cell\" for spreadsheet formula cells when the engine exposes formula metadata. " <>
          "Returns compact text snippets; use doc.read/doc.get for full context. Batch with patterns:[].",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{
            "type" => "string",
            "description" =>
              "Document id/path. For the current/open document, call doc.context and use current_document.document."
          },
          "pattern" => %{"type" => "string"},
          "marker" => %{
            "type" => "string",
            "minLength" => 1,
            "description" =>
              "Optional literal marker inside a matched element. Each match then returns " <>
                "marker_offset and a canonical before_marker_ref whose offset is immediately " <>
                "before that marker. Pass before_marker_ref verbatim for native insertion."
          },
          "patterns" => %{
            "type" => "array",
            "description" =>
              "Batch form: several literal/regex patterns in one call; top-level all/regex/type/case_sensitive apply to each.",
            "items" => %{"type" => "string"}
          },
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
            "enum" => ~w(fillable empty_cell cell filled_cell formula_cell paragraph empty
                 table picture shape equation field form
                 header footer footnote endnote bookmark hyperlink
                 ruby auto_number new_number section_def column_def
                 page_number_pos page_hide hidden_comment char_overlap unknown),
            "description" =>
              "Element filter. `fillable` = writable blank/form/placeholder targets only; " <>
                "`formula_cell` = spreadsheet cells with formula metadata."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 2000,
            "description" => "Max matches returned."
          }
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "get",
      "description" => "Inspect ref(s): type, values, settable props, child refs.",
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
        "Set element props. char (default): Bold/Italic/Underline/TextColor/FontSize(pt). " <>
          "paragraph (props.kind:\"paragraph\"): Alignment:left|center|right|justify — center titles, " <>
          "right-align dates/signatures. cell (props.kind:\"cell\"): BackgroundColor. " <>
          "Use doc.get for prop names. Batch with sets:[{ref,props}].",
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
          }
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "edit",
      "description" =>
        "Apply ONE structural edit (`op`) or many in one call (`ops:[...]` — " <>
          "best-effort, per-op results; batch related edits). Op families: " <>
          "text: insert_text/replace_text/set_cell/delete_range. " <>
          "Paragraphs: insert_paragraph {ref, text, style?} / delete_paragraph / " <>
          "split / merge — refs like \"p3\" from doc.find, or \"end\". " <>
          "For existing HWP paragraph division, use split at offsets; " <>
          "replace_text with newlines does NOT create HWP paragraph nodes. " <>
          "Tables: insert_table {ref, rows, cols, cells?, header?} — pass cells:[[\"r0c0\",\"r0c1\"],[\"r1c0\",..]] " <>
          "(row-major) to CREATE AND FILL the table in ONE op (the reliable way to make a data " <>
          "table; do NOT insert_table empty then type values as body text — they'd land outside the " <>
          "table). header:true shades row 0 gray for a real-document header (use it for data tables). " <>
          "insert_table_row/insert_table_column {ref, below?/right?, count?} — count inserts " <>
          "N rows/cols in ONE op (\"add 10 rows\" = count:10), delete_table_row/_column, " <>
          "merge_cells {ref, start_row.., end_col}, split_cell — use a cell ref from " <>
          "doc.find; row/col default to that cell's own position. To edit ONE existing cell use " <>
          "set_cell {ref(from doc.find), text}. Table-op replies " <>
          "echo rows_after/cols_after — CHECK them against what you intended. " <>
          "Objects: insert_picture {src}, insert_shape, set_geometry {ref, x?, y?, " <>
          "w?, h?}, delete_node {ref}. Notes: insert_footnote/insert_endnote " <>
          "{ref, text}, insert_equation {ref, script}. Slides (pptx): insert_slide " <>
          "{name}; coordinates use the deck's actual slide size in 1/100 mm. " <>
          "Check doc.render slide_size/pixel_width/pixel_height before placing shapes. " <>
          "Layout: set_columns {count, from, " <>
          "to} — footnoted paragraphs must stay outside the range. " <>
          "Authoring pptx/docx slides/sections? Follow this server's instructions " <>
          "(the design guide); doc.render after each slide/section and LOOK at it.",
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
              "Edit object. Common: replace_text {query,replacement,ref?,all?}; insert_text {ref,text}; set_cell {ref,text}; delete_range {ref,count}; insert_table {ref,rows,cols}; set_columns {ref,count}.",
            "properties" => %{
              "op" => %{
                "type" => "string",
                "enum" =>
                  ~w(insert_text delete_range replace_text insert_paragraph delete_paragraph split merge insert_table insert_table_row delete_table_row insert_table_column delete_table_column merge_cells split_cell delete_node insert_picture set_cell insert_equation insert_footnote insert_endnote insert_shape set_columns insert_slide set_geometry)
              },
              "rows" => %{"type" => "integer", "description" => "insert_table: number of rows."},
              "cols" => %{
                "type" => "integer",
                "description" => "insert_table: number of columns."
              },
              "cells" => %{
                "type" => "array",
                "description" =>
                  "insert_table: row-major cell text [[r0c0,r0c1,..],[r1c0,..],..] — creates AND fills the table in one op. \\n in a cell splits it into cell paragraphs.",
                "items" => %{"type" => "array", "items" => %{"type" => "string"}}
              },
              "header" => %{
                "type" => "boolean",
                "description" =>
                  "insert_table: shade row 0 with a light-gray fill (real-document header look). Use for any data table with a header row. Optional header_color overrides the fill."
              },
              "header_color" => %{
                "type" => "string",
                "description" =>
                  "insert_table: header row fill color (hex, e.g. \"#d9d9d9\"); implies header."
              },
              "query" => %{
                "type" => "string",
                "description" => "replace_text: literal text to find."
              },
              "replacement" => %{
                "type" => "string",
                "description" =>
                  "replace_text: text to substitute in. Newlines are folded to spaces; for existing HWP paragraph division use split instead. REQUIRED for replace_text."
              },
              "ref" => %{
                "type" => "string",
                "description" =>
                  "Target element ref (from doc.find). Scopes the edit to that element/paragraph. XLSX insert_picture uses a cell ref like sheet[Sheet1]/cell[A1]."
              },
              "src" => %{
                "type" => "string",
                "description" =>
                  "insert_picture: local image file path to embed. For HWP/browser documents use a plain local path or file:// URL; the server reads it and sends inline image bytes to the editor."
              },
              "all" => %{
                "type" => "boolean",
                "description" =>
                  "replace_text: replace EVERY match (default false = first match only)."
              },
              "text" => %{
                "type" => "string",
                "description" =>
                  "insert_text: text to insert. set_cell: the cell's new content (\\n splits into cell paragraphs)."
              },
              "at" => %{
                "type" => "integer",
                "description" => "char offset within the target paragraph."
              },
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
                "description" =>
                  "insert_equation: equation font size in HWPUNIT (point×100; 1000 = 10pt). Defaults to 1000."
              },
              "color" => %{
                "type" => "integer",
                "description" =>
                  "insert_equation: packed 0xBBGGRR color of the equation (default 0 = black)."
              },
              "shape_type" => %{
                "type" => "string",
                "description" =>
                  "insert_shape: shape kind — \"rectangle\" (default), \"ellipse\", \"line\", or \"textbox\"."
              },
              "width" => %{
                "type" => "integer",
                "description" =>
                  "insert_shape: shape width in HWPUNIT (e.g. 8504 ≈ 3cm). HWP insert_picture: optional placed width in HWPUNIT; omit with height to use the image's natural aspect at the default size."
              },
              "height" => %{
                "type" => "integer",
                "description" =>
                  "insert_shape: shape height in HWPUNIT. HWP insert_picture: optional placed height in HWPUNIT; omit with width to use the image's natural aspect at the default size."
              },
              "x" => %{
                "type" => "integer",
                "description" =>
                  "insert_shape / insert_picture: horizontal position. Slide form (with `page`): 1/100 mm. HWP shape form (with `ref`): HWPUNIT offset (default 0)."
              },
              "y" => %{
                "type" => "integer",
                "description" =>
                  "insert_shape / insert_picture: vertical position. Slide form (with `page`): 1/100 mm. HWP shape form (with `ref`): HWPUNIT offset (default 0)."
              },
              "w" => %{
                "type" => "integer",
                "description" =>
                  "insert_shape / insert_picture (Office form): width in 1/100 mm, relative to the deck/page or spreadsheet cell anchor. REQUIRED for slide pictures with `page`; optional for DOCX inline and XLSX cell pictures."
              },
              "h" => %{
                "type" => "integer",
                "description" =>
                  "insert_shape / insert_picture (Office form): height in 1/100 mm, relative to the deck/page or spreadsheet cell anchor. REQUIRED for slide pictures with `page`; optional for DOCX inline and XLSX cell pictures."
              },
              "page" => %{
                "type" => "string",
                "description" =>
                  "insert_shape / insert_picture (slide form): target slide name (from insert_slide or doc.find refs page[<name>]). Selecting the slide form: raw UNO properties (FillColor, CharHeight, CharColor, CharWeight, CharFontName, ...) may be passed as additional keys and apply verbatim."
              },
              "service" => %{
                "type" => "string",
                "description" =>
                  "insert_shape (slide form): UNO shape service, e.g. com.sun.star.drawing.RectangleShape / .EllipseShape / .TextShape / .LineShape. Default TextShape."
              },
              "name" => %{
                "type" => "string",
                "description" =>
                  "insert_slide / insert_shape / insert_picture (Office form): REQUIRED name for slides and slide objects; the new ref becomes page[<name>] / page[<page>]/shape[<name>], img[<name>] for DOCX inline pictures, or sheet[<sheet>]/shape[<name>] for XLSX pictures."
              },
              "index" => %{
                "type" => "integer",
                "description" => "insert_slide: 0-based position (default: append at end)."
              },
              "fillColor" => %{
                "type" => "string",
                "description" =>
                  "insert_shape: solid fill color as CSS #RRGGBB, e.g. #FFA500 for orange."
              },
              "BackgroundColor" => %{
                "type" => "string",
                "description" => "insert_shape: alias for fillColor as CSS #RRGGBB."
              },
              "fillBgColor" => %{
                "type" => "integer",
                "description" => "insert_shape: solid fill color as packed HWP BGR 0x00BBGGRR."
              },
              "fillType" => %{
                "type" => "string",
                "enum" => ~w(solid none),
                "description" =>
                  "insert_shape: fill type; defaults to solid when a fill color is given."
              },
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
          "verbose" => %{
            "type" => "boolean",
            "default" => false,
            "description" =>
              "For batch ops, include every per-op result. Default false returns counts plus failures only."
          }
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "save",
      "description" => "Persist the document to disk (export). Returns only ok/error.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "path" => %{
            "type" => "string",
            "description" => "Optional save target; defaults to the document's current path."
          }
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "render",
      "description" =>
        "Render page(s)/slide(s) to PNG FILES and return their paths — VIEW the " <>
          "returned file with your image tool (codex: view_image; claude: Read the " <>
          "path) to SEE the result; render-after-edit is the expected feedback loop. " <>
          "`page` = slide name (office) or 1-based page number (HWP); omit to " <>
          "render all (capped at 8).",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "page" => %{
            "type" => "string",
            "description" => "Slide name (refs look like page[<name>]). Omit for all slides."
          },
          "width" => %{
            "type" => "integer",
            "description" => "Pixel width per image (default 880, max 1920)."
          }
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => true}
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
    with {:ok, path} <- require_string(args, "path"),
         # Don't open files outside the workspace (prompt-injection guard).
         {:ok, path} <- confine_path(ctx, path) do
      kind = args |> get(["kind"]) |> normalize_kind(path)
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
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(ctx, "doc.open_doc", args) do
    with {:ok, path} <- require_string(args, "path"),
         {:ok, root} <- vfs_root(ctx),
         {:ok, abs} <- resolve_vfs_document_path(ctx, path),
         :ok <- ensure_projectable(abs) do
      name = vfs_mount_source_name(root, abs)

      refresh_mount? =
        Ecrits.Fuse.DocMount.mounted?(root) and
          (not Ecrits.Fuse.OpenDocs.member?(root, name) or
             stale_temp_reservation?(root, name))

      Ecrits.Fuse.OpenDocs.open(root, name,
        agent_id: Map.get(ctx, :agent_id),
        agent_session: Map.get(ctx, :agent_session),
        instance_id: Map.get(ctx, :instance_id),
        turn_id: Map.get(ctx, :turn_id),
        source_path: abs
      )

      sync_vfs_write_policy(ctx, root)

      mount_status = Ecrits.Fuse.DocMount.status()

      {mounted_at, mount_error} =
        case if(refresh_mount?,
               do: Ecrits.Fuse.DocMount.refresh(root),
               else: Ecrits.Fuse.DocMount.ensure(root)
             ) do
          {:ok, _} ->
            mounted =
              Path.join(
                Ecrits.Fuse.DocMount.mount_point(root),
                Ecrits.Doc.Projection.projected_name(name)
              )

            {mounted, nil}

          :disabled ->
            {nil, Map.get(mount_status, :message)}

          {:error, reason} ->
            {nil, inspect(reason)}
        end

      {mounted_at, mount_error} =
        cache_open_projection(root, name, abs, mounted_at, mount_error)

      {:ok,
       %{
         "opened" => vfs_relative_path(root, abs),
         "document" => Map.get(ctx, :active_doc),
         "mount_name" => name,
         "projected" => Ecrits.Doc.Projection.projected_name(name),
         "path" => abs,
         "mounted_at" => mounted_at,
         "mount_error" => mount_error,
         "mount_status" => doc_mount_status_json(mount_status),
         "vfs_enabled" => mount_status.enabled?,
         "workspace_files" => workspace_file_index(root),
         "surface" => vfs_surface_contract(mounted_at)
       }}
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(ctx, "doc.close_doc", args) do
    with {:ok, path} <- require_string(args, "path"),
         {:ok, root} <- vfs_root(ctx),
         {:ok, abs} <- resolve_vfs_document_path(ctx, path) do
      name = vfs_mount_source_name(root, abs)
      Ecrits.Fuse.OpenDocs.close(root, name)
      {:ok, %{"closed" => vfs_relative_path(root, abs), "mount_name" => name}}
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(ctx, "doc.create", args) do
    with :ok <- enforce_writable(ctx),
         {:ok, path} <- require_string(args, "path"),
         {:ok, path} <- confine_path(ctx, path) do
      kind = args |> get(["kind"]) |> normalize_kind(path)

      case get(args, ["from"]) do
        nil -> create_blank(ctx, path, kind, args)
        from when is_binary(from) and from != "" -> create_from(ctx, path, kind, from)
        _ -> {:error, error_json({:invalid_params, "from must be a non-empty string"})}
      end
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(ctx, "doc.read", args) do
    with {:ok, _ref} <- require_string(args, "ref") do
      route_doc(ctx, args,
        browser: fn lv ->
          browser_call(lv, args, :read, %{
            opts: take_opts(args, ["ref", "nearby", "include"])
          })
        end,
        server: fn editor -> server_read_nearby(editor, args) end
      )
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(ctx, "doc.find", args) do
    all = get(args, ["all"]) || false
    regex = get(args, ["regex"]) || false
    type = get(args, ["type"])

    # `pattern` is required for a literal search, but optional in discovery mode
    # (`all`/`regex`/`type`): {all:true} or {type:"empty_cell"} with no pattern
    # enumerates by structure, so default to "" rather than hard-failing.
    case get(args, ["patterns"]) do
      patterns when is_list(patterns) ->
        with {:ok, patterns} <- normalize_find_patterns(patterns) do
          route_doc(ctx, args,
            authority: Map.get(ctx, :doc_find_authority),
            browser: fn lv ->
              browser_call(lv, args, :find, %{
                patterns: patterns,
                case_sensitive: get(args, ["case_sensitive"]) || false,
                all: all,
                regex: regex,
                type: type,
                limit: find_limit(args)
              })
            end,
            server: fn editor -> server_find_many(editor, patterns, type, args) end
          )
          |> compact_find_response(args)
        end

      _ ->
        with {:ok, pattern} <-
               find_pattern(args, all || regex || (is_binary(type) and type != "")) do
          route_doc(ctx, args,
            authority: Map.get(ctx, :doc_find_authority),
            browser: fn lv ->
              browser_call(lv, args, :find, %{
                pattern: pattern,
                case_sensitive: get(args, ["case_sensitive"]) || false,
                all: all,
                regex: regex,
                type: type,
                limit: find_limit(args)
              })
            end,
            server: fn editor -> server_find(editor, pattern, type, args) end
          )
          |> compact_find_response(args)
        end
    end
  end

  # doc.get inspects a ref: its element type, current property VALUES, the
  # settable property NAMES (the native-property vocabulary), and child refs.
  # This folds the former standalone `doc.inspect` into the one read-properties
  # tool, so the agent has a single place to discover what it can set and what
  # the current values are.
  # `refs:[...]` (batch) takes precedence over `ref` (single). Open Office docs
  # inspect the browser IR; other docs inspect each ref best-effort on the server
  # editor and return a per-ref `results`.
  def call(ctx, "doc.get", args) do
    props = get(args, ["props"])

    case get(args, ["refs"]) do
      refs when is_list(refs) ->
        get_with_editor_or_office_browser(ctx, args, %{refs: refs, props: props}, fn editor ->
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
          get_with_editor_or_office_browser(ctx, args, %{ref: ref, props: props}, fn editor ->
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
    with :ok <- enforce_writable(ctx),
         :ok <- enforce_complete_turn_identity(ctx),
         {:ok, document} <- require_string(args, "document"),
         {:ok, document} <- canonical_document(ctx, document),
         :ok <- enforce_ownership(ctx, document) do
      ctx
      |> do_set(args)
      |> maybe_uncache_projection_after_edit(ctx, document)
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  # `ops:[...]` (batch) takes precedence over `op` (single) when present.
  def call(ctx, "doc.edit", args) do
    # Invariant 2 ("one agent per doc"): in an agent context, editing a doc owned
    # by a DIFFERENT agent is :forbidden. An UNOWNED doc (e.g. the human-opened
    # viewed HWP) is editable and is lazily claimed by this agent on first edit,
    # so the common single-agent flow keeps working while a 2nd agent is fenced
    # out. A bare pool-only context skips the check entirely.
    with :ok <- enforce_writable(ctx),
         :ok <- enforce_complete_turn_identity(ctx),
         :ok <- reject_retired_edit_metadata(args),
         {:ok, document} <- require_string(args, "document"),
         {:ok, document} <- canonical_document(ctx, document),
         :ok <- enforce_ownership(ctx, document) do
      ctx
      |> do_edit(args)
      |> maybe_uncache_projection_after_edit(ctx, document)
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(ctx, "doc.save", args) do
    with :ok <- enforce_writable(ctx),
         :ok <- enforce_complete_turn_identity(ctx),
         {:ok, document} <- require_string(args, "document"),
         {:ok, document, info} <- resolve_save_document(ctx, document),
         :ok <- enforce_ownership(ctx, document),
         {:ok, path} <- confine_path(ctx, get(args, ["path"]) || info.path) do
      args = Map.put(args, "document", document)

      route_doc(ctx, args,
        # Open doc: the browser WASM model is authority — export ITS edited bytes
        # and write them to disk (the server Editor copy is unedited).
        browser: fn lv -> save_browser(lv, args, path) end,
        # Headless doc: the NIF holds the edits — export via Ehwp + write.
        server: fn editor -> save_server(editor, info, path, ctx) end
      )
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(ctx, "doc.render", args) do
    with {:ok, document} <- require_string(args, "document"),
         {:ok, document} <- canonical_document(ctx, document) do
      case route(ctx, document) do
        {:server, editor} ->
          render_pages(editor, args)

        {:browser, lv} ->
          # The browser WASM model is the authority for a viewed doc — so render
          # THAT: snapshot its current bytes (the same channel doc.save uses),
          # open them in a throwaway headless handle, rasterize, drop the
          # handle. The agent gets pixels of exactly what the user is looking
          # at, unsaved edits included. Routing is the backend's job; opening a
          # doc in a viewer must not cost the agent its render feedback loop
          # (live failure 2026-06-13: doc.render -> not_supported on the
          # active document).
          render_viewed_pages(ctx, lv, document, args)

        {:error, :not_found} ->
          {:error, error_json(:not_found)}
      end
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(_ctx, tool_name, _args), do: {:error, {:unknown_tool, tool_name}}

  # The VFS contract is returned as data, not injected into the ACP prompt. This
  # lets a client discover the primary surface's real payload vocabulary and
  # derive the one precise native ref that is not representable there, without
  # prescribing a shell-specific editing recipe.
  defp vfs_surface_contract(mounted_at) do
    %{
      "version" => 2,
      "kind" => "jsonl_projection",
      "available" => is_binary(mounted_at),
      "addressing" => "nested_payload_position",
      "format" => %{
        "encoding" => "one_json_value_one_paragraph_group_per_line",
        "line_addressing" => %{
          "locate" => "line_based_search_finds_the_target_paragraph_group_line",
          "edit" =>
            "replace_whole_lines_keeping_one_paragraph_group_per_line_and_the_trailing_comma",
          "newlines" =>
            "raw_newlines_are_reserved_record_separators_content_newlines_stay_escaped"
        },
        "structure" => ["sections", "paragraphs", "payloads"],
        "commit" => projection_commit_contract(mounted_at)
      },
      "preserve" => ["payload_type", "unknown_fields", "nested_order"],
      "payloads" => %{
        "text" => %{"edit" => true},
        "table" => %{
          "insert" => %{
            "required" => ["type", "cells"],
            "mode" => "insert_compact_payload_node",
            "preserve_existing_payloads" => true
          }
        },
        "picture" => %{
          "insert" => false,
          "route" => "native_fallback"
        }
      },
      "operations" => %{
        "set_text" => %{
          "target_types" => ["paragraph", "char", "cell"],
          "field" => "text",
          "mode" => "in_place",
          "select" => "type_and_current_text",
          "reuse_blank_payloads" => true
        },
        "insert_table" => %{
          "container" => "existing_paragraph_payload_array",
          "at" => "after_existing_anchor_payload",
          "action" => "insert_new_payload_node",
          "replace_container" => false,
          "insert_paragraph_arrays" => false,
          "copy_expanded_table_payloads" => false,
          "node" => %{
            "type" => "table",
            "cells" => "string_matrix",
            "header" => "boolean_optional"
          }
        }
      },
      "native_fallbacks" => %{
        "insert_picture" => %{
          "tool" => "doc.edit",
          "reason" => "unrepresentable",
          "supported_placement" => "picture_at_exact_existing_marker",
          "derive_from" => "current_engine_ref_after_primary_commit",
          "resolve_ref" => %{
            "tool" => "doc.find",
            "when" => "after_primary_commit",
            "arguments" => %{
              "document" => %{"from" => "doc.open_doc.document"},
              "type" => "paragraph",
              "pattern" => %{"from" => "copy_exact_committed_target_paragraph_text"},
              "marker" => %{
                "from" => "existing_literal_immediately_after_picture",
                "must_already_exist" => true,
                "create_placeholder" => false
              },
              "case_sensitive" => true,
              "limit" => 1,
              "occurrence" => %{
                "optional" => true,
                "use" => "1_based_document_order_index_when_the_exact_paragraph_text_repeats"
              }
            },
            "select" => "unique_exact_text_match_containing_existing_marker",
            "use" => "match.before_marker_ref_verbatim",
            "manual_ref_derivation" => false
          },
          "op" => %{
            "op" => "insert_picture",
            "src" => "absolute_file_path",
            "ref" => "json_string",
            "ref_value" => %{
              "section" => "non_negative_integer",
              "paragraph" => "non_negative_integer",
              "offset" => "non_negative_character_index",
              "cellPath" => "optional_nonempty_canonical_cell_path"
            }
          },
          "derive_ref_from_doc_find_match" => true,
          "fallback" => %{
            "attempted" => "vfs",
            "reason" => "unrepresentable",
            "detail" => "describe_the_exact_existing_marker_picture_placement",
            "mounted_at" => "exact_value_returned_by_doc.open_doc"
          }
        }
      }
    }
  end

  defp workspace_file_index(root) do
    case FileIndex.list(root) do
      {:ok, files} -> files
      {:error, _reason} -> []
    end
  end

  defp projection_commit_contract(mounted_at) do
    %{
      "mode" => "same_directory_temp_then_rename",
      "target_path" => mounted_at,
      "temp_path" => if(is_binary(mounted_at), do: mounted_at <> ".tmp", else: nil),
      "temp_scope" => "mounted_projection_directory_only",
      "external_temp" => false,
      "rename" => "same_filesystem_atomic",
      "unsupported_structural_change" => %{"committed" => false, "errno" => "EINVAL"},
      "on_einval" => %{
        "likely_cause" => "staged_bytes_built_from_a_read_older_than_the_last_commit",
        "recover" =>
          "reread_the_mounted_file_now_and_restage_the_same_change_from_that_fresh_read"
      },
      "on_enoent" => %{
        "likely_cause" => "projection_not_registered_this_turn_or_mount_was_recycled",
        "recover" => "call_doc.open_doc_path_current_once_then_retry_the_same_command_unchanged"
      },
      "on_projection_temp_exists" => %{
        "likely_cause" => "temp_reservation_left_by_an_interrupted_writer",
        "recover" =>
          "call_doc.open_doc_path_current_once_it_clears_the_reservation_then_retry_the_same_write_unchanged"
      }
    }
  end

  # The #453 wedge signature: a writer killed between its O_EXCL create and
  # cleanup leaves the FSKit appex holding a phantom item for the temp name —
  # lstat says ENOENT while exclusive creates keep failing EEXIST, bricking
  # every later commit until the mount is replaced. Probe order matters: an
  # EXISTING temp file means a writer is in flight (never refresh under it);
  # only the ENOENT-then-EEXIST contradiction triggers the heal. A healthy
  # probe file is removed immediately.
  defp stale_temp_reservation?(root, name) do
    temp =
      Ecrits.Fuse.DocMount.mount_point(root)
      |> Path.join(Ecrits.Doc.Projection.projected_name(name) <> ".tmp")
      |> String.to_charlist()

    case :prim_file.read_file_info(temp) do
      {:error, :enoent} ->
        case :prim_file.open(temp, [:write, :exclusive]) do
          {:ok, fd} ->
            :prim_file.close(fd)
            _ = :prim_file.delete(temp)
            false

          {:error, :eexist} ->
            true

          {:error, _reason} ->
            false
        end

      _exists_or_error ->
        false
    end
  catch
    _, _ -> false
  end

  defp cache_open_projection(root, name, abs, mounted_at, nil) when is_binary(mounted_at) do
    case OpenDocs.committed(root, name) do
      {:ok, _already_served_bytes} ->
        # Reopening an already-mounted document is not a fresh FSKit vnode
        # boundary. Preserve the exact bytes that inode currently serves.
        {mounted_at, nil}

      :error ->
        case Ecrits.Doc.Projection.project_file(abs) do
          {:ok, bytes} ->
            OpenDocs.cache_committed(root, name, bytes)
            {mounted_at, nil}

          {:error, reason} ->
            {nil, inspect({:projection_unavailable, reason})}
        end
    end
  end

  defp cache_open_projection(_root, _name, _abs, mounted_at, mount_error),
    do: {mounted_at, mount_error}

  # ── doc.render, browser (viewed) arm ────────────────────────────────────
  # Pull the viewer's CURRENT bytes and render headless. The throwaway handle
  # never touches the Pool/Editor registry (no doc.list pollution, no
  # ownership questions) — it lives for exactly one render call.
  defp render_viewed_pages(ctx, lv, document, args) do
    case maybe_render_clean_viewed_office(ctx, lv, document, args) do
      {:ok, _result} = ok -> ok
      :browser_snapshot -> render_viewed_snapshot(ctx, lv, document, args)
    end
  end

  defp maybe_render_clean_viewed_office(ctx, lv, document, args) do
    with {:ok, %{kind: kind, path: path}} <- viewed_office_info(ctx, document),
         {:ok, false} <- viewer_document_dirty?(lv, document),
         {:ok, editor} <- ensure_viewed_office_server_editor(ctx, document, path, kind) do
      Logger.debug(fn ->
        "[doc_tools] doc.render viewed_office fast_path=server_twin kind=#{kind} dirty=false"
      end)

      render_pages(editor, args)
    else
      {:ok, true} ->
        :browser_snapshot

      _ ->
        :browser_snapshot
    end
  end

  defp render_viewed_snapshot(ctx, lv, document, args) do
    case browser_call(lv, args, :save, %{}) do
      {:ok, %{} = saved} ->
        case ByteSpool.decode(saved) do
          {:ok, bytes} ->
            render_viewed_bytes(bytes, viewed_kind(ctx, document, saved), args)

          {:error, _reason} ->
            {:error, error_json({:render_failed, "viewer returned no/invalid bytes"})}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp viewed_office_info(ctx, document) do
    case Pool.info(pool(ctx), document) do
      {:ok, %{kind: kind} = info} when kind in [:docx, :pptx, :xlsx] ->
        {:ok, info}

      {:ok, _info} ->
        :browser_snapshot

      {:error, :not_found} ->
        active_viewed_office_info(ctx, document)
    end
  end

  defp active_viewed_office_info(ctx, document) do
    with true <- Map.get(ctx, :active_doc) == document,
         lv when is_pid(lv) <- session_viewer(ctx, document),
         path when is_binary(path) and path != "" <- Map.get(ctx, :document_path),
         kind when kind in [:docx, :pptx, :xlsx] <- kind_from_path(path),
         {:ok, confined_path} <- confine_path(ctx, path) do
      {:ok, %{id: document, kind: kind, path: confined_path, backing: :browser, viewer: lv}}
    else
      _ -> :browser_snapshot
    end
  end

  defp ensure_viewed_office_server_editor(ctx, document, path, kind) do
    case Pool.route(pool(ctx), document) do
      {:server, editor} ->
        {:ok, editor}

      {:error, :not_found} ->
        with {:ok, ^document} <- Pool.open(pool(ctx), path, kind: kind, document_id: document),
             {:server, editor} <- Pool.route(pool(ctx), document) do
          {:ok, editor}
        else
          {:ok, opened} -> Pool.route(pool(ctx), opened)
          {:error, reason} -> {:error, reason}
          other -> other
        end
    end
  end

  defp viewer_document_dirty?(lv, document) when is_pid(lv) do
    ref = make_ref()
    send(lv, {:doc_viewer_state_request, self(), ref, document})

    receive do
      {:doc_viewer_state_reply, ^ref, {:ok, %{dirty: dirty?}}} when is_boolean(dirty?) ->
        {:ok, dirty?}

      {:doc_viewer_state_reply, ^ref, {:ok, %{"dirty" => dirty?}}} when is_boolean(dirty?) ->
        {:ok, dirty?}

      {:doc_viewer_state_reply, ^ref, {:error, reason}} ->
        {:error, reason}
    after
      @viewer_state_timeout_ms ->
        {:error, :viewer_state_timeout}
    end
  end

  defp viewed_kind(ctx, document, saved) do
    case Pool.info(pool(ctx), document) do
      {:ok, %{kind: kind}} when kind in [:hwp, :hwpx, :docx, :pptx, :xlsx] ->
        kind

      _ ->
        case saved["format"] || saved[:format] do
          "hwpx" -> :hwpx
          "docx" -> :docx
          "pptx" -> :pptx
          "xlsx" -> :xlsx
          _ -> :hwp
        end
    end
  end

  defp render_viewed_bytes(bytes, kind, args) when kind in [:hwp, :hwpx] do
    case Ehwp.open(bytes) do
      {:ok, ehwp_handle, _meta} ->
        try do
          run_page_renders(args, ["1"], fn page, out, width ->
            Ecrits.Doc.Rhwp.render_page(%{ehwp: ehwp_handle, sec: 0}, page, out, width)
          end)
        after
          Ehwp.close(ehwp_handle)
        end

      {:error, reason} ->
        {:error, error_json({:render_failed, "viewer bytes did not reopen: #{inspect(reason)}"})}
    end
  end

  defp render_viewed_bytes(bytes, kind, args) when kind in [:docx, :pptx, :xlsx] do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ecrits_viewed_render_#{System.unique_integer([:positive])}.#{kind}"
      )

    with :ok <- File.write(tmp, bytes),
         {:ok, handle} <- Ecrits.Doc.Office.open(tmp, kind: kind) do
      try do
        # find_page falls back to positional "SlideN" names for unnamed slides.
        default = if kind == :pptx, do: ["Slide1"], else: ["1"]

        slide_size = if kind == :pptx, do: pptx_slide_size_from_bytes(bytes), else: nil

        run_page_renders(
          args,
          default,
          fn page, out, width ->
            Ecrits.Doc.Office.render_page(handle, page, out, width)
          end,
          slide_size: slide_size
        )
      after
        Ecrits.Doc.Office.close(handle)
        File.rm(tmp)
      end
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, error_json({:render_failed, "viewer bytes did not reopen: #{inspect(reason)}"})}
    end
  end

  # Shared page loop for the viewed arm: same width clamp, tmp naming and
  # result shape as the server arm's render_pages (files + note, no base64).
  defp run_page_renders(args, default_pages, render_fun, opts \\ []) do
    width =
      case get(args, ["width"]) do
        w when is_integer(w) -> w |> max(320) |> min(1920)
        _other -> 880
      end

    pages =
      case get(args, ["page"]) do
        page when is_binary(page) and page != "" -> [page]
        _other -> default_pages
      end

    doc_token =
      args
      |> get(["document"])
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_-]/, "_")

    dir = Path.join(System.tmp_dir!(), "ecrits_render")
    File.mkdir_p!(dir)

    {files, failures} =
      Enum.reduce(pages, {[], []}, fn page, {ok_acc, err_acc} ->
        page_token = page |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
        out = Path.join(dir, "#{doc_token}_#{page_token}_w#{width}.png")

        case render_fun.(page, out, width) do
          :ok ->
            {[rendered_file_result(page, out) | ok_acc], err_acc}

          {:error, reason} ->
            File.rm(out)
            {ok_acc, [%{"page" => page, "error" => format_render_error(reason)} | err_acc]}
        end
      end)

    files = Enum.reverse(files)
    failures = Enum.reverse(failures)

    if files == [] do
      {:error, error_json({:render_failed, failures})}
    else
      result =
        %{
          "ok" => true,
          "rendered" => Enum.map(files, & &1["page"]),
          "width" => width,
          "files" => files,
          "note" => "PNG files on local disk — VIEW them with your image tool to check the result"
        }
        |> maybe_put("slide_size", Keyword.get(opts, :slide_size))

      if failures == [], do: {:ok, result}, else: {:ok, Map.put(result, "failed", failures)}
    end
  end

  # Render the requested slide (or all, capped) to PNG FILES and return their
  # paths. NO inline base64: the receivers are CLI agents whose vision path is
  # file-based (codex view_image / claude Read) — an inline image block just
  # round-trips ~100-200KB of base64 through the ACP text channel per render
  # (observed live), bloating the model context instead of showing pixels.
  # Stable per-doc/page/width names under tmp keep re-renders overwrite-only.
  defp render_pages(editor, args) do
    width =
      case get(args, ["width"]) do
        w when is_integer(w) -> w |> max(320) |> min(1920)
        _other -> 880
      end

    pages =
      case get(args, ["page"]) do
        page when is_binary(page) and page != "" ->
          [page]

        _other ->
          # pptx: every slide by name. HWP has no named pages — default to
          # page "1" (the agent passes "2", "3", … explicitly for more).
          case editor |> slide_names() |> Enum.take(8) do
            [] -> ["1"]
            slides -> slides
          end
      end

    doc_token =
      args
      |> get(["document"])
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_-]/, "_")

    dir = Path.join(System.tmp_dir!(), "ecrits_render")
    File.mkdir_p!(dir)

    {files, failures} =
      Enum.reduce(pages, {[], []}, fn page, {ok_acc, err_acc} ->
        page_token = page |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
        out = Path.join(dir, "#{doc_token}_#{page_token}_w#{width}.png")

        case Editor.render(editor, page, out, width: width) do
          :ok ->
            {[rendered_file_result(page, out) | ok_acc], err_acc}

          {:error, reason} ->
            File.rm(out)
            {ok_acc, [%{"page" => page, "error" => format_render_error(reason)} | err_acc]}
        end
      end)

    files = Enum.reverse(files)
    failures = Enum.reverse(failures)

    if files == [] do
      {:error, error_json({:render_failed, failures})}
    else
      result =
        %{
          "ok" => true,
          "rendered" => Enum.map(files, & &1["page"]),
          "width" => width,
          "files" => files,
          "note" => "PNG files on local disk — VIEW them with your image tool to check the result"
        }
        |> maybe_put("slide_size", pptx_slide_size_from_editor(editor))

      result = if failures == [], do: result, else: Map.put(result, "failed", failures)
      {:ok, result}
    end
  end

  defp rendered_file_result(page, path) do
    %{"page" => page, "file" => path}
    |> maybe_put_png_dimensions(path)
  end

  defp maybe_put_png_dimensions(file, path) do
    case png_dimensions(path) do
      {:ok, width, height} ->
        file
        |> Map.put("pixel_width", width)
        |> Map.put("pixel_height", height)
        |> Map.put("pixel_aspect", rounded_aspect(width, height))

      :error ->
        file
    end
  end

  defp png_dimensions(path) when is_binary(path) do
    case File.read(path) do
      {:ok,
       <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", width::unsigned-big-32,
         height::unsigned-big-32, _rest::binary>>} ->
        {:ok, width, height}

      _other ->
        :error
    end
  end

  defp png_dimensions(_path), do: :error

  defp rounded_aspect(_width, 0), do: nil
  defp rounded_aspect(width, height), do: Float.round(width / height, 4)

  defp pptx_slide_size_from_editor(editor) do
    case Editor.info(editor) do
      %{kind: :pptx, path: path} when is_binary(path) -> pptx_slide_size_from_path(path)
      _other -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp pptx_slide_size_from_path(path) do
    with true <- File.regular?(path),
         {:ok, bytes} <- File.read(path) do
      pptx_slide_size_from_bytes(bytes)
    else
      _other -> nil
    end
  end

  defp pptx_slide_size_from_bytes(bytes) when is_binary(bytes) do
    with {:ok, entries} <- :zip.unzip(bytes, [:memory]),
         {_name, xml} <-
           Enum.find(entries, fn {name, _xml} -> to_string(name) == "ppt/presentation.xml" end),
         {:ok, cx, cy} <- extract_pptx_slide_size(xml) do
      %{
        "width_emu" => cx,
        "height_emu" => cy,
        "width_100mm" => round(cx / 360),
        "height_100mm" => round(cy / 360),
        "aspect" => rounded_aspect(cx, cy),
        "orientation" => if(cx >= cy, do: "landscape", else: "portrait"),
        "coordinate_unit" => "1/100 mm"
      }
    else
      _other -> nil
    end
  end

  defp pptx_slide_size_from_bytes(_bytes), do: nil

  defp extract_pptx_slide_size(xml) do
    xml = IO.iodata_to_binary(xml)

    with [tag] <- Regex.run(~r/<p:sldSz\b[^>]*>/, xml),
         [_, cx] <- Regex.run(~r/\bcx="(\d+)"/, tag),
         [_, cy] <- Regex.run(~r/\bcy="(\d+)"/, tag) do
      {:ok, String.to_integer(cx), String.to_integer(cy)}
    else
      _other -> :error
    end
  end

  defp slide_names(editor) do
    case Editor.elements(editor) do
      {:ok, nodes} ->
        nodes
        |> Enum.filter(&(node_field(&1, "type") == "slide"))
        |> Enum.map(&page_name_from_ref(node_field(&1, "ref")))
        |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  end

  defp page_name_from_ref("page[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [name, _] -> name
      _other -> nil
    end
  end

  defp page_name_from_ref(_ref), do: nil

  defp format_render_error(%{} = reason), do: reason
  defp format_render_error(reason), do: inspect(reason)

  defp resolve_save_document(ctx, document) do
    # Aliases (basename / relative path / "active") resolve first; the
    # browser-viewer fallback accepts the exact handle doc.context returns for
    # viewed Office docs that are not materialised in the Pool; the
    # confine+info_by_path fallback keeps the legacy absolute-path form working.
    document =
      case canonical_document(ctx, document) do
        {:ok, id} -> id
        {:error, _reason} -> document
      end

    case Pool.info(pool(ctx), document) do
      {:ok, info} ->
        {:ok, document, info}

      {:error, :not_found} ->
        case active_browser_save_document(ctx, document) do
          {:ok, document_id, info} ->
            {:ok, document_id, info}

          :error ->
            with {:ok, path} <- confine_path(ctx, document),
                 {:ok, %{id: document_id} = info} <- Pool.info_by_path(pool(ctx), path) do
              {:ok, document_id, info}
            end
        end
    end
  end

  defp active_browser_save_document(ctx, document) do
    active_doc = Map.get(ctx, :active_doc)
    path = Map.get(ctx, :document_path)

    with true <- is_binary(active_doc) and active_doc != "",
         true <- session_viewer(ctx, active_doc) != nil,
         true <- document == active_doc or document_matches_path?(document, path),
         path when is_binary(path) and path != "" <- path,
         {:ok, path} <- confine_path(ctx, path),
         kind when not is_nil(kind) <- kind_from_path(path) do
      {:ok, active_doc, %{id: active_doc, kind: kind, path: path, backing: :browser}}
    else
      _ -> :error
    end
  end

  defp document_matches_path?(document, path) when is_binary(document) and is_binary(path) do
    normalized = String.trim_leading(document, "./")

    document == path or
      String.ends_with?(path, "/" <> normalized) or
      Path.basename(path) == normalized
  end

  defp document_matches_path?(_document, _path), do: false

  # --- doc.edit dispatch (after the ownership gate) ------------------------

  defp do_set(ctx, args) do
    case get(args, ["sets"]) do
      sets when is_list(sets) ->
        route_doc(ctx, args,
          browser: fn lv -> browser_set_batch(lv, args, sets) end,
          server: fn editor -> set_batch_server(editor, sets, editor_write_opts(ctx)) end
        )

      _other ->
        with {:ok, ref} <- require_string(args, "ref"),
             {:ok, props} <- require_map(args, "props") do
          route_doc(ctx, args,
            browser: fn lv -> browser_set(lv, args, ref, props) end,
            server: fn editor ->
              write_result(Editor.set(editor, ref, props, editor_write_opts(ctx)))
            end
          )
        end
    end
  end

  defp do_edit(ctx, args) do
    case get(args, ["ops"]) do
      ops when is_list(ops) ->
        # Batch form: apply many edits in one call, best-effort with a per-op
        # result. Each op is normalised per-op for the browser payload (same as
        # the single path), so a malformed op is rejected individually.
        route_doc(ctx, args,
          browser: fn lv -> browser_write_batch(lv, args, ops) end,
          server: fn editor ->
            edit_batch_server(
              editor,
              ops,
              get(args, ["verbose"]) == true,
              editor_write_opts(ctx)
            )
          end
        )

      _ ->
        with {:ok, op} <- require_map(args, "op") do
          route_doc(ctx, args,
            # Viewed-HWP authority is the browser WASM model: deliver the structural
            # edit to the owning LiveView -> WasmHwpEditor hook applies it to the rhwp
            # WASM doc. We do NOT touch the server NIF
            # for a browser-backed doc (design §6.2) so the two models can't diverge.
            browser: fn lv -> browser_write(lv, args, op) end,
            server: fn editor ->
              write_result(Editor.apply(editor, op, editor_write_opts(ctx)))
            end
          )
        end
    end
  end

  # A successful native edit changes the engine model behind an already-served
  # FSKit inode. Keep that inode's exact bytes stable and stage the new canonical
  # projection for the same fresh-sibling terminal publication used by ACP VFS
  # edits. An OpenDocs cache delete alone cannot invalidate FSKit page state.
  defp maybe_uncache_projection_after_edit(result, ctx, document) do
    if edit_mutated?(result) do
      with {:ok, root} <- vfs_root(ctx),
           {:ok, source_path} <- edited_document_path(ctx, document),
           {:ok, name} <- OpenDocs.name_for_source(root, source_path),
           metadata = %{
             agent_id: Map.get(ctx, :agent_id),
             instance_id: Map.get(ctx, :instance_id),
             turn_id: Map.get(ctx, :turn_id),
             source_path: source_path
           },
           {:ok, accepted_bytes, generation} <-
             OpenDocs.begin_canonical_stage(root, name, metadata),
           {:ok, canonical_bytes} <- Ecrits.Doc.Projection.project_file(source_path) do
        OpenDocs.complete_canonical_stage(
          root,
          name,
          accepted_bytes,
          canonical_bytes,
          generation,
          metadata
        )
      end
    end

    result
  end

  defp edit_mutated?({status, %{"applied" => applied}})
       when status in [:ok, :error] and is_integer(applied),
       do: applied > 0

  defp edit_mutated?({:ok, %{"native" => native}}), do: native_edit_mutated?(native)
  defp edit_mutated?({:ok, %{"replaced" => 0}}), do: false
  defp edit_mutated?({:ok, _result}), do: true
  defp edit_mutated?(_result), do: false

  defp native_edit_mutated?(results) when is_list(results),
    do: Enum.any?(results, &native_edit_mutated?/1)

  defp native_edit_mutated?(%{} = result), do: get(result, ["ok"]) != false
  defp native_edit_mutated?(_result), do: true

  defp edited_document_path(ctx, document) do
    case Pool.info(pool(ctx), document) do
      {:ok, %{path: path}} when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        active_doc = Map.get(ctx, :active_doc)
        path = Map.get(ctx, :document_path)

        if active_doc == document and is_binary(path) and path != "" do
          confine_path(ctx, path)
        else
          :error
        end
    end
  end

  # Reject the old protocol at the envelope and each selected operation before
  # routing. In particular, a batch must not partially mutate a document merely
  # because one of its operations still carries retired metadata.
  defp reject_retired_edit_metadata(args) do
    with :ok <- Op.reject_retired_metadata(args) do
      args
      |> edit_ops()
      |> Enum.reduce_while(:ok, fn op, :ok ->
        case Op.reject_retired_metadata(op) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp edit_ops(args) do
    case get(args, ["ops"]) do
      ops when is_list(ops) -> ops
      _ -> List.wrap(get(args, ["op"]))
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
    doc_id = Pool.document_id_for(path, kind)

    if document_open?(ctx, doc_id) do
      {:error, already_open_json(ctx, doc_id, agent_id)}
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

  # A doc is "open" iff there is a live model for it (route resolves to a server
  # editor or an alive browser viewer).
  defp document_open?(ctx, doc_id) do
    case route(ctx, doc_id) do
      {:error, :not_found} -> false
      _ -> true
    end
  end

  # The `already_open` structured error: the existing document id + who holds it.
  # held_by is `self` (this agent already owns it), `{:agent, id}` (another
  # agent), or `:viewer` (a human-viewed/browser-backed doc with no agent owner).
  defp already_open_json(ctx, doc_id, agent_id) do
    %{
      "error" => "already_open",
      "document" => doc_id,
      "held_by" => held_by(ctx, doc_id, agent_id)
    }
  end

  defp held_by(ctx, doc_id, agent_id) do
    case owner(ctx, doc_id) do
      ^agent_id ->
        %{"kind" => "self", "agent_id" => agent_id}

      owner when is_binary(owner) ->
        %{"kind" => "agent", "agent_id" => owner}

      nil ->
        case route(ctx, doc_id) do
          {:browser, _lv} -> %{"kind" => "viewer"}
          _ -> %{"kind" => "unowned"}
        end
    end
  end

  defp maybe_claim_owner(%{agent_id: agent_id} = ctx, doc_id) when is_binary(agent_id),
    do: claim_owner(ctx, doc_id, agent_id)

  defp maybe_claim_owner(_ctx, _doc_id), do: :ok

  # Per-doc ownership (invariant 2) lives in the per-workspace
  # `Ecrits.Workspace.Session` (the real home of `owners` since Phase 3). It is
  # consulted ONLY when the ctx carries a `:session_path` — the production agent
  # path always does. A bare pool-only context (legacy mount / a direct
  # `Tools.call(%{pool: …})` in a test) has no Session, so ownership is not
  # enforced there (it never was isolated): `owner` reports none and `claim`
  # always succeeds, preserving the legacy permissive behaviour.
  defp owner(ctx, doc_id) do
    case Map.get(ctx, :session_path) do
      path when is_binary(path) and path != "" -> Session.owner(path, doc_id)
      _ -> nil
    end
  end

  defp claim_owner(ctx, doc_id, agent_id) do
    case Map.get(ctx, :session_path) do
      path when is_binary(path) and path != "" -> Session.claim_owner(path, doc_id, agent_id)
      _ -> :ok
    end
  end

  # --- doc.edit ownership enforcement (invariant 2) ------------------------

  # In an agent context, gate a write on ownership. `claim_owner` is the single
  # authoritative arbiter (it succeeds for the current owner OR an unowned doc,
  # and fails only when ANOTHER agent owns it), so this both enforces the fence
  # AND lazily claims an unowned doc for the editing agent. A bare pool-only
  # context (no agent_id) skips ownership entirely.
  defp enforce_ownership(%{agent_id: agent_id} = ctx, document) when is_binary(agent_id) do
    case claim_owner(ctx, document, agent_id) do
      :ok ->
        :ok

      {:error, {:owned, owner}} ->
        {:error,
         %{"error" => "forbidden", "document" => document, "owned_by" => %{"agent_id" => owner}}}
    end
  end

  defp enforce_ownership(_ctx, _document), do: :ok

  defp enforce_complete_turn_identity(%{agent_id: agent_id, session_path: session_path} = ctx)
       when is_binary(agent_id) and agent_id != "" and is_binary(session_path) and
              session_path != "" do
    if Enum.all?([:instance_id, :turn_id], fn key ->
         value = Map.get(ctx, key)
         is_binary(value) and value != ""
       end) do
      :ok
    else
      {:error,
       {:invalid_params, "an agent document write requires the active instance_id and turn_id"}}
    end
  end

  defp enforce_complete_turn_identity(_ctx), do: :ok

  # --- doc.create helpers --------------------------------------------------

  # doc.create without `from`: a blank engine template whose save target is `path`.
  # PPTX with `deck` -> the designed PptxBuilder template; without `deck` -> a
  # LibreOffice factory-blank presentation, the seed for IR-direct from-scratch
  # authoring (insert_slide / insert_shape edit ops).
  defp create_blank(ctx, path, :pptx, args) do
    deck = get(args, ["deck"])

    if is_map(deck) do
      create_pptx(ctx, path, deck)
    else
      with :ok <- Ecrits.Doc.Office.create_blank_file(path, :pptx) do
        broadcast_file_written(path)

        case Pool.open(pool(ctx), path, kind: :pptx) do
          {:ok, doc_id} ->
            _ = maybe_claim_owner(ctx, doc_id)
            {:ok, %{"document" => doc_id, "kind" => "pptx", "path" => path}}

          {:error, reason} ->
            {:error, error_json(reason)}
        end
      else
        {:error, reason} -> {:error, error_json({:create_failed, reason})}
      end
    end
  end

  # docx mirrors the pptx factory-blank path: the engine's own "new text
  # document" exported as docx, then opened for IR-direct Writer authoring
  # (insert_paragraph / insert_table / insert_picture / insert_footnote /
  # set_columns edit ops). The generic clause below requires backend.new/1,
  # which Office (create_blank_file/2) does not expose.
  defp create_blank(ctx, path, :docx, _args) do
    with :ok <- Ecrits.Doc.Office.create_blank_file(path, :docx) do
      broadcast_file_written(path)

      case Pool.open(pool(ctx), path, kind: :docx) do
        {:ok, doc_id} ->
          _ = maybe_claim_owner(ctx, doc_id)
          {:ok, %{"document" => doc_id, "kind" => "docx", "path" => path}}

        {:error, reason} ->
          {:error, error_json(reason)}
      end
    else
      {:error, reason} -> {:error, error_json({:create_failed, reason})}
    end
  end

  defp create_blank(ctx, path, kind, _args) do
    with {:ok, backend} <- create_backend(kind),
         :ok <- supports_blank_create(backend) do
      case Pool.create(pool(ctx), path, kind: kind) do
        {:ok, doc_id} ->
          _ = maybe_claim_owner(ctx, doc_id)
          {:ok, %{"document" => doc_id, "kind" => Atom.to_string(kind)}}

        {:error, reason} ->
          {:error, error_json(reason)}
      end
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  defp create_pptx(ctx, path, deck) do
    with :ok <- Ecrits.Doc.PptxBuilder.write(path, deck) do
      broadcast_file_written(path)

      case Pool.open(pool(ctx), path, kind: :pptx) do
        {:ok, doc_id} ->
          _ = maybe_claim_owner(ctx, doc_id)
          {:ok, %{"document" => doc_id, "kind" => "pptx", "path" => path}}

        {:error, reason} ->
          {:error, error_json(reason)}
      end
    else
      {:error, reason} -> {:error, error_json({:create_failed, reason})}
    end
  end

  defp create_backend(kind) do
    case Ecrits.Doc.backend_for(kind) do
      nil -> {:error, {:unsupported_kind, kind}}
      backend -> {:ok, backend}
    end
  end

  defp supports_blank_create(backend) do
    with {:module, ^backend} <- Code.ensure_loaded(backend),
         true <- function_exported?(backend, :new, 1) do
      :ok
    else
      _ -> {:error, {:create_unsupported, backend}}
    end
  end

  defp create_from(ctx, path, kind, from) do
    with {:ok, source} <- resolve_template_path(ctx, from),
         :ok <- copy_template(source, path) do
      # The template was byte-copied to `path`, so a NEW file now exists on disk
      # — announce it so the workspace tree shows it without a manual refresh.
      broadcast_file_written(path)

      case Pool.open(pool(ctx), path, kind: kind) do
        {:ok, doc_id} ->
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
          |> filter_by_pattern(pattern, find_case_sensitive?(args), find_regex?(args))
          |> Enum.map(&element_to_match/1)
          |> limit_matches(find_limit(args))

        {:ok, %{"pattern" => pattern, "type" => type, "matches" => matches}}

      :fallback ->
        literal_find(editor, pattern, args)
    end
  end

  defp server_find_many(editor, patterns, type, args) do
    case maybe_elements(editor, type) do
      {:ok, nodes} ->
        typed_nodes = filter_by_type(nodes, type)
        case_sensitive? = find_case_sensitive?(args)
        regex? = find_regex?(args)
        limit = find_limit(args)

        results =
          Enum.map(patterns, fn pattern ->
            matches =
              typed_nodes
              |> filter_by_pattern(pattern, case_sensitive?, regex?)
              |> Enum.map(&element_to_match/1)
              |> limit_matches(limit)

            %{"pattern" => pattern, "type" => type, "matches" => matches}
          end)

        {:ok, %{"results" => results}}

      :fallback ->
        results =
          Enum.map(patterns, fn pattern ->
            case literal_find(editor, pattern, args) do
              {:ok, result} -> result
              {:error, error} -> %{"pattern" => pattern, "error" => error}
            end
          end)

        {:ok, %{"results" => results}}
    end
  end

  defp compact_find_response({:ok, %{} = result}, args),
    do: {:ok, compact_find_result(result, args)}

  defp compact_find_response(other, _args), do: other

  defp compact_find_result(%{} = result, args) do
    case map_field(result, ["results", :results]) do
      results when is_list(results) ->
        result
        |> delete_map_keys(["results", :results])
        |> Map.put("results", Enum.map(results, &compact_find_entry(&1, args)))

      _ ->
        compact_find_entry(result, args)
    end
  end

  defp compact_find_entry(%{} = entry, args) do
    matches = map_field(entry, ["matches", :matches])

    if is_list(matches) do
      pattern = map_field(entry, ["pattern", :pattern]) || get(args, ["pattern"]) || ""

      entry
      |> delete_map_keys(["matches", :matches])
      |> Map.put("matches", Enum.map(matches, &compact_find_match(&1, pattern, args)))
    else
      entry
    end
  end

  defp compact_find_entry(entry, _args), do: entry

  defp compact_find_match(%{} = match, pattern, args) do
    raw_text =
      match
      |> map_field(["text", :text])
      |> to_string()

    match = maybe_put_before_marker_ref(match, raw_text, args)

    if map_field(match, ["text_truncated", :text_truncated]) == true do
      match
    else
      full_text = compact_find_normalize_text(raw_text)

      text = compact_find_text(full_text, pattern, args)

      match =
        match
        |> delete_map_keys(["text", :text])
        |> Map.put("text", text)

      if String.length(full_text) > String.length(text) do
        Map.put(match, "text_truncated", true)
      else
        match
      end
    end
  end

  defp compact_find_match(match, _pattern, _args), do: match

  defp maybe_put_before_marker_ref(match, text, args) do
    marker = get(args, ["marker"])

    with marker when is_binary(marker) and marker != "" <- marker,
         {:ok, offset} <- literal_marker_offset(text, marker, args),
         {:ok, ref} <- canonical_before_marker_ref(map_field(match, ["ref", :ref]), offset) do
      match
      |> Map.put("marker", marker)
      |> Map.put("marker_offset", offset)
      |> Map.put("before_marker_ref", ref)
    else
      marker when is_binary(marker) and marker != "" ->
        match
        |> Map.put("marker", marker)
        |> Map.put("marker_found", false)

      _ ->
        match
    end
  end

  defp literal_marker_offset(text, marker, args) do
    case literal_marker_byte_offset(text, marker, find_case_sensitive?(args)) do
      {:ok, byte_index} -> {:ok, byte_index_to_codepoint_index(text, byte_index)}
      :error -> :error
    end
  end

  defp literal_marker_byte_offset(text, marker, true) do
    case :binary.match(text, marker) do
      {byte_index, _length} -> {:ok, byte_index}
      :nomatch -> :error
    end
  end

  defp literal_marker_byte_offset(text, marker, false) do
    with {:ok, regex} <- Regex.compile(Regex.escape(marker), "iu"),
         [{byte_index, _length} | _] <- Regex.run(regex, text, return: :index) do
      {:ok, byte_index}
    else
      _ -> :error
    end
  end

  defp byte_index_to_codepoint_index(text, byte_index) do
    text
    |> binary_part(0, byte_index)
    |> String.codepoints()
    |> length()
  rescue
    ArgumentError -> 0
  end

  defp canonical_before_marker_ref("hwp:" <> _ = ref, offset) when is_integer(offset) do
    with {:ok, decoded} <- Ecrits.Doc.Rhwp.Ref.decode(ref) do
      canonical_hwp_before_marker_ref(decoded, offset)
    else
      _ -> :error
    end
  end

  defp canonical_before_marker_ref(ref, offset) when is_binary(ref) and is_integer(offset) do
    with {:ok, decoded} <- Jason.decode(ref),
         section when is_integer(section) and section >= 0 <-
           int_field(decoded, ["section", :section], nil),
         cell when is_map(cell) <- map_field(decoded, ["cell", :cell]) || %{},
         paragraph when is_integer(paragraph) and paragraph >= 0 <-
           int_field(
             cell,
             ["parentParaIndex", :parentParaIndex],
             int_field(decoded, ["paragraph", :paragraph], nil)
           ) do
      marker_ref = %{"section" => section, "paragraph" => paragraph, "offset" => offset}

      marker_ref =
        case canonical_cell_path(decoded, cell) do
          [_ | _] = cell_path -> Map.put(marker_ref, "cellPath", cell_path)
          _no_cell -> marker_ref
        end

      {:ok, Jason.encode!(marker_ref)}
    else
      _ -> :error
    end
  end

  defp canonical_before_marker_ref(_ref, _offset), do: :error

  defp canonical_hwp_before_marker_ref(
         %{kind: :char, sec: section, para: paragraph, off: base_offset},
         offset
       ) do
    {:ok,
     Jason.encode!(%{
       "section" => section,
       "paragraph" => paragraph,
       "offset" => base_offset + offset
     })}
  end

  defp canonical_hwp_before_marker_ref(
         %{
           kind: :cell_char,
           sec: section,
           para: paragraph,
           control: control,
           cell: cell,
           cell_para: cell_paragraph,
           off: base_offset
         },
         offset
       ) do
    {:ok,
     Jason.encode!(%{
       "section" => section,
       "paragraph" => paragraph,
       "offset" => base_offset + offset,
       "cellPath" => [
         %{
           "controlIndex" => control,
           "cellIndex" => cell,
           "cellParaIndex" => cell_paragraph
         }
       ]
     })}
  end

  defp canonical_hwp_before_marker_ref(_decoded, _offset), do: :error

  defp canonical_cell_path(ref, cell) do
    path =
      map_field(ref, ["cellPath", :cellPath, "cell_path", :cell_path]) ||
        map_field(cell, ["cellPath", :cellPath, "cell_path", :cell_path])

    case path do
      [_ | _] = steps ->
        case steps |> Enum.map(&canonical_cell_path_step/1) |> Enum.reject(&is_nil/1) do
          [] -> nil
          normalized -> normalized
        end

      _ ->
        case canonical_cell_path_step(cell) do
          nil -> nil
          step -> [step]
        end
    end
  end

  defp canonical_cell_path_step(step) when is_map(step) do
    control = int_field(step, ["controlIndex", :controlIndex, "control", :control], nil)
    cell = int_field(step, ["cellIndex", :cellIndex], nil)
    paragraph = int_field(step, ["cellParaIndex", :cellParaIndex], nil)

    if Enum.all?([control, cell, paragraph], &(is_integer(&1) and &1 >= 0)) do
      %{
        "controlIndex" => control,
        "cellIndex" => cell,
        "cellParaIndex" => paragraph
      }
    end
  end

  defp canonical_cell_path_step(_step), do: nil

  defp compact_find_text(text, pattern, args) do
    if String.length(text) <= @find_text_limit do
      text
    else
      index = compact_find_snippet_index(text, pattern, args)
      radius = div(@find_text_limit, 2)
      max_start = max(String.length(text) - @find_text_limit, 0)
      start = min(max(index - radius, 0), max_start)
      finish = min(start + @find_text_limit, String.length(text))
      prefix = if start > 0, do: "...", else: ""
      suffix = if finish < String.length(text), do: "...", else: ""

      prefix <> String.slice(text, start, finish - start) <> suffix
    end
  end

  defp compact_find_snippet_index(_text, pattern, _args) when pattern in [nil, ""], do: 0

  defp compact_find_snippet_index(text, pattern, args) do
    pattern = to_string(pattern)

    if find_regex?(args) do
      with {:ok, regex} <-
             Regex.compile(pattern, if(find_case_sensitive?(args), do: "", else: "i")),
           [{byte_index, _length} | _] <- Regex.run(regex, text, return: :index) do
        byte_index_to_grapheme_index(text, byte_index)
      else
        _ -> literal_find_snippet_index(text, pattern, args)
      end
    else
      literal_find_snippet_index(text, pattern, args)
    end
  end

  defp literal_find_snippet_index(text, pattern, args) do
    haystack = if find_case_sensitive?(args), do: text, else: String.downcase(text)
    needle = if find_case_sensitive?(args), do: pattern, else: String.downcase(pattern)

    case :binary.match(haystack, needle) do
      {byte_index, _length} -> byte_index_to_grapheme_index(text, byte_index)
      :nomatch -> 0
    end
  end

  defp byte_index_to_grapheme_index(text, byte_index) do
    text
    |> binary_part(0, byte_index)
    |> String.length()
  rescue
    ArgumentError -> 0
  end

  defp compact_find_normalize_text(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp delete_map_keys(map, keys) do
    Enum.reduce(keys, map, fn key, acc -> Map.delete(acc, key) end)
  end

  defp server_read_nearby(editor, args) do
    ref = get(args, ["ref"])
    nearby = normalize_nearby(get(args, ["nearby"]))

    case Editor.elements(editor) do
      {:ok, nodes} when is_list(nodes) ->
        # Runs (`…/pN/rM`) duplicate their text_frame/cell text, so a ±N window
        # around a target fills with the target's OWN run fragments instead of real
        # siblings. Drop them from the read window (the raw `nodes` are kept for the
        # table helpers, which key on cells, not runs). (#56)
        matches =
          nodes
          |> Enum.map(&element_to_match/1)
          |> Enum.reject(&(Map.get(&1, "type") == "run"))

        read_nearby_from_matches(nodes, matches, ref, nearby)

      {:error, reason} ->
        {:error, error_json(reason)}
    end
  end

  defp read_nearby_from_matches(nodes, matches, ref, nearby) do
    ref_string = ref_to_string(ref)
    candidates = read_ref_candidates(ref)

    resolved =
      Enum.find_value(candidates, fn candidate ->
        case Enum.find_index(matches, &(Map.get(&1, "ref") == candidate)) do
          nil -> nil
          idx -> {candidate, idx}
        end
      end)

    case resolved do
      nil ->
        case Enum.find(candidates, &table_key_from_ref/1) do
          nil ->
            {:error, error_json({:not_found, "ref not found"})}

          table_ref ->
            case compact_table_from_nodes(nodes, table_ref, nearby) do
              {:ok, result} ->
                {:ok,
                 result
                 |> Map.put("ref", ref_string)
                 |> maybe_put("resolved_ref", if(table_ref != ref_string, do: table_ref))}

              error ->
                error
            end
        end

      {resolved_ref, idx} ->
        target = Enum.at(matches, idx)

        if Map.get(target, "type") == "slide" do
          # Reading a pptx slide: a flat ±N window only spans the slide's first few
          # shapes. Aggregate the WHOLE slide instead — every text_frame/cell/shape
          # under it, in slide order — so one doc.read returns the full slide (#56).
          {:ok, slide_read(matches, resolved_ref, ref_string, target)}
        else
          before_n = Map.get(nearby, "before", 2)
          after_n = Map.get(nearby, "after", 2)
          start = max(0, idx - before_n)
          count = before_n + 1 + after_n
          elements = matches |> Enum.slice(start, count) |> Enum.map(&nearby_element/1)

          base =
            %{
              "ref" => ref_string,
              "target" => nearby_element(target),
              "elements" => elements,
              "text" => Map.get(target, "text") || ""
            }
            |> maybe_put("resolved_ref", if(resolved_ref != ref_string, do: resolved_ref))

          if Map.get(target, "type") == "cell" or table_key_from_ref(resolved_ref) do
            {:ok, Map.merge(base, table_nearby(nodes, target, nearby))}
          else
            {:ok, base}
          end
        end
    end
  end

  # Aggregate a whole slide's text: every text-bearing leaf (text_frame/cell/shape)
  # whose ref is nested under the slide, joined in document order. The slide's own
  # `target.text` (just the slide name) is replaced with this aggregate so a single
  # doc.read on a `page[<name>]` ref returns the entire slide (#56).
  defp slide_read(matches, slide_ref, ref_string, target) do
    prefix = slide_ref <> "/"

    leaves =
      Enum.filter(matches, fn m ->
        ref = Map.get(m, "ref")

        is_binary(ref) and String.starts_with?(ref, prefix) and
          Map.get(m, "type") in ["text_frame", "cell", "shape"] and
          (Map.get(m, "text") || "") != ""
      end)

    text = Enum.map_join(leaves, "\n", &(Map.get(&1, "text") || ""))

    %{
      "ref" => ref_string,
      "target" => Map.put(nearby_element(target), "text", text),
      "elements" => Enum.map(leaves, &nearby_element/1),
      "text" => text
    }
    |> maybe_put("resolved_ref", if(slide_ref != ref_string, do: slide_ref))
  end

  defp nearby_element(match) do
    match
    |> Map.take(["ref", "text", "type", "row", "col", "context"])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_nearby(%{} = nearby) do
    %{
      "before" => bounded_int(get(nearby, ["before"]), 2, 0, 10),
      "after" => bounded_int(get(nearby, ["after"]), 2, 0, 10),
      "row" => get(nearby, ["row"]) != false,
      "column" => get(nearby, ["column"]) == true,
      "headers" => get(nearby, ["headers"]) != false
    }
  end

  defp normalize_nearby(_nearby),
    do: %{"before" => 2, "after" => 2, "row" => true, "column" => false, "headers" => true}

  defp bounded_int(value, _default, min_value, max_value)
       when is_integer(value) and value >= min_value,
       do: min(value, max_value)

  defp bounded_int(_value, default, _min_value, _max_value), do: default

  defp read_ref_candidates(ref) do
    ([ref_to_string(ref)] ++ parent_read_refs(ref))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp parent_read_refs(%{} = ref) do
    ref
    |> parent_read_ref_maps()
    |> Enum.map(&ref_to_string/1)
  end

  defp parent_read_refs(ref) when is_binary(ref) do
    trimmed = String.trim(ref)

    json_refs =
      if String.starts_with?(trimmed, "{") do
        case Jason.decode(trimmed) do
          {:ok, %{} = decoded} -> parent_read_refs(decoded)
          _ -> []
        end
      else
        []
      end

    json_refs ++ hwp_parent_read_refs(trimmed) ++ office_parent_read_refs(trimmed)
  end

  defp parent_read_refs(_ref), do: []

  defp parent_read_ref_maps(%{} = ref) do
    cell = map_field(ref, ["cell", :cell])

    cond do
      is_map(cell) ->
        sec = int_field(ref, ["section", :section, "sectionIndex", :sectionIndex], 0)

        para =
          int_field(
            cell,
            ["parentParaIndex", :parentParaIndex, "parentPara", :parentPara],
            int_field(ref, ["paragraph", :paragraph, "paragraphIndex", :paragraphIndex], nil)
          )

        control = int_field(cell, ["controlIndex", :controlIndex, "ctrlIdx", :ctrlIdx], nil)
        cell_index = int_field(cell, ["cellIndex", :cellIndex, "cellIdx", :cellIdx], nil)
        cell_para = int_field(cell, ["cellParaIndex", :cellParaIndex, "cellPara", :cellPara], 0)

        if is_integer(para) and is_integer(control) and is_integer(cell_index) do
          [
            %{
              "section" => sec,
              "paragraph" => para,
              "offset" => 0,
              "cell" => %{
                "parentParaIndex" => para,
                "controlIndex" => control,
                "cellIndex" => cell_index,
                "cellParaIndex" => cell_para
              }
            },
            %{"section" => sec, "paragraph" => para, "control" => control}
          ]
        else
          []
        end

      not is_nil(map_field(ref, ["paragraph", :paragraph, "paragraphIndex", :paragraphIndex])) ->
        sec = int_field(ref, ["section", :section, "sectionIndex", :sectionIndex], 0)
        para = int_field(ref, ["paragraph", :paragraph, "paragraphIndex", :paragraphIndex], nil)

        if is_integer(para) do
          [%{"section" => sec, "paragraph" => para, "offset" => 0}, "hwp:s#{sec}/p#{para}"]
        else
          []
        end

      true ->
        []
    end
  end

  defp hwp_parent_read_refs(ref) do
    cond do
      match =
          Regex.run(
            ~r/^hwp:s(\d+)\/p(\d+)\/tbl(\d+)\/cell(\d+)\/cp(\d+)\/c\d+\+\d+$/,
            ref
          ) ->
        [_all, sec, para, control, cell, cell_para] = match
        sec = String.to_integer(sec)
        para = String.to_integer(para)
        control = String.to_integer(control)
        cell = String.to_integer(cell)
        cell_para = String.to_integer(cell_para)

        [
          ref_to_string(%{
            "section" => sec,
            "paragraph" => para,
            "offset" => 0,
            "cell" => %{
              "parentParaIndex" => para,
              "controlIndex" => control,
              "cellIndex" => cell,
              "cellParaIndex" => cell_para
            }
          })
        ]

      match = Regex.run(~r/^hwp:s(\d+)\/p(\d+)\/c\d+\+\d+$/, ref) ->
        [_all, sec, para] = match
        sec = String.to_integer(sec)
        para = String.to_integer(para)

        [
          ref_to_string(%{"section" => sec, "paragraph" => para, "offset" => 0}),
          "hwp:s#{sec}/p#{para}"
        ]

      true ->
        []
    end
  end

  defp office_parent_read_refs(ref) do
    case Regex.run(~r/^(.*\/p\d+)\/r\d+$/, ref) do
      [_, paragraph_ref] -> [paragraph_ref]
      _ -> []
    end
  end

  defp compact_table_from_nodes(nodes, ref, nearby) do
    entries = table_entries(nodes)
    target_key = table_key_from_ref(ref) || target_key_from_entries(entries, ref)

    cond do
      is_nil(target_key) ->
        {:error, error_json({:invalid_ref, "ref is not a table/cell ref"})}

      true ->
        cells =
          entries
          |> Enum.filter(&(&1.type == "cell" and &1.table_key == target_key))
          |> Enum.map(&table_cell_json/1)

        if cells == [] do
          {:error, error_json({:not_found, "no cells for table ref"})}
        else
          {:ok,
           %{"ref" => ref_to_string(ref)}
           |> Map.merge(compact_table_payload(ref, target_key, cells, nil, nearby))}
        end
    end
  end

  defp table_nearby(nodes, target, nearby) do
    entries = table_entries(nodes)
    ref = Map.get(target, "ref")
    key = table_key_from_ref(ref) || target_key_from_entries(entries, ref)

    cells =
      entries
      |> Enum.filter(&(&1.type == "cell" and &1.table_key == key))
      |> Enum.map(&table_cell_json/1)

    if is_nil(key) or cells == [] do
      %{}
    else
      compact_table_payload(ref, key, cells, target, nearby)
    end
  end

  defp table_entries(nodes) do
    nodes
    |> Enum.map_reduce(nil, fn node, current_key ->
      type = node_type(node)
      ref = node_field(node, "ref")
      own_key = table_key_from_ref(ref)

      table_key =
        cond do
          type == "table" -> own_key || ref_to_string(ref)
          type == "cell" -> own_key || current_key
          type == "paragraph" -> nil
          true -> current_key
        end

      next_key =
        cond do
          type == "table" -> table_key
          type == "paragraph" -> nil
          true -> current_key
        end

      {%{
         node: node,
         type: type,
         ref: ref,
         ref_string: ref_to_string(ref),
         table_key: table_key
       }, next_key}
    end)
    |> elem(0)
  end

  defp target_key_from_entries(entries, ref) do
    ref_string = ref_to_string(ref)

    case Enum.find(entries, &(&1.ref_string == ref_string)) do
      nil -> nil
      entry -> entry.table_key
    end
  end

  defp table_cell_json(%{node: node, ref: ref} = entry) do
    row = node_field(node, "row")
    col = node_field(node, "col")
    match = element_to_match(node)
    writable = writable_table_cell?(match, row, col)

    %{
      "ref" => ref_to_string(ref),
      "row" => row,
      "col" => col,
      "text" => node_text(node),
      "writable" => writable
    }
    |> maybe_put("context", node_field(node, "context"))
    |> maybe_put("_table_key", entry.table_key)
  end

  defp compact_table_payload(ref, table_key, cells, target, nearby) do
    cells = cells |> Enum.map(&Map.delete(&1, "_table_key")) |> Enum.sort_by(&cell_sort_key/1)
    target_row = if target, do: Map.get(target, "row")
    target_col = if target, do: Map.get(target, "col")
    target_ref = ref_to_string(ref)

    table =
      %{
        "key" => table_key,
        "anchor" => table_anchor(table_key),
        "row_count" =>
          cells |> Enum.map(& &1["row"]) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length(),
        "col_count" =>
          cells |> Enum.map(& &1["col"]) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()
      }

    %{"table" => table}
    |> maybe_put(
      "table_headers",
      if(Map.get(nearby, "headers"), do: compact_headers(cells), else: nil)
    )
    |> maybe_put(
      "row_labels",
      if(Map.get(nearby, "headers"), do: compact_row_labels(cells, target_row), else: nil)
    )
    |> maybe_put(
      "row",
      if(Map.get(nearby, "row") and is_integer(target_row),
        do: cells |> Enum.filter(&(&1["row"] == target_row)) |> compact_cells(target_ref),
        else: nil
      )
    )
    |> maybe_put(
      "column",
      if(Map.get(nearby, "column") and is_integer(target_col),
        do: cells |> Enum.filter(&(&1["col"] == target_col)) |> compact_cells(target_ref),
        else: nil
      )
    )
  end

  defp cell_sort_key(cell), do: {cell["row"] || 0, cell["col"] || 0}

  defp compact_headers(cells) do
    header_row = table_header_row(cells)

    cells
    |> Enum.filter(&(&1["row"] == header_row))
    |> Enum.sort_by(&(&1["col"] || 0))
    |> Enum.map(&Map.take(&1, ["col", "text"]))
  end

  defp compact_row_labels(cells, target_row) do
    header_row = table_header_row(cells)
    label_col = table_label_col(cells)

    cells
    |> Enum.filter(&(&1["col"] == label_col and (&1["row"] || 0) > header_row))
    |> Enum.filter(fn cell ->
      text = cell["text"] |> to_string() |> String.trim()
      text != "" or cell["row"] == target_row
    end)
    |> Enum.sort_by(&(&1["row"] || 0))
    |> Enum.map(&Map.take(&1, ["row", "text"]))
  end

  defp table_header_row(cells) do
    cells
    |> Enum.map(& &1["row"])
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> 0 end)
  end

  defp table_label_col(cells) do
    cells
    |> Enum.map(& &1["col"])
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> 0 end)
  end

  defp compact_cells(cells, target_ref) do
    cells
    |> Enum.sort_by(&cell_sort_key/1)
    |> Enum.map(fn cell ->
      cell
      |> Map.take(["row", "col", "text", "type", "context", "writable"])
      |> maybe_put("ref", if(cell["writable"] or cell["ref"] == target_ref, do: cell["ref"]))
    end)
  end

  defp table_anchor(table_key) do
    case Regex.run(~r/^hwp:s(\d+):p(\d+):c(\d+)$/, to_string(table_key)) do
      [_, section, paragraph, control] ->
        %{
          "section" => String.to_integer(section),
          "paragraph" => String.to_integer(paragraph),
          "control" => String.to_integer(control)
        }

      _ ->
        %{"key" => table_key}
    end
  end

  defp writable_table_cell?(match, row, col) do
    text = match |> Map.get("text", "") |> to_string() |> String.trim()
    body_cell? = is_integer(row) and is_integer(col) and row > 0 and col > 0
    Map.get(match, "type") == "cell" and text == "" and (real_context?(match) or body_cell?)
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
      {:ok, matches} ->
        matches =
          matches
          |> Enum.map(&stringify/1)
          |> limit_matches(find_limit(args))

        {:ok, %{"pattern" => pattern, "matches" => matches}}

      {:error, reason} ->
        {:error, error_json(reason)}
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
  defp filter_by_type(nodes, "fillable"), do: Enum.filter(nodes, &fillable_node?/1)
  defp filter_by_type(nodes, "empty"), do: Enum.filter(nodes, &blank_node_text?/1)

  defp filter_by_type(nodes, "empty_cell"),
    do: Enum.filter(nodes, &(node_type(&1) == "cell" and blank_node_text?(&1)))

  defp filter_by_type(nodes, "filled_cell"),
    do: Enum.filter(nodes, &(node_type(&1) == "cell" and not blank_node_text?(&1)))

  defp filter_by_type(nodes, "formula_cell"),
    do: Enum.filter(nodes, &(node_type(&1) == "cell" and formula_node?(&1)))

  defp filter_by_type(nodes, type) when is_binary(type),
    do: Enum.filter(nodes, &(node_type(&1) == type))

  defp filter_by_pattern(nodes, nil, _cs, _regex), do: nodes
  defp filter_by_pattern(nodes, "", _cs, _regex), do: nodes

  defp filter_by_pattern(nodes, pattern, case_sensitive?, true) do
    case Regex.compile(pattern, if(case_sensitive?, do: "", else: "i")) do
      {:ok, regex} -> Enum.filter(nodes, &Regex.match?(regex, node_text(&1)))
      {:error, _reason} -> []
    end
  end

  defp filter_by_pattern(nodes, pattern, case_sensitive?, _regex) do
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
    match =
      %{
        "ref" => ref_to_string(node_field(node, "ref")),
        "text" => node_text(node),
        "type" => node_type(node)
      }
      |> maybe_put("row", node_field(node, "row"))
      |> maybe_put("col", node_field(node, "col"))
      |> maybe_put("context", node_field(node, "context"))
      |> maybe_put("formula", node_formula(node))
      |> maybe_put_office_metadata(node)

    maybe_put(match, "fillable_kind", fillable_kind(match))
  end

  defp node_type(node), do: node_field(node, "type")
  defp node_text(node), do: node_field(node, "text") || ""
  defp blank_node_text?(node), do: String.trim(node_text(node)) == ""
  defp formula_node?(node), do: String.trim(to_string(node_formula(node) || "")) != ""

  defp node_formula(node) do
    props = node_field(node, "props") || node_field(node, "properties") || %{}

    node_field(node, "formula") ||
      node_field(node, "Formula") ||
      node_field(props, "formula") ||
      node_field(props, "Formula")
  end

  defp maybe_put_office_metadata(match, node) do
    Enum.reduce(@office_element_metadata_fields, match, fn field, acc ->
      maybe_put(acc, field, node_field(node, field))
    end)
  end

  defp fillable_node?(node), do: fillable_match?(element_to_match(node))

  defp fillable_match?(match) do
    not is_nil(fillable_kind(match))
  end

  defp fillable_kind(match) do
    text = match |> Map.get("text", "") |> String.trim()
    type = Map.get(match, "type")

    cond do
      type == "cell" and text == "" and real_context?(match) -> "empty_cell"
      type in ["field", "form"] -> type
      placeholder_host?(type) -> placeholder_kind(text)
      true -> nil
    end
  end

  defp placeholder_host?(type), do: type in [nil, "", "paragraph", "cell"]

  defp placeholder_kind(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" or String.starts_with?(text, "※") -> nil
      String.contains?(text, "____") -> "underscore"
      String.contains?(text, "[]") -> "checkbox"
      Regex.match?(~r/^\s*[□☐]\s*/u, text) -> "checkbox"
      Regex.match?(~r/[-‐‑‒–—―－─]{4,}.*\(이하/u, text) -> "signature_line"
      Regex.match?(~r/\(\s{2,}\)/u, text) -> "paren_blank"
      Regex.match?(~r/[:：]\s{2,}[회년월일원%]/u, text) -> "inline_gap"
      Regex.match?(~r/[년월일]\s{2,}/u, text) -> "date_gap"
      String.ends_with?(text, ":") and String.length(text) <= 80 -> "trailing_label"
      true -> nil
    end
  end

  defp real_context?(match) do
    match
    |> Map.get("context", "")
    |> to_string()
    |> String.trim()
    |> Kernel.!=("")
  end

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
  defp find_regex?(args), do: get(args, ["regex"]) == true or get(args, ["all"]) == true

  defp find_limit(args) do
    case get(args, ["limit"]) do
      value when is_integer(value) and value > 0 -> min(value, 2000)
      _ -> nil
    end
  end

  defp limit_matches(matches, nil), do: matches
  defp limit_matches(matches, limit), do: Enum.take(matches, limit)

  defp table_key_from_ref(ref) when is_map(ref) do
    cond do
      is_map(map_field(ref, ["cell", :cell])) ->
        cell = map_field(ref, ["cell", :cell])
        sec = int_field(ref, ["section", :section, "sectionIndex", :sectionIndex], 0)

        para =
          int_field(cell, ["parentParaIndex", :parentParaIndex, "parentPara", :parentPara], nil)

        control = int_field(cell, ["controlIndex", :controlIndex, "ctrlIdx", :ctrlIdx], nil)
        table_key("hwp", sec, para, control)

      is_integer(map_field(ref, ["control", :control, "controlIndex", :controlIndex])) ->
        sec = int_field(ref, ["section", :section, "sectionIndex", :sectionIndex], 0)
        para = int_field(ref, ["paragraph", :paragraph, "paragraphIndex", :paragraphIndex], nil)
        control = int_field(ref, ["control", :control, "controlIndex", :controlIndex], nil)
        table_key("hwp", sec, para, control)

      true ->
        nil
    end
  end

  defp table_key_from_ref(ref) when is_binary(ref) do
    trimmed = String.trim(ref)

    cond do
      String.starts_with?(trimmed, "{") ->
        case Jason.decode(trimmed) do
          {:ok, decoded} -> table_key_from_ref(decoded)
          _ -> nil
        end

      match = Regex.run(~r/^(tbl\[[^\]]+\])(?:\/cell\[.*\])?$/, trimmed) ->
        Enum.at(match, 1)

      match = Regex.run(~r/^(sheet\[[^\]]+\])(?:\/cell\[.*\])?$/, trimmed) ->
        Enum.at(match, 1)

      match = Regex.run(~r/^hwp:s(\d+)\/p(\d+)\/tbl(\d+)/, trimmed) ->
        [_all, sec, para, control] = match

        table_key(
          "hwp",
          String.to_integer(sec),
          String.to_integer(para),
          String.to_integer(control)
        )

      true ->
        nil
    end
  end

  defp table_key_from_ref(_ref), do: nil

  defp table_key(_prefix, _sec, nil, _control), do: nil
  defp table_key(_prefix, _sec, _para, nil), do: nil
  defp table_key(prefix, sec, para, control), do: "#{prefix}:s#{sec}:p#{para}:c#{control}"

  defp map_field(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp int_field(map, keys, default) do
    case map_field(map, keys) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp ref_to_string(nil), do: nil
  defp ref_to_string(ref) when is_binary(ref), do: ref
  defp ref_to_string(%{} = ref), do: Jason.encode!(ref)
  defp ref_to_string(ref), do: to_string(ref)

  defp normalize_find_patterns(patterns) do
    patterns =
      Enum.map(patterns, fn
        pattern when is_binary(pattern) -> {:ok, pattern}
        %{} = entry -> find_pattern(entry, false)
        _other -> {:error, {:invalid_params, "patterns must be strings or pattern objects"}}
      end)

    case Enum.find(patterns, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, Enum.map(patterns, fn {:ok, pattern} -> pattern end)}
    end
  end

  # --- dispatch helpers ----------------------------------------------------

  # Route a tool against a document whose authority may be the server NIF
  # (`:server`) OR the browser WASM model (`:browser`, a doc open in a viewer).
  # `opts` carries `:browser` and `:server` closures; the right one runs based on
  # `Pool.route/2`. Tools that the browser hook can apply (read/find/edit) pass
  # both; server-only tools use `with_editor/3` (which falls back to the server
  # editor even for browser-backed docs — the structure is identical on open).
  defp route_doc(ctx, args, opts) do
    with {:ok, document} <- require_string(args, "document") do
      case canonical_document(ctx, document) do
        {:ok, document} ->
          case Keyword.get(opts, :authority) do
            :committed_server ->
              with_committed_server_editor(ctx, document, Keyword.fetch!(opts, :server))

            _normal_authority ->
              case route(ctx, document) do
                {:browser, lv} ->
                  Keyword.fetch!(opts, :browser).(lv)

                {:server, editor} ->
                  Keyword.fetch!(opts, :server).(editor)

                {:error, :not_found} ->
                  {:error, error_json({:document_not_found, document, known_documents(ctx)})}
              end
          end

        {:error, reason} ->
          {:error, error_json(reason)}
      end
    end
  end

  # Reopen the server twin from the durable file before a post-ACP lookup. The
  # browser-authority write path deliberately closes its old cold twin after
  # saving, while the server-authority path may leave one cached; handling both
  # cases here prevents either a stale browser or a stale pool editor from
  # supplying the requested marker ref.
  defp with_committed_server_editor(ctx, document, fun) when is_function(fun, 1) do
    with {:ok, path, kind} <- committed_document_path(ctx, document),
         :ok <- Pool.close_by_path(pool(ctx), path),
         {:ok, ^document} <-
           Pool.open(pool(ctx), path, kind: kind, document_id: document),
         {:server, editor} <- Pool.route(pool(ctx), document) do
      fun.(editor)
    else
      {:error, :not_found} ->
        {:error, error_json({:document_not_found, document, known_documents(ctx)})}

      {:error, reason} ->
        {:error, error_json(reason)}

      other ->
        {:error, error_json({:committed_document_unavailable, inspect(other)})}
    end
  end

  defp committed_document_path(ctx, document) do
    case Pool.info(pool(ctx), document) do
      {:ok, %{path: path, kind: kind}} when is_binary(path) and is_atom(kind) ->
        {:ok, path, kind}

      _missing_twin ->
        with ^document <- Map.get(ctx, :active_doc),
             path when is_binary(path) and path != "" <- Map.get(ctx, :document_path),
             {:ok, path} <- confine_path(ctx, path),
             kind when is_atom(kind) <- kind_from_path(path) do
          {:ok, path, kind}
        else
          _ -> {:error, :not_found}
        end
    end
  end

  # The `document` arg may arrive as something other than the canonical Pool id:
  # the picks block's stamped id, a workspace-relative path, a bare basename, or
  # "active". Resolve all of those here so EVERY doc tool accepts what an agent
  # reasonably passes; on a miss, fail with the open-document catalog so the
  # agent self-corrects in one step instead of a doc.context round-trip (#32 —
  # observed live: "local-* id not accepted. Trying given document name." both
  # failed before this resolver existed).
  defp canonical_document(ctx, document) do
    cond do
      document in ["active", "current"] ->
        case Map.get(ctx, :active_doc) do
          id when is_binary(id) and id != "" -> {:ok, id}
          _ -> {:error, {:document_not_found, document, known_documents(ctx)}}
        end

      known_document_id?(ctx, document) ->
        {:ok, document}

      true ->
        with :error <- match_document_by_path(ctx, document),
             :error <- open_document_from_disk(ctx, document) do
          {:error, {:document_not_found, document, known_documents(ctx)}}
        end
    end
  end

  # #34 — the PATH is the stable document handle: open, closed, or never
  # opened, the same path resolves. A document arg that is a real document
  # file inside the workspace is opened on demand (ids are deterministic over
  # (path, kind), so a closed doc reopens under its old id for free). Gated on
  # a known document extension and the workspace confinement — a junk string
  # or an outside path falls through to the catalog error instead.
  defp open_document_from_disk(ctx, document) do
    with {:ok, path} <- confine_path(ctx, document),
         kind when not is_nil(kind) <- kind_from_path(path),
         true <- File.regular?(path),
         {:ok, id} <- Pool.open(pool(ctx), path, kind: kind) do
      {:ok, id}
    else
      _ -> :error
    end
  end

  defp known_document_id?(ctx, document) do
    active_office_document_id?(ctx, document) or
      session_viewer(ctx, document) != nil or
      match?({:ok, _}, Pool.info(pool(ctx), document))
  end

  defp active_office_document_id?(ctx, document) do
    case Map.get(ctx, :document_path) do
      path when is_binary(path) ->
        Map.get(ctx, :active_doc) == document and path_kind(path) in ["docx", "pptx", "xlsx"]

      _ ->
        false
    end
  end

  # Match a path-ish alias against the pool entries: exact path, path suffix
  # ("drafts/x.hwp"), or basename. Ambiguous basenames prefer the caller's
  # active doc, then the first match.
  defp match_document_by_path(ctx, document) do
    normalized = String.trim_leading(document, "./")

    matches =
      Enum.filter(Pool.list(pool(ctx)), fn %{path: path} ->
        path == document or
          String.ends_with?(path, "/" <> normalized) or
          Path.basename(path) == normalized
      end)

    case matches do
      [] ->
        :error

      [%{id: id}] ->
        {:ok, id}

      many ->
        active = Map.get(ctx, :active_doc)

        case Enum.find(many, &(&1.id == active)) do
          %{id: id} -> {:ok, id}
          nil -> {:ok, hd(many).id}
        end
    end
  end

  defp known_documents(ctx) do
    Enum.map(Pool.list(pool(ctx)), fn entry ->
      %{"document" => entry.id, "path" => entry.path, "kind" => to_string(entry.kind)}
    end)
  end

  # The wasm/NIF routing decision (design invariant 4). The per-workspace
  # `Ecrits.Workspace.Session` owns the `viewers` map and decides browser-vs-not:
  # a doc with a live human viewer routes `{:browser, lv}` (its WASM model). The
  # server-editor side is resolved from the ctx's OWN Pool (`pool(ctx)`), so the
  # decision (Session) and the Editor registry (this caller's pool) compose
  # cleanly. A bare pool-only context (no `:session_path`) has no viewers, so it
  # routes straight to its Pool's server Editor.
  defp route(ctx, document) do
    case session_viewer(ctx, document) do
      lv when is_pid(lv) -> {:browser, lv}
      nil -> Pool.route(pool(ctx), document)
    end
  end

  defp session_viewer(ctx, document) do
    case Map.get(ctx, :session_path) do
      path when is_binary(path) and path != "" -> Session.viewer(path, document)
      _ -> nil
    end
  end

  # For a browser-backed doc, deliver a structural edit op to the owning LiveView
  # and wait for the WASM apply result (design §6.2).
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
  # An inline `insert_picture` is run through the picture producer first, which
  # reads `src` and attaches the image bytes as `image_base64` (the browser can't
  # read the server filesystem). Gated to the inline form, so the office slide
  # form (`page` set) is left untouched.
  defp normalize_browser_op(op) do
    with {:ok, atom_op} <- Ecrits.Doc.Op.normalize(op),
         {:ok, produced} <- Ecrits.Doc.Rhwp.Image.for_browser(atom_op) do
      {:ok, Map.new(produced, fn {k, v} -> {to_string(k), v} end)}
    end
  end

  defp do_browser_write(lv, args, op) do
    case browser_call(lv, args, :edit, %{op: op}) do
      {:ok, %{} = applied} ->
        # Pass the editor's per-op EVIDENCE through (replaced, inserted,
        # rows_after/cols_after, ...) — a bare {ok:true} is how an agent once
        # claimed "10 rows added" when 1 was: with rows_after in the reply the
        # model sees the structural effect and self-corrects.
        {:ok, Map.merge(browser_write_evidence(applied), %{"ok" => true})}

      {:error, _reason} = error ->
        error
    end
  end

  # Scalar result fields from the browser editor's reply, minus plumbing keys.
  @browser_reply_plumbing ~w(ok request_id ref document_id)
  defp browser_write_evidence(%{} = applied) do
    applied
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.filter(fn {k, v} ->
      k not in @browser_reply_plumbing and (is_number(v) or is_binary(v) or is_boolean(v))
    end)
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
    validation_failures = Enum.map(bad_results, fn {:error, res} -> res end)

    if normalized_ops == [] do
      batch_reply(
        batch_result(
          validation_failures,
          0,
          length(validation_failures),
          get(args, ["verbose"]) == true
        )
      )
    else
      case browser_call(lv, args, :edit, %{ops: normalized_ops}) do
        {:ok, %{} = applied} ->
          batch_reply(
            merge_browser_batch(applied, validation_failures, get(args, ["verbose"]) == true)
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Merge the browser's batch result with any locally-rejected (un-normalisable)
  # ops so `failed`/`results` account for EVERY op the agent submitted.
  defp merge_browser_batch(applied, validation_failures, verbose) do
    results =
      (Map.get(applied, "results") || Map.get(applied, :results) || []) ++ validation_failures

    applied_n = Map.get(applied, "applied") || Map.get(applied, :applied) || 0

    failed_n =
      (Map.get(applied, "failed") || Map.get(applied, :failed) || 0) + length(validation_failures)

    batch_result(results, applied_n, failed_n, verbose)
  end

  # doc.set for a browser-backed doc: deliver the property set to the viewer's
  # authoritative WASM model. The ref (doc.find's
  # positional ref, incl. cell address) is parsed browser-side by the SAME parseRef
  # the edit verbs use, so there is no ref-format round-trip mismatch with the
  # server `hwp:` grammar — the reason a server-routed set rejected find's ref.
  defp browser_set(lv, args, ref, props) do
    case browser_call(lv, args, :set, %{ref: ref, props: props}) do
      {:ok, %{} = applied} ->
        {:ok, %{"ok" => true} |> maybe_put("invalidated", Map.get(applied, "invalidated"))}

      {:error, _reason} = error ->
        error
    end
  end

  # Batch doc.set for a browser-backed doc: hand the `sets` array to the hook's
  # applyAgentSetBatch in ONE round-trip (each set addresses a fixed cell/run, so
  # order is irrelevant). The hook applies all of them best-effort and finishes
  # (re-renders) once, returning {applied, failed, results}.
  defp browser_set_batch(lv, args, sets) do
    case browser_call(lv, args, :set, %{sets: sets}) do
      {:ok, %{} = applied} ->
        batch_reply(merge_browser_batch(applied, [], get(args, ["verbose"]) == true))

      {:error, _reason} = error ->
        error
    end
  end

  # doc.get for an open Office document must inspect the browser WASM model, not
  # the headless server copy. HWP keeps the existing server metadata path because
  # the HWP browser hook does not expose `get`.
  defp get_with_editor_or_office_browser(ctx, args, browser_payload, server_fun) do
    with {:ok, document} <- require_string(args, "document") do
      case canonical_document(ctx, document) do
        {:ok, document} ->
          case route(ctx, document) do
            {:browser, lv} ->
              if office_document?(ctx, document) do
                browser_get(lv, args, browser_payload)
              else
                with_server_editor(ctx, document, server_fun)
              end

            {:server, editor} ->
              server_fun.(editor)

            {:error, :not_found} ->
              {:error, error_json({:document_not_found, document, known_documents(ctx)})}
          end

        {:error, reason} ->
          {:error, error_json(reason)}
      end
    end
  end

  defp office_document?(ctx, document) do
    case Pool.info(pool(ctx), document) do
      {:ok, %{kind: kind}} ->
        kind in [:docx, :pptx, :xlsx]

      _ ->
        active_browser_office_document?(ctx, document)
    end
  end

  defp active_browser_office_document?(ctx, document) do
    Map.get(ctx, :active_doc) == document and
      session_viewer(ctx, document) != nil and
      path_kind(Map.get(ctx, :document_path)) in ["docx", "pptx", "xlsx"]
  end

  defp browser_get(lv, args, payload) do
    case browser_call(lv, args, :get, payload) do
      {:ok, %{} = result} -> {:ok, result}
      {:error, _reason} = error -> error
    end
  end

  # doc.save for an open (browser) doc: round-trip the viewer for its current
  # edited bytes, then write them to `path`.
  defp save_browser(lv, args, path) do
    case browser_call(lv, args, :save, %{}) do
      {:ok, %{} = res} ->
        with {:ok, bytes} <- ByteSpool.decode(res),
             :ok <- File.write(path, bytes) do
          broadcast_file_written(path)
          {:ok, %{"ok" => true}}
        else
          {:error, :missing_bytes} ->
            {:error, error_json({:save_failed, "viewer returned no bytes"})}

          {:error, :invalid_base64} ->
            {:error, error_json({:save_failed, "viewer returned invalid base64"})}

          {:error, reason} ->
            {:error, error_json(reason)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # doc.save for a headless (server NIF) doc: Ehwp.export + write, via the Editor.
  defp save_server(editor, info, path, ctx) do
    opts = [format: save_format(info.kind), path: path]

    result =
      case editor_owner(ctx) do
        nil ->
          Editor.save(editor, opts)

        owner ->
          snapshot = Editor.dirty_snapshot(editor)

          case Editor.owner_status(snapshot, owner) do
            :clean -> Editor.save(editor, opts)
            :exclusive -> Editor.save_if_owner(editor, snapshot, opts)
            :mixed -> {:error, :document_has_mixed_unsaved_writers}
            :other -> {:error, :document_has_other_unsaved_writers}
          end
      end

    case result do
      :ok ->
        broadcast_file_written(path)
        {:ok, %{"ok" => true}}

      {:ok, %{} = _saved} ->
        broadcast_file_written(path)
        {:ok, %{"ok" => true}}

      {:error, reason} ->
        {:error, error_json(reason)}

      {:skipped, reason} ->
        {:error, error_json({:save_raced, reason})}
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
  defp save_format(:xlsx), do: :xlsx
  defp save_format(_kind), do: :hwp

  # Synchronous request/reply against the viewing LiveView. The LiveView's
  # `{:doc_browser_request, ...}` handler pushes the op to the WasmHwpEditor hook,
  # the hook applies it to the WASM model and replies, and the LiveView relays the
  # result back to us as `{:doc_browser_reply, ref, result}`. Runs in the agent's
  # MCP process (NOT the LiveView), so we use a tagged send + selective receive.
  defp browser_call(lv, _args, verb, payload) when is_pid(lv) do
    case BrowserBridge.call(lv, verb, payload) do
      {:ok, result} -> {:ok, stringify(result)}
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  defp with_server_editor(ctx, document, fun) do
    case Pool.with_doc(pool(ctx), document, fun) do
      {:error, :not_found} -> {:error, error_json(:not_found)}
      other -> other
    end
  end

  defp write_result({:ok, applied}) do
    {:ok,
     %{"ok" => true}
     |> maybe_put("invalidated", Map.get(applied, :invalidated))
     # Native engine result (e.g. insert_table returns {paraIdx, controlIdx} —
     # the agent needs it to address the new table's cells with a follow-up edit).
     |> maybe_put("native", Map.get(applied, :native))}
  end

  defp write_result({:error, reason}), do: {:error, error_json(reason)}

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

  # Server-arm batch doc.edit: apply each op via Editor.apply best-effort,
  # collect per-op results, and return the same shape the browser batch does.
  # A per-op failure is recorded but does NOT abort the rest.
  defp edit_batch_server(editor, ops, verbose, editor_opts) do
    {results, applied, failed} =
      Enum.reduce(ops, {[], 0, 0}, fn op, {acc, ok_n, bad_n} ->
        op_ref = op_ref(op)

        case Editor.apply(editor, op, editor_opts) do
          {:ok, _applied_map} ->
            {[%{"ref" => op_ref, "ok" => true} | acc], ok_n + 1, bad_n}

          {:error, reason} ->
            {[%{"ref" => op_ref, "error" => error_json(reason)} | acc], ok_n, bad_n + 1}
        end
      end)

    batch_reply(batch_result(Enum.reverse(results), applied, failed, verbose))
  end

  # Server-arm batch doc.set: apply each {ref, props} via Editor.set best-effort.
  defp set_batch_server(editor, sets, editor_opts) do
    {results, applied, failed} =
      Enum.reduce(sets, {[], 0, 0}, fn entry, {acc, ok_n, bad_n} ->
        ref = get(entry, ["ref"])
        props = get(entry, ["props"])

        case set_one_server(editor, ref, props, editor_opts) do
          {:ok, _applied_map} ->
            {[%{"ref" => ref, "ok" => true} | acc], ok_n + 1, bad_n}

          {:error, reason} ->
            {[%{"ref" => ref, "error" => error_json(reason)} | acc], ok_n, bad_n + 1}
        end
      end)

    batch_reply(batch_result(Enum.reverse(results), applied, failed, false))
  end

  # One server set with the same ref/props validation the single path uses, so a
  # malformed entry in the batch is an :invalid_params error for THAT entry only.
  defp set_one_server(_editor, ref, _props, _editor_opts) when not is_binary(ref) or ref == "",
    do: {:error, {:invalid_params, "ref (non-empty string) is required"}}

  defp set_one_server(_editor, _ref, props, _editor_opts) when not is_map(props),
    do: {:error, {:invalid_params, "props (object) is required"}}

  defp set_one_server(editor, ref, props, editor_opts),
    do: Editor.set(editor, ref, props, editor_opts)

  defp editor_write_opts(ctx) do
    [owner: editor_owner(ctx)]
  end

  defp editor_owner(ctx) do
    owner =
      Map.take(ctx, [:agent_id, :instance_id, :turn_id])

    if map_size(owner) == 3 and
         Enum.all?(Map.values(owner), &(is_binary(&1) and &1 != "")) do
      owner
    end
  end

  # The ref carried on an op (for the per-op result label); nil when absent.
  defp op_ref(op) when is_map(op), do: get(op, ["ref"])
  defp op_ref(_op), do: nil

  # The shared best-effort batch result shape (browser + server use it):
  # `applied`/`failed` counts plus per-op results.
  defp batch_result(results, applied, failed, verbose) do
    failed_results = Enum.filter(results, &Map.has_key?(&1, "error"))

    %{"ok" => failed == 0, "applied" => applied, "failed" => failed}
    |> maybe_put("results", if(verbose, do: results))
    |> maybe_put("failed_results", if(failed_results == [], do: nil, else: failed_results))
  end

  defp batch_reply(%{"failed" => failed} = result) when failed > 0, do: {:error, result}
  defp batch_reply(result), do: {:ok, result}

  # Live property values for doc.get, best-effort: nil when the engine can't read
  # them yet, so the reflective discovery still stands.
  defp best_effort_values(editor, ref, props) do
    native_values =
      case Editor.get(editor, ref, nil) do
        {:ok, values} -> stringify(values)
        {:error, _reason} -> %{}
      end

    element_values = element_values_for_ref(editor, ref)

    case Map.merge(element_values, native_values) do
      values when values == %{} -> nil
      values -> narrow_get_values(values, props)
    end
  end

  defp element_values_for_ref(editor, ref) do
    case Editor.elements(editor) do
      {:ok, nodes} when is_list(nodes) ->
        nodes
        |> Enum.map(&stringify/1)
        |> Enum.find(%{}, &(ref_to_string(Map.get(&1, "ref")) == ref))
        |> Map.drop(["ref", "type"])

      _ ->
        %{}
    end
  end

  defp narrow_get_values(values, props) when is_list(props) and props != [] do
    wanted = MapSet.new(Enum.map(props, &to_string/1))
    Map.filter(values, fn {key, _value} -> MapSet.member?(wanted, key) end)
  end

  defp narrow_get_values(values, _props), do: values

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
      "property_types" => meta["property_types"] || %{},
      "settable" => meta["properties"],
      "children" => meta["children"] || []
    }
  end

  # Current document only. The active document is per-CALLER (design invariant 3 /
  # Phase 3): the agent's OWN active doc, read from the AgentLive
  # (`ctx.active_doc`) — there is no global active anymore. `WorkspaceLive` follows
  # the user's open doc onto the foreground agent live (`update_options`), so
  # `doc.context` returns the doc this agent is bound to.
  #
  # We resolve ONLY the explicitly-set active doc — no "first" or "sole doc"
  # guessing and no full `documents` catalog in the response. If the workspace
  # still knows a selected `document_path`, `current_document.document` uses that
  # path handle so the agent can explicitly open/read the viewed document through
  # MCP, not through prompt text.
  defp context_json(ctx) do
    %{"current_document" => current_document_json(ctx, current_document_entry(ctx))}
  end

  defp current_document_entry(ctx) do
    pool = pool(ctx)

    case active_doc_id(ctx, pool) do
      active_id when is_binary(active_id) and active_id != "" ->
        case Pool.info(pool, active_id) do
          {:ok, active} ->
            active

          {:error, _} ->
            active_browser_document_entry(ctx, active_id)
        end

      _ ->
        nil
    end
  end

  # The active doc for THIS call is ALWAYS the per-caller `ctx.active_doc`: in an
  # agent context (design invariant 3) that is the agent's OWN active doc, read
  # from the AgentLive, so two agents never see each other's. The global
  # `Pool.active` is GONE (design Phase 3): a bare pool-only context (legacy mount
  # / test) that sets no `:active_doc` simply reports no active document.
  defp active_doc_id(ctx, _pool), do: Map.get(ctx, :active_doc)

  defp active_browser_document_entry(ctx, active_id) do
    with path when is_binary(path) and path != "" <- Map.get(ctx, :document_path),
         kind when kind in ["docx", "pptx", "xlsx"] <- path_kind(path) do
      %{id: active_id, path: path, kind: String.to_atom(kind), backing: :browser}
    else
      _ -> nil
    end
  end

  # Already-structured error maps (e.g. `enforce_ownership` -> forbidden) pass
  # through unchanged so the uniform `else error_json/1` wrapping never re-wraps a
  # map the MCP server already surfaces as structured JSON content.
  defp error_json(%{} = structured), do: structured

  defp error_json({:not_supported, reason}),
    do: %{"not_supported" => true, "reason" => to_string(reason)}

  defp error_json(:not_found), do: %{"error" => "not_found"}

  defp error_json({:unsupported_kind, kind}),
    do: %{"error" => "unsupported_kind", "kind" => to_string(kind)}

  defp error_json({:template_not_found, from}),
    do: %{"error" => "template_not_found", "from" => from}

  defp error_json({:clone_failed, reason}),
    do: %{"error" => "clone_failed", "reason" => inspect(reason)}

  defp error_json({:create_failed, reason}),
    do: %{"error" => "create_failed", "reason" => inspect(reason)}

  defp error_json({:create_unsupported, backend}),
    do: %{"error" => "create_unsupported", "backend" => inspect(backend)}

  defp error_json({:invalid_params, message}),
    do: %{"error" => "invalid_params", "message" => to_string(message)}

  defp error_json({:invalid_op, message}),
    do: %{"error" => "invalid_op", "message" => to_string(message)}

  defp error_json(:read_only),
    do: %{
      "error" => "read_only",
      "message" => "read-only session — switch access to Ask/Full workspace to edit/save"
    }

  defp error_json({:outside_workspace, root}),
    do: %{
      "error" => "outside_workspace",
      "message" => "path must stay within the workspace root: #{root}",
      "workspace_root" => root
    }

  defp error_json({:document_not_found, document, open_documents}) do
    %{
      "error" => "document_not_found",
      "document" => document,
      "message" =>
        "unknown document id/path. Use one of open_documents' `document` ids " <>
          "(or its path/basename), or doc_open a new path.",
      "open_documents" => open_documents
    }
  end

  defp error_json(reason) when is_atom(reason), do: %{"error" => to_string(reason)}
  defp error_json(reason), do: %{"error" => inspect(reason)}

  defp entry_json(%{} = entry) do
    %{
      "document" => entry.id,
      "name" => document_name(entry.path),
      "kind" => to_string(entry.kind),
      "path" => entry.path,
      "backing" => to_string(entry.backing)
    }
  end

  defp current_document_json(_ctx, %{} = active) do
    active
    |> entry_json()
    |> Map.put("active", true)
  end

  defp current_document_json(ctx, nil) do
    case Map.get(ctx, :document_path) do
      path when is_binary(path) and path != "" ->
        %{
          "document" => path,
          "name" => document_name(path),
          "kind" => path_kind(path),
          "path" => path,
          "backing" => nil,
          "active" => true
        }

      _ ->
        nil
    end
  end

  defp document_name(path) when is_binary(path) and path != "", do: Path.basename(path)
  defp document_name(_path), do: nil

  defp path_kind(path) when is_binary(path) do
    case Path.extname(path) do
      "." <> ext when ext != "" -> String.downcase(ext)
      _ -> nil
    end
  end

  defp pool(ctx), do: Map.get(ctx, :pool, Ecrits.Doc.Pool)

  # Access-control guards (security review #1): the doc.* tools run in-process and
  # bypass the agent CLI sandbox, so they must honour the workspace access setting
  # themselves. `:read_only` is set from the agent's sandbox == "read-only"
  # (workspace_live.ex access controls); `:session_path` is the workspace root.

  # Refuse mutating tools in a read-only session.
  defp enforce_writable(ctx) do
    if Map.get(ctx, :read_only, false), do: {:error, :read_only}, else: :ok
  end

  # Confine a caller-supplied path to the workspace root so a prompt-injected path
  # can't open/create/save outside the workspace. A bare pool-only context (no
  # `:session_path`) is the legacy unisolated path and is left unconstrained.
  #
  # The workspace root is the agent's CWD (acp_stream working_dir == workspace_root
  # == session_path), so caller paths are workspace-RELATIVE: expand them AGAINST
  # the root (`Path.expand/2`). A relative path resolves under the root; an absolute
  # path is normalised (the base is ignored) and must already be within the root.
  # Either way `..`-escapes are normalised away before the prefix check, so a
  # lexical `<root>/../x` that escapes the root is rejected.
  defp confine_path(ctx, path) do
    case Map.get(ctx, :session_path) do
      root when is_binary(root) and root != "" ->
        root_expanded = Path.expand(root)
        expanded = Path.expand(path, root_expanded)
        canonical_root = DocMount.canonical_root(root_expanded)
        canonical_expanded = canonical_path_for_compare(expanded)

        if canonical_expanded == canonical_root or
             String.starts_with?(canonical_expanded, canonical_root <> "/") do
          {:ok, expanded}
        else
          {:error, {:outside_workspace, canonical_root}}
        end

      _ ->
        {:ok, path}
    end
  end

  # The workspace root for the doc VFS open-set (`Ecrits.Fuse.OpenDocs` /
  # `DocMount` key). `ctx.session_path` is the agent's workspace root.
  defp vfs_root(ctx) do
    case Map.get(ctx, :session_path) do
      root when is_binary(root) and root != "" -> {:ok, DocMount.canonical_root(root)}
      _ -> {:error, {:invalid_params, "no workspace root in this context"}}
    end
  end

  defp resolve_vfs_document_path(ctx, path) when is_binary(path) do
    path = String.trim(path)

    result =
      path
      |> vfs_document_path_candidates(ctx)
      |> Enum.reduce_while(nil, fn candidate, first_error ->
        case resolve_vfs_document_candidate(ctx, candidate) do
          {:ok, abs} -> {:halt, {:ok, abs}}
          {:error, reason} -> {:cont, first_error || {:error, reason}}
        end
      end)

    case result do
      {:ok, abs} ->
        {:ok, abs}

      {:error, reason} ->
        {:error, reason}

      nil when path in ["active", "current"] ->
        {:error,
         {:invalid_params,
          "no document is bound to this conversation yet — retry doc.open_doc in a " <>
            "moment (the binding syncs with the open editor tab), or pass the " <>
            "document's workspace-relative path explicitly"}}

      nil ->
        {:error, {:invalid_params, "path is required"}}
    end
  end

  # "current"/"active" are KEYWORDS, never filenames: resolving them as
  # literal paths produced "unsupported document type: " when no document was
  # bound (2026-07-19 live, a revived session before its binding synced) —
  # an error with no path forward. Keywords resolve only through the bound
  # document, and their absence gets an actionable message.
  defp vfs_document_path_candidates(path, ctx) when path in ["active", "current"] do
    active_document_path_candidates(ctx, path)
  end

  defp vfs_document_path_candidates(path, ctx) do
    ([path] ++ active_document_path_candidates(ctx, path))
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
  end

  defp active_document_path_candidates(ctx, path) do
    active = Map.get(ctx, :document_path)
    normalized = String.trim_leading(path, "./")

    cond do
      not is_binary(active) or active == "" ->
        []

      path in ["active", "current"] ->
        [active]

      active == path or active == normalized ->
        [active]

      Path.basename(active) == normalized ->
        [active]

      String.ends_with?(active, "/" <> normalized) ->
        [active]

      true ->
        []
    end
  end

  defp resolve_vfs_document_candidate(ctx, candidate) do
    with {:ok, abs} <- confine_path(ctx, candidate),
         :ok <- ensure_projectable(abs) do
      {:ok, abs}
    end
  end

  defp vfs_mount_source_name(root, abs) do
    root = DocMount.canonical_root(root)
    rel = vfs_relative_path(root, abs)
    name = flat_vfs_source_name(rel)

    case Ecrits.Fuse.OpenDocs.source_path(root, name) do
      {:ok, existing} ->
        if canonical_file_path(existing) == canonical_file_path(abs) do
          name
        else
          disambiguated_vfs_source_name(name, rel)
        end

      :error ->
        name
    end
  end

  defp vfs_relative_path(root, abs) do
    Path.relative_to(canonical_file_path(abs), DocMount.canonical_root(root))
  end

  defp flat_vfs_source_name(rel) do
    if Path.dirname(rel) == "." do
      rel
    else
      rel
      |> String.replace("%", "%25")
      |> String.replace("/", "%2F")
    end
  end

  defp disambiguated_vfs_source_name(name, rel) do
    ext = Path.extname(name)
    stem = String.replace_suffix(name, ext, "")
    hash = :crypto.hash(:sha256, rel) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    stem <> "--" <> hash <> ext
  end

  defp canonical_path_for_compare(path) when is_binary(path) do
    canonical_file_path(path)
  end

  defp canonical_file_path(path) when is_binary(path) do
    path = Path.expand(path)
    Path.join(DocMount.canonical_root(Path.dirname(path)), Path.basename(path))
  end

  defp ensure_projectable(abs) do
    cond do
      not Ecrits.Doc.Projection.supported?(abs) ->
        {:error, {:invalid_params, "unsupported document type: #{Path.extname(abs)}"}}

      not File.regular?(abs) ->
        {:error, {:invalid_params, "no such file: #{abs}"}}

      true ->
        :ok
    end
  end

  defp doc_mount_status_json(status) do
    %{
      "backend" => status.backend |> to_string(),
      "enabled" => status.enabled?,
      "reason" => status.reason && to_string(status.reason),
      "message" => status.message,
      "settings_url" => status.settings_url
    }
  end

  defp sync_vfs_write_policy(ctx, root) do
    case Map.fetch(ctx, :read_only) do
      {:ok, read_only?} when is_boolean(read_only?) ->
        Ecrits.Fuse.OpenDocs.set_writable(root, not read_only?)

      _ ->
        :ok
    end
  end

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

  defp normalize_kind(nil, path), do: kind_from_path(path) || :hwp
  defp normalize_kind("", path), do: kind_from_path(path) || :hwp
  defp normalize_kind(kind, _path), do: normalize_kind(kind)

  defp normalize_kind("hwpx"), do: :hwpx
  defp normalize_kind("hwp"), do: :hwp
  defp normalize_kind("docx"), do: :docx
  defp normalize_kind("pptx"), do: :pptx
  defp normalize_kind("xlsx"), do: :xlsx
  defp normalize_kind(:hwpx), do: :hwpx
  defp normalize_kind(:docx), do: :docx
  defp normalize_kind(:pptx), do: :pptx
  defp normalize_kind(:xlsx), do: :xlsx
  defp normalize_kind(_other), do: :hwp

  defp kind_from_path(path) when is_binary(path) do
    case path |> Path.extname() |> String.downcase() do
      ".hwp" -> :hwp
      ".hwpx" -> :hwpx
      ".docx" -> :docx
      ".pptx" -> :pptx
      ".xlsx" -> :xlsx
      _ -> nil
    end
  end

  defp kind_from_path(_path), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
