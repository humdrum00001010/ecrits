defmodule Ecrits.Doc.OpMatrixAuditTest do
  @moduledoc """
  The parity-directive audit (#27/#31, docs/plans/2026-06-12-ir-op-parity-matrix.md).

  Three invariants this suite pins:

  1. **One vocabulary.** `Op.verbs()` and the `doc.edit` JSON-schema `op` enum are
     byte-identical — the agent is never offered a verb the gate rejects, and the
     gate never accepts a verb the agent can't discover.

  2. **The tool list never changes.** The whole op surface expands INSIDE
     `doc.edit`'s `op` discriminator (user-confirmed hard constraint: codex defers
     MCP tools behind discovery when servers expose many, so the small fixed tool
     list is what keeps the doc server reliably surfaced). Adding a tool fails
     this test on purpose — change it only with that tradeoff in mind.

  3. **Every verb is consciously dispositioned per arm.** The per-arm coverage
     maps below say, for each verb, whether the arm SUPPORTS it (a matrix test
     must drive it) or precisely REJECTS it. A new verb fails this audit until
     someone classifies it on all four arms — that's the point.
  """
  use ExUnit.Case, async: true

  alias Ecrits.Doc.Op

  # ── the four per-arm dispositions ──────────────────────────────────────
  # :supported — the arm applies the op (positive matrix test required)
  # :rejected  — the arm returns a PRECISE capability error (negative test)
  # :na        — verb is meaningless for the format and errors in the engine

  @hwp_server %{
    "insert_text" => :supported,
    "delete_range" => :supported,
    "replace_text" => :supported,
    "insert_paragraph" => :supported,
    "delete_paragraph" => :supported,
    "split" => :supported,
    "merge" => :supported,
    "insert_table" => :supported,
    "insert_table_row" => :supported,
    "delete_table_row" => :supported,
    "insert_table_column" => :supported,
    "delete_table_column" => :supported,
    "merge_cells" => :supported,
    "split_cell" => :supported,
    "delete_node" => :supported,
    "insert_picture" => :supported,
    "set_cell" => :supported,
    "insert_equation" => :supported,
    "insert_footnote" => :supported,
    "insert_endnote" => :supported,
    "insert_shape" => :supported,
    "set_columns" => :supported,
    "insert_slide" => :na,
    "set_geometry" => :na
  }

  # Browser HWP bridge (wasm_hwp_editor.js applyOneOp) — full parity since #29.
  @hwp_browser @hwp_server

  # Office server (libreofficex uno_bridge lokx_uno_apply) — full surface since
  # #30: table structure via XTextTable rows/cols + XTextTableCursor, paragraph
  # structure via the body-enumeration walk, endnote/equation services.
  # insert_shape's HWP form (no `page`) gets a guidance error; the slide form is
  # the supported one — still :supported here (the verb works).
  @office_server Map.merge(@hwp_server, %{
                   "insert_slide" => :supported,
                   "set_geometry" => :supported,
                   # merge_cells/split_cell are Writer-table only; Impress table
                   # shapes get a precise refusal (engine-level, by design).
                   "insert_equation" => :supported
                 })

  # Browser office bridge: same binary op set as the server cpp since the #30
  # relink; replace_text/set_cell/delete_range stay JS-composed (IR-faithful).
  @office_browser @office_server

  test "doc.edit schema op enum is byte-identical to Op.verbs()" do
    edit_tool =
      Enum.find(Ecrits.Doc.Tools.tools(), fn t ->
        t["name"] == "edit" or t["name"] == "doc.edit" or
          (t["namespace"] || "") <> "." <> t["name"] == "doc.edit"
      end)

    assert edit_tool, "doc.edit tool not found in Tools.tools()"

    enum = get_in(edit_tool, ["inputSchema", "properties", "op", "properties", "op", "enum"])
    assert enum == Op.verbs()
  end

  test "the MCP tool list is FIXED (op growth happens inside doc.edit, never as new tools)" do
    # The exact tool set the doc MCP server advertises. If you are editing this
    # list, you are changing the agent-facing tool surface — re-read the module
    # doc first (codex tool-discovery deferral is the constraint).
    assert Enum.sort(Ecrits.Doc.Tools.tool_names()) == [
             "doc.close_doc",
             "doc.context",
             "doc.create",
             "doc.edit",
             "doc.find",
             "doc.get",
             "doc.list",
             "doc.open",
             "doc.open_doc",
             "doc.read",
             "doc.render",
             "doc.save",
             "doc.set"
           ]
  end

  test "every verb has a disposition on every arm (new verbs must be classified)" do
    for {arm, map} <- [
          hwp_server: @hwp_server,
          hwp_browser: @hwp_browser,
          office_server: @office_server,
          office_browser: @office_browser
        ] do
      missing = Op.verbs() -- Map.keys(map)
      assert missing == [], "arm #{arm} has unclassified verbs: #{inspect(missing)}"

      stale = Map.keys(map) -- Op.verbs()
      assert stale == [], "arm #{arm} classifies verbs that no longer exist: #{inspect(stale)}"
    end
  end

  test "no arm silently drops a verb (everything is :supported, :rejected or :na)" do
    for {arm, map} <- [
          hwp_server: @hwp_server,
          hwp_browser: @hwp_browser,
          office_server: @office_server,
          office_browser: @office_browser
        ],
        {verb, disposition} <- map do
      assert disposition in [:supported, :rejected, :na],
             "arm #{arm} verb #{verb} has invalid disposition #{inspect(disposition)}"
    end
  end
end
