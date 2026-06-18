defmodule EcritsWeb.OfficePickerProbeTest do
  @moduledoc """
  resolveRef probe (#38): the office wasm's element-picker hover/pick bridge,
  in real COI Chrome on the relinked soffice.wasm (the Tidewave iframe channel
  is not crossOriginIsolated, so this lives in Wallaby like the op matrix).

  Verifies the two contracts the hover preview rests on:

    * a probe inside the docx table resolves to a cell/paragraph ref with
      ACCURATE per-line `rects` — not the legacy caret-box fallback that drew
      a made-up 90px rectangle at the caret;
    * a commit=false probe RESTORES the prior caret (the hover contract —
      sweeping the pointer must never steal the editing state).
  """

  use EcritsWeb.FeatureCase, async: false

  @moduletag :browser
  @moduletag timeout: 420_000

  @docx_fixture Path.expand("../../fixtures/office/table.docx", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "picker_probe_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp!(@docx_fixture, Path.join(dir, "probe.docx"))
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, ws: dir}
  end

  feature "resolveRef returns per-line rects and restores the caret on hover probes",
          %{session: session, ws: ws} do
    session = Wallaby.Browser.visit(session, "/workspace?path=#{URI.encode(ws)}")
    open_file(session, "probe.docx")

    assert js(session, "return window.crossOriginIsolated === true;"),
           "workspace page is not crossOriginIsolated — office wasm cannot boot"

    loaded =
      poll(
        session,
        "var ed = window.__officeWasmEditor;" <>
          "if (ed && ed.api && typeof ed.api.loadStatus === 'function' && ed.api.loadStatus() === 2) return true;" <>
          "if (!ed) { var el = document.querySelector('[phx-click=\"open_file\"][phx-value-path=\"probe.docx\"]');" <>
          "if (el) el.click(); } return false;",
        300_000
      )

    assert loaded, "office wasm never finished loading the docx"

    js(session, """
    const ed = window.__officeWasmEditor;
    window.__probeResult = null;
    (async () => {
      const out = {};
      try {
        out.hasResolve = typeof ed.api.resolveRef === "function";
        if (!out.hasResolve) { window.__probeResult = JSON.stringify(out); return; }

        // Anchor a known caret first: a commit=true pick near the doc start.
        const anchor = ed.api.resolveRef(1, 200, 80, true);
        out.anchor = { ok: !!(anchor && anchor.ok), ref: anchor && anchor.ref };

        // The cursor callback flushes on the LO loop's idle — wait for a VALID
        // caret snapshot before probing, or the restore comparison reads an
        // unflushed {ok:false} baseline.
        let caretBefore = null;
        for (let i = 0; i < 40; i++) {
          const c = ed.api.getCursor();
          if (c && c.ok) { caretBefore = c; break; }
          await new Promise(r => setTimeout(r, 50));
        }

        // Sweep down the page with HOVER probes (commit=false); keep the richest
        // hit (cell-with-rects > any-with-rects > first ok) and a per-attempt
        // trace so a failure says exactly where the harvest broke.
        let probe = null;
        let fallbackOk = null;
        out.attempts = [];
        for (let y = 80; y <= 900; y += 40) {
          const p = ed.api.resolveRef(1, 320, y, false);
          out.attempts.push({
            y,
            ok: !!(p && p.ok),
            type: p && p.type,
            ref: p && p.ref,
            rects: (p && p.rects && p.rects.length) || 0,
            // hitTest's own caret echo: tracks the click when the mouse events
            // actually land — separates "click not applied" from "stale
            // resolution".
            caretOk: !!(p && p.caret && p.caret.ok),
            caretY: p && p.caret && Math.round(p.caret.y),
            dbg: p && p.dbg
          });
          if (!p || !p.ok) continue;
          if (!fallbackOk) fallbackOk = p;
          if ((p.rects || []).length) {
            if (p.type === "cell") { probe = p; break; }
            if (!probe) probe = p;
          }
        }
        if (!probe) probe = fallbackOk;

        out.probe = probe && {
          ok: probe.ok,
          type: probe.type,
          ref: probe.ref,
          rectCount: (probe.rects || []).length,
          rect0: probe.rects && probe.rects[0]
        };

        // Snapshot the restore only after the cursor SETTLES: getCursor reads
        // the latest FLUSHED callback, and right after the probes that is the
        // last harvest-selection position — the restore's own cursor event is
        // still in the queue. Wait until the value stops changing (~200ms).
        let caretAfter = null;
        let lastKey = null;
        let stable = 0;
        for (let i = 0; i < 60; i++) {
          const c = ed.api.getCursor();
          if (c && c.ok) {
            const key = Math.round(c.x) + ":" + Math.round(c.y) + ":" + c.page;
            if (key === lastKey) {
              if (++stable >= 4) { caretAfter = c; break; }
            } else {
              lastKey = key;
              stable = 0;
            }
          }
          await new Promise(r => setTimeout(r, 50));
        }
        out.caretBefore = caretBefore;
        out.caretAfter = caretAfter;
        out.caretRestored =
          !!caretBefore && !!caretAfter &&
          Math.round(caretBefore.x) === Math.round(caretAfter.x) &&
          Math.round(caretBefore.y) === Math.round(caretAfter.y) &&
          caretBefore.page === caretAfter.page;

        // Footnotes live in their own XText at the page bottom — plant one via
        // the op surface, then hover-sweep the footer area: it must resolve as
        // type "footnote" with an fn[<n>] ref (the body comparator alone makes
        // the footnote area unpickable).
        try {
          await ed.officeApplyOneOp({ op: "insert_footnote", ref: "p0", text: "PROBE_FOOTNOTE" });
          out.footnoteInserted = true;
          let fn = null;
          for (let y = 1100; y >= 700 && !fn; y -= 25) {
            const p = ed.api.resolveRef(1, 200, y, false);
            if (p && p.ok && p.type === "footnote") fn = p;
          }
          out.footnote = fn && {
            ref: fn.ref,
            type: fn.type,
            text: (fn.text || "").slice(0, 30),
            rects: (fn.rects || []).length
          };

          // Endnote: geometry is page-layout-fragile (Writer collects endnotes
          // on a separate final page), so assert the ADDRESSING instead — the
          // walker must list the planted endnote as en[<n>] with its text.
          out.endnoteInsert = await ed.officeApplyOneOp({ op: "insert_endnote", ref: "p0", text: "PROBE_ENDNOTE" });
          const elements = JSON.parse(ed.api.getElements());
          out.walkerTail = (elements || []).slice(-6).map(el => el.ref);
          // NOTE: no JS regex literals in this Elixir heredoc — the heredoc
          // strips backslashes, so /\[\d/ reaches the browser as /[d/ .
          const en = (elements || []).find(el => (el.ref || "").startsWith("en["));
          out.endnote = en && { ref: en.ref, type: en.type, text: (en.text || "").slice(0, 30) };
        } catch (e) {
          out.footnoteError = String(e);
        }
      } catch (e) {
        out.error = String(e);
      }
      window.__probeResult = JSON.stringify(out);
    })();
    return true;
    """)

    assert poll(session, "return window.__probeResult != null;", 60_000),
           "resolveRef probe never finished"

    raw = js(session, "return window.__probeResult;")
    result = Jason.decode!(raw)

    assert result["error"] == nil, "probe threw: #{inspect(result["error"])}"
    assert result["hasResolve"], "soffice.wasm is missing the resolveRef export"
    assert result["anchor"]["ok"], "anchor pick failed: #{raw}"

    probe = result["probe"]
    assert probe && probe["ok"], "no hover probe resolved a ref: #{raw}"

    # The probe must TRACK the pointer: a vertical sweep across title + table +
    # body paragraphs has to resolve several DISTINCT refs (the p0-pinned
    # regression resolved every point to the restored anchor), and crossing the
    # table must yield at least one cell hit.
    refs =
      result["attempts"]
      |> Enum.filter(& &1["ok"])
      |> Enum.map(& &1["ref"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    assert length(refs) >= 3,
           "hover probes do not track the pointer (refs=#{inspect(refs)}): #{raw}"

    assert Enum.any?(result["attempts"], &(&1["type"] == "cell")),
           "sweeping across the table never resolved a cell: #{raw}"

    # Accurate bounds: real per-line rects with positive extent — not the
    # legacy caret-box fallback (which never populates `rects`).
    assert probe["rectCount"] >= 1, "probe carried no rects: #{raw}"
    rect = probe["rect0"]
    assert rect["width"] > 0 and rect["height"] > 0

    # The hover contract: commit=false probes hand the caret back.
    assert result["caretRestored"],
           "hover probe stole the caret: before=#{inspect(result["caretBefore"])} " <>
             "after=#{inspect(result["caretAfter"])} full=#{raw}"

    # Footnote picking: the planted footnote resolves with an fn[<n>] ref and
    # carries its text + rects.
    assert result["footnoteError"] == nil,
           "footnote leg threw: #{inspect(result["footnoteError"])}"

    footnote = result["footnote"]
    assert footnote, "hover never resolved the planted footnote: #{raw}"
    assert footnote["ref"] =~ ~r/^fn\[\d+\]$/
    assert footnote["text"] =~ "PROBE_FOOTNOTE"
    assert footnote["rects"] >= 1

    # Endnote addressing: the walker lists the planted endnote as en[<n>].
    endnote = result["endnote"]
    assert endnote, "walker never listed the planted endnote: #{raw}"
    assert endnote["ref"] =~ ~r/^en\[\d+\]$/
    assert endnote["type"] == "endnote"
    assert endnote["text"] =~ "PROBE_ENDNOTE"
  end

  # ── plumbing (mirrors doc_browser_op_matrix_test) ─────────────────────────

  defp open_file(session, name) do
    assert poll(
             session,
             "if (!document.querySelector('.phx-connected')) return false;" <>
               "var el = document.querySelector('[phx-click=\"open_file\"][phx-value-path=\"#{name}\"]');" <>
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
