defmodule EcritsWeb.DocBrowserOpMatrixTest do
  @moduledoc """
  Per-verb matrix for the BROWSER arms (#31): real Chromium (Wallaby) loads the
  workspace, opens a fixture in the real wasm editor, and drives every doc.edit
  verb through the SAME bridge code the agent path uses:

    * HWP: `WasmHwpEditor.applyOneOp` bound to the live `window.__rhwpDoc`
      (the exact glue `document.engine.operation.command` invokes) — sync rhwp wasm calls.
    * Office: `window.__officeWasmEditor.officeApplyOneOp` — async embind calls
      into the relinked soffice.wasm (full uno_apply op set). Needs the page to
      be crossOriginIsolated, which real top-level Chrome gives us (the Tidewave
      iframe channel cannot run this — that's why this lives in Wallaby).

  Run with: mix test --include browser test/ecrits_web/features/doc_browser_op_matrix_test.exs
  The office leg loads a ~145MB wasm — generous timeouts are intentional.
  """

  use EcritsWeb.FeatureCase, async: false

  @moduletag :browser
  @moduletag timeout: 420_000

  @hwpx_fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)
  @docx_fixture Path.expand("../../fixtures/office/table.docx", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "doc_matrix_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp!(@hwpx_fixture, Path.join(dir, "matrix.hwpx"))
    File.cp!(@docx_fixture, Path.join(dir, "matrix.docx"))
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, ws: dir}
  end

  feature "HWPX browser arm: all 22 HWP verbs apply via applyOneOp", %{session: session, ws: ws} do
    session = Wallaby.Browser.visit(session, "/workspace?path=#{URI.encode(ws)}")
    open_document(session, "matrix.hwpx")

    # Re-click while waiting: a click that landed on the dead (pre-connect)
    # render is swallowed, so retry until the wasm doc exists.
    assert poll(
             session,
             "if (window.__rhwpDoc) return true;" <>
               "var el = document.querySelector('[phx-click=\"workspace.document.open\"][phx-value-path=\"matrix.hwpx\"]');" <>
               "if (el) el.click(); return false;",
             90_000
           ),
           "rhwp wasm doc never loaded"

    raw =
      js(session, """
      const proto = Object.entries(window.liveSocket.hooks)
        .find(([name]) => name.endsWith(".WasmHwpEditor"))?.[1];
      if (!proto) return JSON.stringify([["hook", {error: "WasmHwpEditor hook missing"}]]);
      const ctx = Object.create(proto); ctx.doc = window.__rhwpDoc; ctx.recordOp = () => {};
      const out = [];
      const run = (label, op) => { try { out.push([label, ctx.applyOneOp(op)]); } catch (e) { out.push([label, { error: String(e) }]); } };

      // discover a table cell + a body paragraph in the live model
      let cellRef = null, tableHome = null;
      outer: for (let p = 0; p < 200; p++) {
        for (let c = 0; c < 4; c++) {
          try { JSON.parse(ctx.doc.getTableDimensions(0, p, c)); tableHome = { p, c }; break outer; } catch (_) {}
        }
      }
      if (!tableHome) { out.push(["discover", { error: "no table in fixture" }]); return JSON.stringify(out); }
      cellRef = { section: 0, paragraph: tableHome.p, offset: 0,
                  cell: { parentParaIndex: tableHome.p, controlIndex: tableHome.c, cellIndex: 0, cellParaIndex: 0 } };
      const body = { section: 0, paragraph: 1, offset: 0 };

      run("insert_text", { op: "insert_text", ref: body, text: "BRMX_TOKEN" });
      run("replace_text", { op: "replace_text", ref: body, query: "BRMX_TOKEN", replacement: "BRMX_TOKEN2" });
      run("delete_range", { op: "delete_range", ref: body, count: 1 });
      run("insert_paragraph", { op: "insert_paragraph", ref: body });
      run("split", { op: "split", ref: body });
      run("merge", { op: "merge", ref: { section: 0, paragraph: 2 } });
      run("delete_paragraph", { op: "delete_paragraph", ref: { section: 0, paragraph: 2 } });
      run("insert_table", { op: "insert_table", ref: body, rows: 2, cols: 2 });
      run("insert_table_row", { op: "insert_table_row", ref: cellRef, below: true });
      run("delete_table_row", { op: "delete_table_row", ref: cellRef, row: 1 });
      run("insert_table_column", { op: "insert_table_column", ref: cellRef, right: true });
      run("delete_table_column", { op: "delete_table_column", ref: cellRef, col: 1 });
      run("set_cell", { op: "set_cell", ref: cellRef, text: "BRMX_CELL" });
      run("insert_equation", { op: "insert_equation", ref: body, script: "x^2" });
      run("insert_footnote", { op: "insert_footnote", ref: body });
      run("insert_endnote", { op: "insert_endnote", ref: body });
      run("insert_shape", { op: "insert_shape", ref: body, width: 8504, height: 4252 });
      run("set_columns", { op: "set_columns", ref: body, count: 2 });
      // structure ops that need a fresh known table: build 2x2 then merge/split/delete
      run("insert_table#2", { op: "insert_table", ref: { section: 0, paragraph: 3, offset: 0 }, rows: 2, cols: 2 });
      // find the new table's control on p3
      let c2 = null;
      for (let c = 0; c < 6; c++) { try { JSON.parse(ctx.doc.getTableDimensions(0, 3, c)); c2 = c; break; } catch (_) {} }
      const cell2 = { section: 0, paragraph: 3, offset: 0,
                      cell: { parentParaIndex: 3, controlIndex: c2 ?? 0, cellIndex: 0, cellParaIndex: 0 } };
      run("merge_cells", { op: "merge_cells", ref: cell2, start_row: 0, start_col: 0, end_row: 0, end_col: 1 });
      run("split_cell", { op: "split_cell", ref: cell2, row: 1, col: 0, rows: 1, cols: 2 });
      run("delete_node", { op: "delete_node", ref: cell2 });
      // picture: inline base64 1x1 png
      run("insert_picture", { op: "insert_picture", ref: body, width: 4252, height: 4252,
        image_base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
        extension: "png", natural_width_px: 1, natural_height_px: 1 });
      return JSON.stringify(out);
      """)

    results = Jason.decode!(raw)
    failures = Enum.filter(results, fn [_label, r] -> r["error"] end)
    assert failures == [], "hwp browser verbs failed: #{inspect(failures)}"
  end

  feature "office browser arm: relinked soffice.wasm accepts the full op set",
          %{session: session, ws: ws} do
    session = Wallaby.Browser.visit(session, "/workspace?path=#{URI.encode(ws)}")
    open_document(session, "matrix.docx")

    coi = js(session, "return window.crossOriginIsolated === true;")
    assert coi, "workspace page is not crossOriginIsolated — office wasm cannot boot"

    loaded =
      poll(
        session,
        "var ed = window.__officeWasmEditor;" <>
          "if (ed && ed.api && typeof ed.api.loadStatus === 'function' && ed.api.loadStatus() === 2) return true;" <>
          "if (!ed) { var el = document.querySelector('[phx-click=\"workspace.document.open\"][phx-value-path=\"matrix.docx\"]');" <>
          "if (el) el.click(); } return false;",
        300_000
      )

    assert loaded, "office wasm never finished loading the docx"

    js(session, """
    const ed = window.__officeWasmEditor;
    window.__matrixResults = null;
    (async () => {
      const out = [];
      const run = async (label, op) => {
        try { out.push([label, await ed.officeApplyOneOp(op)]); }
        catch (e) { out.push([label, { error: String(e) }]); }
      };
      await run("insert_paragraph", { op: "insert_paragraph", ref: "end", text: "BROFFICE_A" });
      await run("insert_text", { op: "insert_text", ref: "p0", text: "_T" });
      await run("replace_text", { op: "replace_text", ref: "p0", query: "_T", replacement: "_U" });
      await run("split", { op: "split", ref: "p0", at: 1 });
      await run("merge", { op: "merge", ref: "p1" });
      await run("delete_range", { op: "delete_range", ref: "p1" });
      await run("insert_table", { op: "insert_table", ref: "end", rows: 2, cols: 2, name: "WX" });
      await run("set_cell", { op: "set_cell", ref: "tbl[WX]/cell[A1]", text: "WX_A1" });
      await run("insert_table_row", { op: "insert_table_row", ref: "tbl[WX]/cell[B2]", below: true });
      await run("insert_table_column", { op: "insert_table_column", ref: "tbl[WX]", col: 1, right: true });
      await run("delete_table_row", { op: "delete_table_row", ref: "tbl[WX]", row: 2 });
      await run("delete_table_column", { op: "delete_table_column", ref: "tbl[WX]", col: 2 });
      await run("merge_cells", { op: "merge_cells", ref: "tbl[WX]", start_row: 0, start_col: 0, end_row: 0, end_col: 1 });
      await run("split_cell", { op: "split_cell", ref: "tbl[WX]/cell[A2]", cols: 2 });
      await run("insert_footnote", { op: "insert_footnote", ref: "end", text: "BR_FOOT" });
      await run("insert_endnote", { op: "insert_endnote", ref: "end", text: "BR_END" });
      await run("insert_equation", { op: "insert_equation", ref: "end", script: "x^2 + y^2" });
      await run("delete_paragraph", { op: "delete_paragraph", ref: "p0" });
      window.__matrixResults = JSON.stringify(out);
    })();
    return true;
    """)

    assert poll(session, "return window.__matrixResults != null;", 120_000),
           "office op sequence never completed"

    results = Jason.decode!(js(session, "return window.__matrixResults;"))
    failures = Enum.filter(results, fn [_label, r] -> r["error"] end)
    assert failures == [], "office browser verbs failed: #{inspect(failures)}"
  end

  # ── plumbing ────────────────────────────────────────────────────────────

  defp open_document(session, name) do
    # Wait for the LiveView to CONNECT first (a click on the dead render is
    # swallowed), then click the tree entry [phx-click=workspace.document.open][phx-value-path].
    assert poll(
             session,
             "if (!document.querySelector('.phx-connected')) return false;" <>
               "var el = document.querySelector('[phx-click=\"workspace.document.open\"][phx-value-path=\"#{name}\"]');" <>
               "if (el) { el.click(); return true; } return false;",
             30_000
           ),
           "file tree entry #{name} never appeared on the connected LiveView"
  end

  defp js(session, script) do
    parent = self()
    ref = make_ref()

    Wallaby.Browser.execute_script(session, script, [], fn value ->
      send(parent, {ref, value})
    end)

    receive do
      {^ref, value} -> value
    after
      30_000 -> nil
    end
  end

  defp poll(session, script, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll(session, script, deadline)
  end

  defp do_poll(session, script, deadline) do
    case js(session, script) do
      true ->
        true

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          false
        else
          Process.sleep(1_000)
          do_poll(session, script, deadline)
        end
    end
  end
end
