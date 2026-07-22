# Document and VFS Normalization Schemas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace manual document operation, read-option, sanitizer-summary, edit-event, and OpenDocs lifecycle normalization with Ecto schemas while preserving document engine and PubSub wire contracts.

**Architecture:** Small discriminators select bounded operation schemas; fixed option, summary, event, and lifecycle records each have one embedded schema. Arbitrary engine properties remain explicit string-keyed maps. Browser code consumes server-normalized read options and keeps browser-only rectangle normalization local.

**Tech Stack:** Elixir 1.20, Ecto 3.13, Phoenix PubSub/LiveView, ExUnit, FSKit/exfuse integration.

## Global Constraints

- A normalizer or sanitizer handling more than three fields must use an Ecto schema.
- Preserve existing `doc.*`, engine, VFS, PubSub, and browser wire shapes.
- Do not create atoms from agent or engine input.
- Keep arbitrary engine properties string-keyed in an explicit `props` or extension map.
- Keep browser-only five-field geometry normalization local.
- Write and run a failing test before each production change.
- Restart the app only if dependency/NIF/port code changes; this plan changes none.

---

### Task 1: Model `doc.read` nearby options once

**Files:**
- Create: `lib/ecrits/doc/read/nearby.ex`
- Create: `test/ecrits/doc/read/nearby_test.exs`
- Modify: `lib/ecrits/doc/tools.ex`
- Modify: `lib/ecrits_web/live/studio/components/canvas/hwp_pages.ex`
- Modify: `lib/ecrits_web/live/studio/components/canvas/office_wasm.ex`
- Modify: `test/ecrits/doc/tools_test.exs`
- Modify: `test/ecrits_web/features/doc_browser_op_matrix_test.exs`

**Interfaces:**
- Consumes: optional atom- or string-keyed nearby maps.
- Produces: `Nearby.cast/1`, `cast!/1`, and `dump/1` with `before`, `after`, `row`, `column`, and `headers`.

- [ ] **Step 1: Write the failing schema test**

```elixir
defmodule Ecrits.Doc.Read.NearbyTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.Read.Nearby

  test "casts defaults and clamps counts" do
    assert {:ok, %Nearby{} = nearby} =
             Nearby.cast(%{"before" => 20, "after" => -1, "column" => true})

    assert Nearby.dump(nearby) == %{
             "before" => 10,
             "after" => 2,
             "row" => true,
             "column" => true,
             "headers" => true
           }
  end

  test "non-map input receives the canonical defaults" do
    assert {:ok, nearby} = Nearby.cast(nil)
    assert Nearby.dump(nearby)["before"] == 2
  end
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mise exec -- mix test test/ecrits/doc/read/nearby_test.exs`

Expected: compilation fails because `Ecrits.Doc.Read.Nearby` does not exist.

- [ ] **Step 3: Implement the schema and replace server normalization**

Use an embedded schema with integer fields `before` and `after`, boolean fields `row`, `column`, and `headers`, and the current defaults. Cast invalid counts to defaults before changeset application, then clamp valid non-negative counts to `10`. Replace `Tools.normalize_nearby/1` with `Nearby.cast!/1 |> Nearby.dump()`.

- [ ] **Step 4: Remove browser-owned copies**

Delete `normalizeAgentNearby` and `normalizeOfficeNearby`. Both reader paths must consume the already-complete five-field map sent by the server; use direct property reads and retain no browser defaulting or clamping.

- [ ] **Step 5: Run focused tests and commit**

Run: `mise exec -- mix test test/ecrits/doc/read/nearby_test.exs test/ecrits/doc/tools_test.exs test/ecrits_web/features/doc_browser_op_matrix_test.exs`

Expected: server and browser read tests pass, and `rg -n 'normalizeAgentNearby|normalizeOfficeNearby' lib/ecrits_web` returns no definitions.

```bash
git add lib/ecrits/doc/read/nearby.ex lib/ecrits/doc/tools.ex lib/ecrits_web/live/studio/components/canvas/hwp_pages.ex lib/ecrits_web/live/studio/components/canvas/office_wasm.ex test/ecrits/doc/read/nearby_test.exs test/ecrits/doc/tools_test.exs test/ecrits_web/features/doc_browser_op_matrix_test.exs
git commit -m "Normalize document nearby options with Ecto"
```

