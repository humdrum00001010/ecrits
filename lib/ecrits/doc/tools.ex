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
  | `doc.inspect`    | read  | `Editor.inspect_element/2` (services/interfaces/props/children) |
  | `doc.read`       | read  | `Editor.read/2` (**≤30 paragraphs/call** + cursor) |
  | `doc.find`       | read  | `Editor.find/3` |
  | `doc.get`        | read  | `Editor.get/3` |
  | `doc.set`        | write | `Editor.set/4` (base_revision) |
  | `doc.edit`       | write | `Editor.apply/3` (base_revision) |
  | `doc.apply_style`| write | `Editor.apply_style/3` |
  | `doc.save`       | write | `Editor.save/2` |

  `doc.read` is **incremental**: a single call returns at most 30 paragraphs (a
  hard cap, design §4.4) plus a `next_at` cursor, so the agent pages through a
  document and never pulls the whole thing.

  The deep Office tools (`office.inspect`/`office.call`/`office.dispatch`,
  design §4.4 "Office 전용 심화") are intentionally **not** part of this HWP
  surface; the LibreOffice backend is a separate effort. The reflective
  `doc.inspect` here is the engine-agnostic equivalent for the HWP backend.

  Tools run against a context map `%{pool: pool}` (defaults to the named
  `Ecrits.Doc.Pool`). Results are JSON-shaped maps so the layer is testable
  server-side without a browser or an MCP transport. Errors that the agent is
  expected to act on (conflict, capability gaps) are returned as structured
  maps mirroring the design's example payloads.
  """

  alias Ecrits.Doc.Editor
  alias Ecrits.Doc.Pool

  @namespace "doc"

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
          "kind" => %{"type" => "string", "enum" => ["hwp", "hwpx"]}
        },
        "required" => ["path"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "create",
      "description" =>
        "Create a NEW empty document (blank template) whose save target is `path` " <>
          "(the file need not exist yet). Returns {document, kind}. Author content " <>
          "with doc.edit (insert_text/insert_paragraph/split/insert_table_*/…) and " <>
          "persist with doc.save.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "minLength" => 1},
          "kind" => %{"type" => "string", "enum" => ["hwp", "hwpx"]}
        },
        "required" => ["path"]
      }
    },
    %{
      "namespace" => @namespace,
      "name" => "read",
      "description" =>
        "Read a paragraph chunk from a document. INCREMENTAL: a single call returns " <>
          "AT MOST #{@read_cap} paragraphs (a hard cap) and never the whole document. " <>
          "Start at paragraph index `at` (default 0); `size` is the requested paragraph " <>
          "count, clamped to #{@read_cap}. The result includes `next_at` (the cursor for " <>
          "the next page, or null at end) and `total` — page through long docs with it.",
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
      "description" => "Literal search -> [{ref, text}].",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "pattern" => %{"type" => "string", "minLength" => 1},
          "case_sensitive" => %{"type" => "boolean", "default" => false}
        },
        "required" => ["document", "pattern"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "inspect",
      "description" =>
        "Reflective discovery for an element (ref, nil = document): its type, the NATIVE " <>
          "property names get/set understand (e.g. Bold/Italic/Width), conceptual " <>
          "interfaces, and child refs. Use this to discover property names instead of " <>
          "guessing them (design §4.1).",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"}
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "get",
      "description" => "Read native properties of an element (ref). props? selects names.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "props" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["document", "ref"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "set",
      "description" =>
        "Universal property edit. Routes to native setters. Honours base_revision.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "props" => %{"type" => "object"},
          "base_revision" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["document", "ref", "props"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "edit",
      "description" =>
        "Apply ONE structural edit, discriminated by op.op. Honours base_revision.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
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
                "• delete_range {op, ref, count?}\n" <>
                "• insert_paragraph {op, ref} • delete_paragraph {op, ref} • split {op, ref} • merge {op, ref}\n" <>
                "• insert_table {op, ref, rows, cols}: create a NEW rows×cols table at `ref`. Returns native {paraIdx, controlIdx} — " <>
                "use it to fill cells: insert_text with a ref carrying {section, paragraph: paraIdx, control: controlIdx, cell: <0-based cell index, row-major>, cell_para: 0, offset: 0}.\n" <>
                "• insert_table_row / delete_table_row / insert_table_column / delete_table_column / merge_cells / split_cell {op, ref}: modify an EXISTING table.\n" <>
                "• delete_node {op, ref} • insert_picture {op, ref, bins}",
            "properties" => %{
              "op" => %{
                "type" => "string",
                "enum" =>
                  ~w(insert_text delete_range replace_text insert_paragraph delete_paragraph split merge insert_table insert_table_row delete_table_row insert_table_column delete_table_column merge_cells split_cell delete_node insert_picture)
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
              "text" => %{"type" => "string", "description" => "insert_text: text to insert."},
              "at" => %{"type" => "integer", "description" => "char offset within the target paragraph."},
              "count" => %{"type" => "integer", "description" => "delete_range: number of chars to delete."}
            },
            "required" => ["op"]
          },
          "base_revision" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["document", "op"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "apply_style",
      "description" => "Apply a named style to an element (ref).",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "style" => %{"type" => ["string", "object"]}
        },
        "required" => ["document", "ref", "style"]
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

  `ctx` is `%{pool: pool}` (defaults to the named `Ecrits.Doc.Pool`).
  """
  @spec call(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx \\ %{}, tool_name, args)

  def call(ctx, "doc.context", _args) do
    {:ok, context_json(pool(ctx))}
  end

  def call(ctx, "doc.list", _args) do
    {:ok, %{"documents" => Enum.map(Pool.list(pool(ctx)), &entry_json/1)}}
  end

  def call(ctx, "doc.open", args) do
    with {:ok, path} <- require_string(args, "path") do
      kind = args |> get(["kind"]) |> normalize_kind()
      open_opts = args |> get(["open_opts"]) |> List.wrap()

      case Pool.open(pool(ctx), path, kind: kind, open_opts: open_opts) do
        {:ok, doc_id} ->
          {:ok, %{"document" => doc_id, "kind" => Atom.to_string(kind)}}

        {:error, reason} ->
          {:error, error_json(reason)}
      end
    end
  end

  def call(ctx, "doc.create", args) do
    with {:ok, path} <- require_string(args, "path") do
      kind = args |> get(["kind"]) |> normalize_kind()

      case Pool.create(pool(ctx), path, kind: kind) do
        {:ok, doc_id} ->
          _ = Pool.set_active(pool(ctx), doc_id)
          {:ok, %{"document" => doc_id, "kind" => Atom.to_string(kind)}}

        {:error, reason} ->
          {:error, error_json(reason)}
      end
    end
  end

  def call(ctx, "doc.inspect", args) do
    with_editor(ctx, args, fn editor ->
      ref = get(args, ["ref"])
      wrap(Editor.inspect_element(editor, ref), &inspect_json/1)
    end)
  end

  def call(ctx, "doc.read", args) do
    route_doc(ctx, args,
      browser: fn lv -> browser_call(lv, args, :read, %{opts: take_opts(args, ["at", "size", "ref"])}) end,
      server: fn editor ->
        opts = take_opts(args, ["at", "size", "ref"])
        wrap(Editor.read(editor, opts), &Map.merge(%{}, stringify(&1)))
      end
    )
  end

  def call(ctx, "doc.find", args) do
    with {:ok, pattern} <- require_string(args, "pattern") do
      route_doc(ctx, args,
        browser: fn lv ->
          browser_call(lv, args, :find, %{
            pattern: pattern,
            case_sensitive: get(args, ["case_sensitive"]) || false
          })
        end,
        server: fn editor ->
          opts = take_opts(args, ["case_sensitive"])

          case Editor.find(editor, pattern, opts) do
            {:ok, matches} ->
              {:ok, %{"pattern" => pattern, "matches" => Enum.map(matches, &stringify/1)}}

            {:error, reason} ->
              {:error, error_json(reason)}
          end
        end
      )
    end
  end

  def call(ctx, "doc.get", args) do
    with {:ok, ref} <- require_string(args, "ref") do
      with_editor(ctx, args, fn editor ->
        props = get(args, ["props"])
        wrap(Editor.get(editor, ref, props), &stringify/1)
      end)
    end
  end

  def call(ctx, "doc.set", args) do
    with {:ok, ref} <- require_string(args, "ref"),
         {:ok, props} <- require_map(args, "props") do
      with_editor(ctx, args, fn editor ->
        base_rev = get(args, ["base_revision"])
        write_result(Editor.set(editor, ref, props, base_rev))
      end)
    end
  end

  def call(ctx, "doc.edit", args) do
    with {:ok, op} <- require_map(args, "op") do
      base_rev = get(args, ["base_revision"])

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

  def call(ctx, "doc.apply_style", args) do
    with {:ok, ref} <- require_string(args, "ref"),
         {:ok, style} <- require_present(args, "style") do
      with_editor(ctx, args, fn editor ->
        write_result(Editor.apply_style(editor, ref, style))
      end)
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

  # doc.save for an open (browser) doc: round-trip the viewer for its current
  # edited bytes, then write them to `path`.
  defp save_browser(lv, args, path) do
    case browser_call(lv, args, :save, %{}) do
      {:ok, %{} = res} ->
        b64 = res["bytes_base64"] || res[:bytes_base64]

        with true <- is_binary(b64) or {:error, {:save_failed, "viewer returned no bytes"}},
             {:ok, bytes} <- Base.decode64(b64),
             :ok <- File.write(path, bytes) do
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
      :ok -> {:ok, %{"ok" => true, "path" => path}}
      {:ok, %{} = saved} -> {:ok, Map.merge(%{"ok" => true, "path" => path}, stringify(saved))}
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  defp save_format(:hwpx), do: :hwpx
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

  defp inspect_json(node) when is_map(node), do: stringify(node)

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
  defp context_json(pool) do
    docs = Pool.list(pool)
    active_id = Pool.active(pool)
    active = active_id && Enum.find(docs, &(&1.id == active_id))

    %{
      "active_document" => active && active.id,
      "cursor" => nil,
      "selection" => nil,
      "cursor_reporting" => "todo:browser_wiring",
      "documents" => Enum.map(docs, &entry_json/1)
    }
  end

  defp error_json({:not_supported, reason}),
    do: %{"not_supported" => true, "reason" => to_string(reason)}

  defp error_json({:stale_revision, details}),
    do: %{"error" => "stale_revision", "details" => stringify_kw(details)}

  defp error_json(:not_found), do: %{"error" => "not_found"}

  defp error_json({:unsupported_kind, kind}),
    do: %{"error" => "unsupported_kind", "kind" => to_string(kind)}

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

  defp require_map(args, key) do
    case get(args, [key]) do
      %{} = value -> {:ok, value}
      _ -> {:error, {:invalid_params, "#{key} (object) is required"}}
    end
  end

  defp require_present(args, key) do
    case get(args, [key]) do
      nil -> {:error, {:invalid_params, "#{key} is required"}}
      value -> {:ok, value}
    end
  end

  defp normalize_kind("hwpx"), do: :hwpx
  defp normalize_kind("hwp"), do: :hwp
  defp normalize_kind(:hwpx), do: :hwpx
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
