import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { officeReadRefCandidates, readOfficeElements } from "../js/wasm_office_read.ts"
import type { OfficeElement } from "../js/wasm_office_ops.ts"

describe("readOfficeElements", () => {
  const slideElements: OfficeElement[] = [
    {
      ref: "page[Handling I/O Devices in Software]",
      text: "Handling I/O Devices in Software",
      type: "slide",
    },
    {
      ref: "page[Handling I/O Devices in Software]/shape[Title 1]",
      text: "Handling I/O Devices in Software",
      type: "text_frame",
    },
    {
      ref: "page[Handling I/O Devices in Software]/shape[Title 1]/p0/r0",
      text: "Handling I/O Devices in Software",
      type: "run",
    },
    {
      ref: "page[Handling I/O Devices in Software]/shape[Content Placeholder 2]",
      text: "I/O devices typically provide 3 kinds of registers",
      type: "text_frame",
    },
  ]

  it("returns only the target text for a title shape even when nearby includes slide siblings", () => {
    const read = readOfficeElements(
      slideElements,
      "page[Handling I/O Devices in Software]/shape[Title 1]",
      { before: 1, after: 2, unit: "element" },
    )

    assert.equal(read.target.ref, "page[Handling I/O Devices in Software]/shape[Title 1]")
    assert.equal(read.text, "Handling I/O Devices in Software")
    assert.equal(read.target.text, "Handling I/O Devices in Software")
    assert.ok(read.elements.some((el: OfficeElement) => el.ref.endsWith("/shape[Content Placeholder 2]")))
    assert.ok(!read.elements.some((el: OfficeElement) => el.type === "run"))
  })

  it("keeps whole-slide aggregation for page refs", () => {
    const read = readOfficeElements(slideElements, "page[Handling I/O Devices in Software]")

    assert.equal(read.target.type, "slide")
    assert.equal(
      read.text,
      "Handling I/O Devices in Software\nI/O devices typically provide 3 kinds of registers",
    )
    assert.equal(read.target.text, read.text)
    assert.deepEqual(read.elements.map((el: OfficeElement) => el.type), ["text_frame", "text_frame"])
  })

  it("collapses pptx run refs to their shape target when no paragraph element exists", () => {
    assert.deepEqual(
      officeReadRefCandidates("page[Slide]/shape[Title 1]/p0/r0"),
      [
        "page[Slide]/shape[Title 1]/p0/r0",
        "page[Slide]/shape[Title 1]/p0",
        "page[Slide]/shape[Title 1]",
      ],
    )

    const read = readOfficeElements(slideElements, "page[Handling I/O Devices in Software]/shape[Title 1]/p0/r0")
    assert.equal(read.resolved_ref, "page[Handling I/O Devices in Software]/shape[Title 1]")
    assert.equal(read.text, "Handling I/O Devices in Software")
  })
})