### Task 2: Model compact tool-payload deck summaries

**Files:**
- Create: `lib/ecrits/doc/tool_payload/compact_deck.ex`
- Create: `test/ecrits/doc/tool_payload/compact_deck_test.exs`
- Modify: `lib/ecrits/doc/tool_payload_sanitizer.ex`
- Modify: `test/ecrits/doc/tool_payload_sanitizer_test.exs`

**Interfaces:**
- Consumes: a presentation deck map.
- Produces: `CompactDeck.cast/1` and `dump/1` with string-keyed `title`, `subtitle`, slide count, and slide titles.

- [ ] **Step 1: Write the failing compact-deck test**

```elixir
defmodule Ecrits.Doc.ToolPayload.CompactDeckTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.ToolPayload.CompactDeck

  test "summarizes authored slides through an embedded schema" do
    assert {:ok, deck} =
             CompactDeck.cast(%{
               "title" => "Board update",
               "subtitle" => "Q2",
               "slides" => [%{"title" => "Problem"}, %{"title" => "Solution"}]
             })

    assert CompactDeck.dump(deck) == %{
             "title" => "Board update",
             "subtitle" => "Q2",
             "slides" => 2,
             "slide_titles" => ["Problem", "Solution"]
           }
  end
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mise exec -- mix test test/ecrits/doc/tool_payload/compact_deck_test.exs`

Expected: compilation fails because `CompactDeck` does not exist.

- [ ] **Step 3: Implement and route the schema**

The schema fields are `title`, `subtitle`, `slides` as integer, and `slide_titles` as string array. `cast/1` derives count and titles before `Ecto.Changeset.cast/3`. Replace `compact_deck/1` with `CompactDeck.cast/1` and `dump/1`; keep recursive retired-metadata scrubbing generic and unchanged.

- [ ] **Step 4: Run tests and commit**

Run: `mise exec -- mix test test/ecrits/doc/tool_payload/compact_deck_test.exs test/ecrits/doc/tool_payload_sanitizer_test.exs`

Expected: all sanitizer tests pass with the exact prior JSON shape.

```bash
git add lib/ecrits/doc/tool_payload/compact_deck.ex lib/ecrits/doc/tool_payload_sanitizer.ex test/ecrits/doc/tool_payload/compact_deck_test.exs test/ecrits/doc/tool_payload_sanitizer_test.exs
git commit -m "Model compact deck summaries with Ecto"
```

### Task 3: Replace the document operation key registry with variant schemas

**Files:**
- Create: `lib/ecrits/doc/op/dispatcher.ex`
- Create: `lib/ecrits/doc/op/text.ex`
- Create: `lib/ecrits/doc/op/table.ex`
- Create: `lib/ecrits/doc/op/picture.ex`
- Create: `lib/ecrits/doc/op/shape.ex`
- Create: `lib/ecrits/doc/op/layout.ex`
- Create: `test/ecrits/doc/op_schema_test.exs`
- Modify: `lib/ecrits/doc/op.ex`
- Modify: `test/ecrits/doc/op_test.exs`
- Modify: `test/ecrits/doc/op_matrix_audit_test.exs`

**Interfaces:**
- Consumes: current atom- or string-keyed operation maps.
- Produces: `Op.normalize/1` with the unchanged `{:ok, atom_keyed_map}` or existing error tuples; typed structs exist only inside the boundary.

- [ ] **Step 1: Write failing variant and coverage tests**

```elixir
test "every advertised verb dispatches to exactly one Ecto schema" do
  for verb <- Ecrits.Doc.Op.verbs() do
    module = Ecrits.Doc.Op.Dispatcher.schema_for(verb)
    assert is_atom(module)
    assert function_exported?(module, :changeset, 2)
  end
end

test "shape extensions stay string keyed" do
  assert {:ok, op} =
           Ecrits.Doc.Op.normalize(%{
             "op" => "insert_shape",
             "page" => "summary",
             "name" => "title",
             "x" => 100,
             "y" => 100,
             "w" => 1_000,
             "h" => 500,
             "CharHeight" => 32
           })

  assert op.op == "insert_shape"
  assert op["CharHeight"] == 32
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mise exec -- mix test test/ecrits/doc/op_schema_test.exs`

