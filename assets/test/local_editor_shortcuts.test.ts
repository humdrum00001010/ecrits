import { describe, it } from "node:test"
import assert from "node:assert/strict"

import {
  resolveEditorShortcut,
  LOCAL_EDITOR_SHORTCUT_COMMANDS,
  LOCAL_EDITOR_SHIFT_SHORTCUT_COMMANDS,
} from "../js/local_editor_shortcuts.ts"

// An editable control (input/textarea/…): closest() returns itself for the
// editable selector, matching how the real DOM resolves the nearest editable.
function editable(): any {
  const node: any = {}
  node.closest = () => node
  return node
}

// A non-editable node (a canvas, the body): closest() finds no editable.
function plain(): any {
  return { closest: () => null }
}

// A surface whose contains() reports membership from a fixed set.
function surfaceWith(...inside: any[]): any {
  return { contains: (node: any) => inside.includes(node) }
}

describe("resolveEditorShortcut", () => {
  it("maps the primary-modifier B/I/U chords to toolbar commands", () => {
    const body = plain()
    const surface = surfaceWith()
    assert.equal(resolveEditorShortcut({ metaKey: true, key: "b", target: body }, surface, body), "bold")
    assert.equal(resolveEditorShortcut({ metaKey: true, key: "i", target: body }, surface, body), "italic")
    assert.equal(resolveEditorShortcut({ ctrlKey: true, key: "u", target: body }, surface, body), "underline")
    assert.equal(resolveEditorShortcut({ ctrlKey: true, key: "B", target: body }, surface, body), "bold")
  })

  it("ignores keys without exactly the primary modifier", () => {
    const body = plain()
    assert.equal(resolveEditorShortcut({ key: "b", target: body }, surfaceWith(), body), null)
    assert.equal(resolveEditorShortcut({ metaKey: true, altKey: true, key: "b", target: body }, surfaceWith(), body), null)
    assert.equal(resolveEditorShortcut({ altKey: true, key: "b", target: body }, surfaceWith(), body), null)
  })

  it("ignores unmapped chords (⌘S, ⌘Z, …)", () => {
    const body = plain()
    assert.equal(resolveEditorShortcut({ metaKey: true, key: "s", target: body }, surfaceWith(), body), null)
    assert.equal(resolveEditorShortcut({ metaKey: true, key: "z", target: body }, surfaceWith(), body), null)
  })

  it("maps the shift chords to strikethrough and alignment (Docs convention)", () => {
    const body = plain()
    const surface = surfaceWith()
    const chord = (key: string) => ({ metaKey: true, shiftKey: true, key, target: body })
    assert.equal(resolveEditorShortcut(chord("x"), surface, body), "strikethrough")
    assert.equal(resolveEditorShortcut(chord("l"), surface, body), "align-left")
    assert.equal(resolveEditorShortcut(chord("e"), surface, body), "align-center")
    assert.equal(resolveEditorShortcut(chord("r"), surface, body), "align-right")
    assert.equal(resolveEditorShortcut(chord("j"), surface, body), "align-justify")
    // Uppercase key (what shift actually produces) resolves the same.
    assert.equal(resolveEditorShortcut(chord("X"), surface, body), "strikethrough")
  })

  it("keeps the shift and no-shift planes separate", () => {
    const body = plain()
    // ⌘⇧B is NOT bold; ⌘X (cut) is NOT strikethrough.
    assert.equal(resolveEditorShortcut({ metaKey: true, shiftKey: true, key: "b", target: body }, surfaceWith(), body), null)
    assert.equal(resolveEditorShortcut({ metaKey: true, key: "x", target: body }, surfaceWith(), body), null)
  })

  it("keeps its hands off editable controls outside the editor surface", () => {
    const chatInput = editable()
    // Focus in the chat composer / a rename box: leave ⌘B to that control.
    assert.equal(resolveEditorShortcut({ metaKey: true, key: "b", target: chatInput }, surfaceWith(), chatInput), null)
    // Even when the event target is the body, a foreign editable activeElement blocks it.
    assert.equal(resolveEditorShortcut({ metaKey: true, key: "b", target: plain() }, surfaceWith(), chatInput), null)
  })

  it("fires for the editor's own inputs (markdown textarea / IME proxy) inside the surface", () => {
    const imeProxy = editable()
    const surface = surfaceWith(imeProxy)
    assert.equal(resolveEditorShortcut({ metaKey: true, key: "b", target: imeProxy }, surface, imeProxy), "bold")
  })

  it("returns null for a null event", () => {
    assert.equal(resolveEditorShortcut(null, surfaceWith(), null), null)
  })

  it("exposes the same command vocabulary the toolbar buttons emit", () => {
    assert.deepEqual(LOCAL_EDITOR_SHORTCUT_COMMANDS, { b: "bold", i: "italic", u: "underline" })
    assert.deepEqual(LOCAL_EDITOR_SHIFT_SHORTCUT_COMMANDS, {
      x: "strikethrough",
      l: "align-left",
      e: "align-center",
      r: "align-right",
      j: "align-justify",
    })
  })
})
