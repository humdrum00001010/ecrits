import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

let editorSurfaceModule: Promise<Record<string, any>> | null = null

export function loadEditorSurfaceColocatedHook() {
  if (editorSurfaceModule) return editorSurfaceModule

  const component = new URL(
    "../../../lib/ecrits_web/live/studio/components/editor_surface.ex",
    import.meta.url,
  )
  const source = readFileSync(component, "utf8")
  const hook = source.match(
    /<script\s+:type=\{Phoenix\.LiveView\.ColocatedHook\}\s+name="\.DocumentSearchBridge">([\s\S]*?)<\/script>/,
  )

  if (!hook) throw new Error("DocumentSearchBridge colocated hook not found")

  const moduleSource = `${hook[1]}\nexport { installEditorZoom }\n`
  editorSurfaceModule = (async () => {
    const dir = mkdtempSync(join(tmpdir(), "ecrits-editor-surface-hook-"))
    const modulePath = join(dir, "editor_surface_colocated.mjs")
    writeFileSync(modulePath, moduleSource)

    try {
      return await import(pathToFileURL(modulePath).href)
    } finally {
      rmSync(dir, {recursive: true, force: true})
    }
  })()
  return editorSurfaceModule
}