Expected: compilation fails because `Ecrits.Doc.Op.Dispatcher` does not exist.

- [ ] **Step 3: Implement bounded operation schemas**

Create these semantic schemas and verb assignments:

- `Text`: `insert_text`, `delete_range`, `replace_text`, `insert_paragraph`, `delete_paragraph`, `split`, `merge`, `set_cell`, `insert_footnote`, `insert_endnote`, `insert_equation`, and `delete_node`.
- `Table`: `insert_table`, row/column insert/delete, `merge_cells`, and `split_cell`.
- `Picture`: `insert_picture` and its source, dimensions, binary transport, and cell-overlay fields.
- `Shape`: `insert_shape`, `set_geometry`, and arbitrary string-keyed engine properties in virtual `extensions`.
- `Layout`: `set_columns` and `insert_slide`.

Each schema uses `Ecto.Enum` for its bounded verb set, casts its full current field list, performs the existing per-verb required-field checks in `validate_change`/changeset helpers, and exposes `dump/1`. `Dispatcher.schema_for/1` pattern matches known strings and returns `nil` for unknown values; it never calls `String.to_atom/1`.

- [ ] **Step 4: Switch `Op.normalize/1` and remove manual authority**

Keep `reject_retired_metadata/1`. After it passes, select the schema, apply its changeset, and dump to the current atom-keyed map. Delete `@known_op_keys`, `@known_op_key_by_name`, `atomize/1`, and the old `validate/2` clauses after their invariants live in schemas.

- [ ] **Step 5: Run the operation matrix and commit**

Run: `mise exec -- mix test test/ecrits/doc/op_schema_test.exs test/ecrits/doc/op_test.exs test/ecrits/doc/op_matrix_audit_test.exs test/ecrits/doc/rhwp_op_matrix_test.exs test/ecrits/doc/office/op_classify_test.exs test/ecrits/doc/office_uno_op_matrix_test.exs`

Expected: all operation and backend matrices pass with no changed wire operations.

```bash
git add lib/ecrits/doc/op.ex lib/ecrits/doc/op/dispatcher.ex lib/ecrits/doc/op/text.ex lib/ecrits/doc/op/table.ex lib/ecrits/doc/op/picture.ex lib/ecrits/doc/op/shape.ex lib/ecrits/doc/op/layout.ex test/ecrits/doc/op_schema_test.exs test/ecrits/doc/op_test.exs test/ecrits/doc/op_matrix_audit_test.exs
git commit -m "Validate document operations with Ecto schemas"
```

### Task 4: Share the VFS edit lifecycle event schema

**Files:**
- Create: `lib/ecrits/doc/edit_lifecycle_event.ex`
- Create: `test/ecrits/doc/edit_lifecycle_event_test.exs`
- Modify: `lib/ecrits/doc/projection.ex`
- Modify: `lib/ecrits_web/live/workspace/workspace_live.ex`
- Modify: `test/ecrits/doc/projection_test.exs`
- Modify: `test/ecrits_web/live/workspace/mount_workspace_live_test.exs`

**Interfaces:**
- Consumes: candidate, committed, rejected, and snapshot-ready edit event maps.
- Produces: `EditLifecycleEvent.cast/1`, `cast!/1`, and `dump/1`, used at both PubSub publication and LiveView receipt.

- [ ] **Step 1: Write the failing lifecycle schema test**

```elixir
defmodule Ecrits.Doc.EditLifecycleEventTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.EditLifecycleEvent

  test "casts string-keyed lifecycle data and defaults collections" do
    assert {:ok, event} =
             EditLifecycleEvent.cast(%{
               "phase" => "committed",
               "turn_id" => "turn-1",
               "edit_id" => "edit-1",
               "document_id" => "doc-1",
               "revision" => 7,
               "ops" => nil
             })

    assert %EditLifecycleEvent{phase: :committed, ops: [], sets: [], highlights: []} = event
    assert EditLifecycleEvent.dump(event).phase == :committed
  end

  test "rejects unknown phases" do
    assert {:error, %Ecto.Changeset{}} = EditLifecycleEvent.cast(%{phase: "future"})
  end
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mise exec -- mix test test/ecrits/doc/edit_lifecycle_event_test.exs`

