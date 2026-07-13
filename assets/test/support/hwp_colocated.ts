import { readFileSync } from "node:fs"

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
    const moduleUrl = `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
    loaded = import(moduleUrl)
  }

  return loaded
}
