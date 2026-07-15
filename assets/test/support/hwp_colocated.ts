import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

const sourceUrl = new URL(
  "../../../lib/ecrits_web/live/studio/components/canvas/hwp_pages.ex",
  import.meta.url,
)

export const hwpColocatedSource = () => {
  const component = readFileSync(sourceUrl, "utf8")
  const match = component.match(
    /<script[\s\S]*?name="\.WasmHwpEditor"[\s\S]*?>([\s\S]*?)<\/script>/,
  )

  if (!match) throw new Error("HwpPages colocated hook source was not found")
  return match[1]
}

let loaded: Promise<any> | null = null

export const loadHwpColocatedHook = () => {
  if (!loaded) {
    const source = hwpColocatedSource().replace(
      'ensureWasm().catch((error) => console.error("[wasm-hwp] init failed", error));',
      'if (typeof location !== "undefined") ensureWasm().catch((error) => console.error("[wasm-hwp] init failed", error));',
    )
    loaded = (async () => {
      const dir = mkdtempSync(join(tmpdir(), "ecrits-hwp-hook-"))
      const modulePath = join(dir, "hwp_colocated.mjs")
      writeFileSync(modulePath, source)

      try {
        return await import(pathToFileURL(modulePath).href)
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    })()
  }

  return loaded
}