Expected: compilation fails because `EditLifecycleEvent` does not exist.

- [ ] **Step 3: Implement the lifecycle schema**

Use `Ecto.Enum` phases `[:candidate, :committed, :rejected, :snapshot_ready]`. Fields are `phase`, `turn_id`, `edit_id`, `document_id`, `revision`, `legacy_lifecycle`, `ops`, `sets`, `highlights`, `preview_snapshot`, `preview_snapshot_error`, `agent_id`, and `instance_id`. Default the three collections to `[]`; require `phase`; preserve optional legacy fields.

- [ ] **Step 4: Move normalization to publication**

At every `{:vfs_doc_edited, info}` publication in `Projection`, cast and dump through the schema. In `WorkspaceLive`, replace `normalize_vfs_edit_lifecycle_event/2` with legacy enrichment followed by `EditLifecycleEvent.cast!/1`; remove the thirteen-field `Map.put` pipeline. The browser receives the same atom-keyed map from `dump/1`.

- [ ] **Step 5: Run lifecycle tests and commit**

Run: `mise exec -- mix test test/ecrits/doc/edit_lifecycle_event_test.exs test/ecrits/doc/projection_test.exs test/ecrits_web/live/workspace/mount_workspace_live_test.exs`

Expected: lifecycle PubSub, preview persistence, and canvas event tests pass.

```bash
git add lib/ecrits/doc/edit_lifecycle_event.ex lib/ecrits/doc/projection.ex lib/ecrits_web/live/workspace/workspace_live.ex test/ecrits/doc/edit_lifecycle_event_test.exs test/ecrits/doc/projection_test.exs test/ecrits_web/live/workspace/mount_workspace_live_test.exs
git commit -m "Model VFS edit lifecycle events with Ecto"
```

### Task 5: Model OpenDocs committed lifecycle state

**Files:**
- Create: `lib/ecrits/fuse/open_docs/lifecycle.ex`
- Create: `test/ecrits/fuse/open_docs_lifecycle_test.exs`
- Modify: `lib/ecrits/fuse/open_docs.ex`
- Modify: `test/ecrits/fuse/doc_fs_consecutive_projection_test.exs`
- Modify: `test/ecrits/doc/projection_write_back_atomicity_test.exs`

**Interfaces:**
- Consumes: lifecycle initialization and state transitions.
- Produces: `%Ecrits.Fuse.OpenDocs.Lifecycle{}` with `bytes`, `dirty_owner`, `generation`, `in_flight`, and `pending`; runtime values are virtual where they cannot be durably dumped.

- [ ] **Step 1: Write the failing lifecycle state test**

```elixir
defmodule Ecrits.Fuse.OpenDocsLifecycleTest do
  use ExUnit.Case, async: true

  alias Ecrits.Fuse.OpenDocs.Lifecycle

  test "builds and validates clean committed state" do
    assert {:ok,
            %Lifecycle{
              bytes: "projection",
              dirty_owner: nil,
              generation: 4,
              in_flight: nil,
              pending: nil
            }} = Lifecycle.cast(%{bytes: "projection", generation: 4})
  end

  test "rejects a negative generation" do
    assert {:error, %Ecto.Changeset{}} =
             Lifecycle.cast(%{bytes: "projection", generation: -1})
  end
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mise exec -- mix test test/ecrits/fuse/open_docs_lifecycle_test.exs`

Expected: compilation fails because the lifecycle schema does not exist.

- [ ] **Step 3: Implement and route the lifecycle schema**

Define non-durable `dirty_owner`, `in_flight`, and `pending` as `:any, virtual: true`; cast `bytes` and non-negative `generation`; validate transition values with existing OpenDocs predicates. Replace `clean_lifecycle/2` with `Lifecycle.cast!/1`. Store the struct in ETS and update it with struct updates, not untyped map reconstruction.

