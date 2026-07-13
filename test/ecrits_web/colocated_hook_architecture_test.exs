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
    refute source =~ "[data-role='local-hwp-editor'][data-editor-mirror='false']"

    refute source =~
             ~r/data-(?:document-id|document-path|scroll-top|scroll-left|local-document-id|local-document-format|bytes-url|editor-mirror|preview-turn-id|preview-text|preview-delta-count|preview-highlights)=/

    refute File.exists?("assets/js/wasm_hwp_editor.ts")
    refute File.exists?("assets/js/wasm_hwp_keys.ts")
    refute File.exists?("assets/js/wasm_ops.ts")
  end

  test "OfficeWasm keeps only ephemeral browser-engine state in its colocated adapter" do
    source = File.read!(@office_engine_adapter)

    assert source =~ ~s(name=".WasmOfficeEditor")
    assert source =~ "const WasmOfficeEditor = {"
    assert source =~ "export default OfficeWasmHook"
    assert source =~ "data-canvas-state={DocumentCanvasState.encode(@state)}"

    refute source =~ ~r/import\s+.*wasm_office/

    refute source =~
             ~r/data-(?:document-id|document-path|scroll-top|scroll-left|local-document-id|local-document-format|bytes-url|editor-mirror|preview-turn-id|preview-text|preview-delta-count|preview-highlights)=/

    refute File.exists?("assets/js/wasm_office_editor.js")
    refute File.exists?("assets/js/wasm_office_ops.ts")
    refute File.exists?("assets/js/wasm_office_read.ts")
  end

  test "app.js is only the Phoenix bootstrap and consumes colocated hooks" do
    source = File.read!("assets/js/app.js")

    assert source =~ ~s(import {hooks as colocatedHooks} from "phoenix-colocated/ecrits")
    assert source =~ "hooks: colocatedHooks"
    refute source =~ "installEcritsClientBehavior"
    refute source =~ ~r/^\s*import\s+.*(?:from\s+)?["']\.\//m
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

  test "retired external UI hook controllers stay deleted" do
    refute Enum.any?(
             ~w(
               ecrits_app.js
               editor_zoom.js
               local_chat_rail_resizer.js
               local_editor_shortcuts.ts
               local_editor_toolbar.js
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
      ~r/data-(?:document-id|document-path|scroll-top|scroll-left|document-name|contract-type-key|local-document-id|local-document-format|bytes-url|editor-mirror|preview-turn-id|preview-text|preview-delta-count|preview-highlights)=/

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
