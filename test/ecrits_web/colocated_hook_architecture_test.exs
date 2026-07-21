defmodule EcritsWeb.ColocatedHookArchitectureTest do
  use ExUnit.Case, async: true

  @colocated_script ~r/<script\s+:type=\{Phoenix\.LiveView\.ColocatedHook\}.*?<\/script>/s
  @controller_field_assignment ~r/\bthis\.[A-Za-z_$][A-Za-z0-9_$]*\s*=(?!=)/
  @office_engine_adapter "lib/ecrits_web/live/studio/components/canvas/office_wasm.ex"
  @hwp_engine_adapter "lib/ecrits_web/live/studio/components/canvas/hwp_pages.ex"

  test "colocated hooks do not own controller state in this fields" do
    violations =
      "lib/ecrits_web/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&(&1 in [@office_engine_adapter, @hwp_engine_adapter]))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(&Regex.scan(@colocated_script, &1))
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {[script], index} ->
          if Regex.match?(@controller_field_assignment, script), do: [{path, index}], else: []
        end)
      end)

    assert violations == [],
           "colocated hooks must delegate state to embedded domain models; violations: #{inspect(violations)}"
  end

  test "HwpPages keeps only ephemeral browser-engine state in its colocated adapter" do
    source = File.read!(@hwp_engine_adapter)

    assert source =~ ~s(name=".WasmHwpEditor")
    assert source =~ "var WasmHwpEditor = {"
    assert source =~ "hwp_colocated_entry_default as default"
    assert source =~ "data-canvas-state={DocumentCanvasState.encode(@state)}"

    refute source =~ ~r/import\s+.*wasm_hwp/
    refute source =~ "[data-role='hwp-editor'][data-editor-mirror='false']"

    refute source =~
             ~r/data-(?:document-id|document-path|scroll-top|scroll-left|document-id|document-format|bytes-url|editor-mirror|preview-turn-id|preview-text|preview-delta-count|preview-highlights)=/

    refute File.exists?("assets/js/wasm_hwp_editor.ts")
    refute File.exists?("assets/js/wasm_hwp_keys.ts")
    refute File.exists?("assets/js/wasm_ops.ts")
  end

  test "HWP edit preview renders the base page before framing saved highlights" do
    source = File.read!(@hwp_engine_adapter)

    assert source =~
             ~r/for \(const page of pages\).*?this\.renderPage\(page\).*?this\.paintSavedEditHighlightsOnPage\(page\).*?this\.frameSavedEditHighlights\(rects\)/s

    assert source =~
             ~r/if \(!this\.rendered \|\| !this\.rendered\.get\(target\.pageIndex\)\) this\.renderPage\(target\.pageIndex\).*?previewBaseFrameReady = "true"/s

    assert source =~
             ~r/latestHighlightIndex.*?savedHighlightIndex.*?target.*?savedHighlightIndex === latestHighlightIndex/s
  end

  test "HWP edit preview paints pinned snapshot highlights without an authority round trip" do
    source = File.read!(@hwp_engine_adapter)

    assert source =~
             ~r/handleLoadedPreviewHighlights.*?const pinnedSnapshot = this\.pinnedPreviewSnapshot\(\).*?syncPinnedPreviewPageFilter\(\).*?this\.renderSavedEditHighlights\(\)/s

    assert source =~
             ~r/pinnedPreviewSnapshot\(\).*?previewSnapshotPinned === true/s
  end

  test "HWP pinned snapshot previews ignore mutable authority events and refresh page filters" do
    source = File.read!(@hwp_engine_adapter)

    assert source =~
             ~r/document\.preview\.revision_received.*?this\.mirror && !this\.pinnedPreviewSnapshot\(\).*?queuePreviewRevision/s

    assert source =~
             ~r/onPreviewAuthority.*?this\.mirror && !this\.pinnedPreviewSnapshot\(\).*?applyAuthoritativePreviewState/s

    assert source =~
             ~r/requestAuthoritativePreview.*?if \(!this\.mirror \|\| this\.pinnedPreviewSnapshot\(\)\) return false/s

    assert source =~
             ~r/syncPinnedPreviewPageFilter.*?previewPageIndexesForSavedHighlights.*?buildPageStack\(\).*?renderVisiblePages\(\)/s

    assert source =~
             ~r/handleLoadedPreviewHighlights.*?pinnedSnapshot.*?syncPinnedPreviewPageFilter\(\).*?renderSavedEditHighlights\(\)/s
  end

  test "HWP edit preview renders actual saved states without synthetic playback" do
    source = File.read!(@hwp_engine_adapter)

    refute source =~ "startVfsPreviewPlayback"
    refute source =~ "applyVfsPreviewStep"
    refute source =~ "previewPlaybackIndex"

    assert source =~
             ~r/this\.previewPageFilter = this\.previewPageIndexesForSavedHighlights\(\).*?this\.buildPageStack\(\).*?this\.renderVisiblePages\(\).*?handleLoadedPreviewHighlights/s
  end

  test "HWP applies each genuine preview revision as one direct semantic batch" do
    source = File.read!(@hwp_engine_adapter)

    refute source =~ "applyAgentEditBatchPaced"

    assert source =~
             ~r/document\.preview\.revision_received.*?queuePreviewRevision.*?applyAgentEditBatch\(\{ ops \}/s

    assert source =~ ~r/previewRevisionKey.*?edit_id.*?revision/s
  end

  test "HWP insert_paragraph appends after its live anchor instead of prepending" do
    source = File.read!(@hwp_engine_adapter)

    assert source =~
             ~r/var opInsertParagraph.*?insertedParagraph = appending \? idx : idx \+ 1.*?paragraphLength\(target\.section, idx\).*?insertTextLines\(\{ section: target\.section, paragraph: idx \}, offset, "\\n" \+ text\)/s

    refute source =~
             ~r/opInsertParagraph.*?insertTextLines\(\{ section: target\.section, paragraph: idx \}, 0, text \+ "\\n"\)/s
  end

  test "OfficeWasm keeps only ephemeral browser-engine state in its colocated adapter" do
    source = File.read!(@office_engine_adapter)

    assert source =~ ~s(name=".WasmOfficeEditor")
    assert source =~ "const WasmOfficeEditor = {"
    assert source =~ "export default OfficeWasmHook"
    assert source =~ "data-canvas-state={DocumentCanvasState.encode(@state)}"

    refute source =~ ~r/import\s+.*wasm_office/

    refute source =~
             ~r/data-(?:document-id|document-path|scroll-top|scroll-left|document-id|document-format|bytes-url|editor-mirror|preview-turn-id|preview-text|preview-delta-count|preview-highlights)=/

    refute File.exists?("assets/js/wasm_office_editor.js")
    refute File.exists?("assets/js/wasm_office_ops.ts")
    refute File.exists?("assets/js/wasm_office_read.ts")
  end

  test "Office applies each genuine preview revision as one direct semantic batch" do
    source = File.read!(@office_engine_adapter)

    assert source =~
             ~r/document\.preview\.revision_received.*?queuePreviewRevision.*?officeApplyEditBatch/s

    assert source =~ ~r/previewRevisionKey.*?edit_id.*?revision/s
  end

  test "Office pinned snapshot previews ignore mutable revision events" do
    source = File.read!(@office_engine_adapter)

    assert source =~
             ~r/document\.preview\.revision_received.*?this\.mirror && !this\.pinnedPreviewSnapshot\(\).*?queuePreviewRevision/s

    assert source =~
             ~r/pinnedPreviewSnapshot\(\).*?previewSnapshotPinned === "true"/s

    assert source =~
             ~r/queuePreviewRevision.*?!this\.mirror \|\| this\.pinnedPreviewSnapshot\(\).*?return false/s
  end

  test "app.js is only the Phoenix bootstrap and consumes colocated hooks" do
    source = File.read!("assets/js/app.js")

    assert source =~ ~s(import {hooks as colocatedHooks} from "phoenix-colocated/ecrits")
    assert source =~ "hooks: colocatedHooks"
    assert source =~ "params: {_csrf_token: csrfToken}"
    refute source =~ "installEcritsClientBehavior"
    refute source =~ "chat_rail_tab_id"
    refute source =~ "sessionStorage"
    refute source =~ ~r/^\s*import\s+.*(?:from\s+)?["']\.\//m
  end

  test "workspace owns browser-tab identity in a colocated hook" do
    source = File.read!("lib/ecrits_web/live/workspace/workspace_live.ex")

    assert source =~ ~s(phx-hook=".ChatRailTabIdentity")
    assert source =~ ~s(name=".ChatRailTabIdentity")
    assert source =~ "sessionStorage"
    assert source =~ ~s(pushEvent("workspace.chat_rail.tab_ready")
    assert source =~ ~r/mounted\(\).*announceChatRailTab\(this\)/s
    assert source =~ ~r/reconnected\(\).*announceChatRailTab\(this\)/s
  end

  test "app.js is the only source file under assets/js" do
    assert Path.wildcard("assets/js/*") == ["assets/js/app.js"]
  end

  test "project modules and source paths do not use Local prefixes or namespaces" do
    source_violations =
      ["lib/**/*.{ex,heex}", "test/**/*.exs"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.filter(fn path ->
        File.read!(path) =~ ~r/\bLocal[A-Z][A-Za-z0-9_]*\b|\bEcrits(?:Web)?\.Local\b/
      end)

    path_violations =
      ["lib/**/*", "test/**/*"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.filter(fn path ->
        Enum.any?(Path.split(path), &(&1 == "local" or String.starts_with?(&1, "local_")))
      end)

    assert source_violations == []
    assert path_violations == []
  end

  # Everything in this app is local, so the prefix carries no information.
  # Swept 2026-07-18 (assigns, functions, DOM ids/roles, URL segments, form
  # names, spec keys); this keeps it from creeping back. "local-first" and
  # "local-only" are prose, not identifiers.
  test "runtime names do not use local prefixes" do
    violations =
      ["lib/**/*.{ex,heex}", "test/**/*.exs", "assets/js/**/*.{js,ts}", "assets/test/**/*.ts"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} ->
          line
          |> String.replace(~w(local-first local-only), "")
          |> String.match?(~r/local[_-][a-z]/)
        end)
        |> Enum.map(fn {_line, n} -> "#{path}:#{n}" end)
      end)

    assert violations == []
  end

  test "retired external UI hook controllers stay deleted" do
    refute Enum.any?(
             ~w(
               ecrits_app.js
               editor_zoom.js
               chat_rail_resizer.js
               editor_shortcuts.ts
               editor_toolbar.js
               markdown_editor.js
               observex_preview.js
             ),
             &File.exists?(Path.join("assets/js", &1))
           )
  end

  test "web templates use colocated hook names only" do
    external_hooks =
      "lib/ecrits_web/**/*.{ex,heex}"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(&Regex.scan(~r/phx-hook\s*=\s*["']([^"']+)["']/, &1, capture: :all_but_first))
        |> Enum.map(fn [name] -> {path, name} end)
        |> Enum.reject(fn {_path, name} -> String.starts_with?(name, ".") end)
      end)

    assert external_hooks == [],
           "phx-hook bindings must resolve through the colocated manifest: #{inspect(external_hooks)}"
  end

  test "document canvases transmit their embedded state once" do
    legacy_parallel_attrs =
      ~r/data-(?:document-id|document-path|scroll-top|scroll-left|document-name|contract-type-key|document-id|document-format|bytes-url|editor-mirror|preview-turn-id|preview-text|preview-delta-count|preview-highlights)=/

    for path <- [
          "lib/ecrits_web/live/studio/components/canvas/hwp_pages.ex",
          "lib/ecrits_web/live/studio/components/canvas/markdown_editor.ex",
          "lib/ecrits_web/live/studio/components/canvas/office_wasm.ex"
        ] do
      source = File.read!(path)

      assert length(Regex.scan(~r/data-canvas-state=/, source)) == 1,
             "#{path} must transmit DocumentCanvasState through one data-canvas-state attribute"

      refute Regex.match?(legacy_parallel_attrs, source),
             "#{path} must not expand DocumentCanvasState back into parallel data attributes"
    end
  end

  test "editor surface consumes its embedded model without unpacking parallel assigns" do
    source = File.read!("lib/ecrits_web/live/studio/components/editor_surface.ex")

    refute source =~ "|> assign(:document, state.document)"
    refute source =~ "|> assign(:active_document_id, state.active_document_id)"
    refute source =~ "|> assign(:editor_toolbar, state.editor_toolbar)"
    assert source =~ "@state.document"
    assert source =~ "@state.editor_toolbar"
  end

  test "mount screen passes its embedded model across the component boundary" do
    live_source = File.read!("lib/ecrits_web/live/workspace/mount_live.ex")
    component_source = File.read!("lib/ecrits_web/components/core_components.ex")

    assert live_source =~ "workspace_mount={@workspace_mount}"
    refute live_source =~ "picker_busy?={@workspace_mount.picker_busy?}"
    refute live_source =~ "mount_error={@workspace_mount.error}"
    refute live_source =~ "path_form={"

    assert component_source =~ "@workspace_mount.picker_busy?"
    assert component_source =~ "@workspace_mount.error"
    assert component_source =~ "%{workspace_mount: %WorkspaceMount{}}"
  end
end