- [ ] **Step 4: Run projection settlement tests and commit**

Run: `mise exec -- mix test test/ecrits/fuse/open_docs_lifecycle_test.exs test/ecrits/fuse/doc_fs_consecutive_projection_test.exs test/ecrits/doc/projection_write_back_atomicity_test.exs`

Expected: canonical staging, echo completion, dirty ownership, and consecutive projection tests pass.

```bash
git add lib/ecrits/fuse/open_docs.ex lib/ecrits/fuse/open_docs/lifecycle.ex test/ecrits/fuse/open_docs_lifecycle_test.exs test/ecrits/fuse/doc_fs_consecutive_projection_test.exs test/ecrits/doc/projection_write_back_atomicity_test.exs
git commit -m "Model OpenDocs lifecycle state with Ecto"
```

### Task 6: Verify document/VFS authority and live flow

**Files:**
- Modify only if tests expose a regression: files already named in Tasks 1-5.
- Modify: `test/ecrits/normalization_schema_boundary_test.exs`

**Interfaces:**
- Consumes: all five document/VFS schema families from this plan.
- Produces: one normalization authority per boundary and live proof of the unchanged edit flow.

- [ ] **Step 1: Record and prove that manual authorities are gone**

Extend `normalization_schema_boundary_test.exs` with:

```elixir
test "document and VFS records have one schema authority" do
  sources =
    [
      "lib/ecrits/doc/tools.ex",
      "lib/ecrits/doc/op.ex",
      "lib/ecrits/fuse/open_docs.ex",
      "lib/ecrits_web/live/workspace/workspace_live.ex"
    ]
    |> Enum.map_join("\n", &File.read!/1)

  refute sources =~ "defp normalize_nearby("
  refute sources =~ "@known_op_keys"
  refute sources =~ "defp clean_lifecycle("
  refute sources =~ "defp normalize_vfs_edit_lifecycle_event("
end
```

Run:

```bash
rg -n 'defp normalize_nearby|@known_op_keys|defp clean_lifecycle|defp normalize_vfs_edit_lifecycle_event|normalizeAgentNearby|normalizeOfficeNearby' lib
```

Expected: no authoritative definitions remain. References in historical comments are acceptable only after confirming they do not execute.

- [ ] **Step 2: Run the full document/VFS regression set**

Run: `mise exec -- mix test test/ecrits/doc test/ecrits/fuse test/ecrits_web/features/doc_browser_op_matrix_test.exs test/ecrits_web/live/workspace/mount_workspace_live_test.exs`

Expected: zero failures.

- [ ] **Step 3: Verify the live edit flow**

Use Tidewave `project_eval` to cast and dump one real `EditLifecycleEvent`, then drive one mounted JSONL edit through the running workspace and use `browser_eval` snapshots to confirm the canvas receives the committed update. Expected flow remains `Agent -> JSONL -> exfuse -> DocFs -> PubSub -> canvas`.

- [ ] **Step 4: Commit only regression fixes, if any**

```bash
git status --short
git add lib/ecrits/doc/read/nearby.ex lib/ecrits/doc/tool_payload/compact_deck.ex lib/ecrits/doc/op.ex lib/ecrits/doc/op/dispatcher.ex lib/ecrits/doc/op/text.ex lib/ecrits/doc/op/table.ex lib/ecrits/doc/op/picture.ex lib/ecrits/doc/op/shape.ex lib/ecrits/doc/op/layout.ex lib/ecrits/doc/edit_lifecycle_event.ex lib/ecrits/doc/projection.ex lib/ecrits/doc/tools.ex lib/ecrits/doc/tool_payload_sanitizer.ex lib/ecrits/fuse/open_docs.ex lib/ecrits/fuse/open_docs/lifecycle.ex lib/ecrits_web/live/studio/components/canvas/hwp_pages.ex lib/ecrits_web/live/studio/components/canvas/office_wasm.ex lib/ecrits_web/live/workspace/workspace_live.ex test/ecrits/normalization_schema_boundary_test.exs
git commit -m "Verify document schema boundaries"
```

If no regression fix was needed, do not create an empty commit.
