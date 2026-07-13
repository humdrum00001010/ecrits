import { readFileSync } from "node:fs"

let officeWasmModule: Promise<Record<string, any>> | null = null

export function importOfficeWasmInternals() {
  if (officeWasmModule) return officeWasmModule

  const component = new URL(
    "../../../lib/ecrits_web/live/studio/components/canvas/office_wasm.ex",
    import.meta.url,
  )
  const source = readFileSync(component, "utf8")
  const hook = source.match(
    /<script\s+:type=\{Phoenix\.LiveView\.ColocatedHook\}\s+name="\.WasmOfficeEditor">([\s\S]*?)<\/script>/,
  )

  if (!hook) throw new Error("OfficeWasm colocated hook not found")

  const moduleSource =
    hook[1].replace(/\bexport default OfficeWasmHook\s*$/, "") +
    "\nexport { OfficeWasmHook, WasmOfficeEditor, rewriteOfficeOp, OFFICE_OPS, normalizeOfficeNearby, officeReadRefCandidates, readOfficeElements }\n"

  const url = `data:text/javascript;base64,${Buffer.from(moduleSource).toString("base64")}`
  officeWasmModule = import(url)
  return officeWasmModule
}
