# Repository Normalizer Audit Record

## Rule

An authored Elixir normalizer or sanitizer that owns more than three fields of one logical payload must use an Ecto schema. Scalar coercion, recursive arbitrary JSON traversal, collection pruning, and records of three fields or fewer are not schema candidates.

## Audit Method

The audit searched authored Elixir source for `normalize*` and `sanitize*` definitions, then followed their producers and consumers to distinguish semantic records from scalar, recursive, and collection helpers. The final source scan found 129 function clauses; clause count is not record count because most scalar normalizers use several pattern-matching clauses.

Each semantic record was tested at its boundary before the old authority was removed. The permanent authority test is `test/ecrits/normalization_schema_boundary_test.exs`.

## Migrated Semantic Records

| Area | Schema authority | Replaced authority |
| --- | --- | --- |
| Agent transcript | `Ecrits.Agent.Item.*` | broad item field registry and Session file-activity copy |
| ACP input | `Ecrits.AcpAgent.Content.*` | manual content-block atomization and validation |
| Agent persistence | `Ecrits.Agent.DurableState` | Session and handoff state reconstruction |
| Adapter persistence | `Ecrits.Agent.AdapterOptions` | persisted adapter-option filtering |
| Document edits | `Ecrits.Doc.Op.*` | operation key registry and manual verb validation |
| Nearby reads | `Ecrits.Doc.Read.Nearby` | server and browser duplicate option normalization |
| Tool summaries | `Ecrits.Doc.ToolPayload.CompactDeck` | compact deck field sanitizer |
| VFS edit events | `Ecrits.Doc.EditLifecycleEvent` | Projection and LiveView lifecycle reconstruction |
| Open document lifecycle | `Ecrits.Fuse.OpenDocs.Lifecycle` | lifecycle map cleanup and reconstruction |
| Workspace documents | `Ecrits.Workspace.Session.Document` | path/id/scroll reconstruction |
| Workspace foregrounds | `Ecrits.Workspace.Foreground` | Session and handoff foreground reconstruction |
| Turn ownership | `Ecrits.Workspace.TurnOwner` | runtime owner/monitor map validation |
| Turn finalization | `Ecrits.Workspace.TurnFinalizationState` | five parallel finalization collections and active map |

## Remaining Normalizer Classes

- Scalar or path coercion: provider ids, formats, indexes, markers, text, paths, permissions, and tool names.
- Recursive arbitrary data: projection IR value traversal, handoff string-key conversion, and tool-payload JSON scrubbing.
- Collection/index maintenance: dialogs already dispatched through item schemas, foreground selection indexes, viewer lists, slide lists, find patterns, and legacy rail collections.
- Schema-local input preparation: known-key extraction and aliases inside `DurableState`, `AdapterOptions`, `Session.Document`, and `TurnFinalizationState` changesets.
- Public schema dispatch: `Ecrits.Doc.Op.normalize/1` and `Ecrits.AcpAgent.Content.normalize/1` now select and dump typed variants.
- Browser-only geometry: Office/HWP rectangle and cursor normalization remains in colocated JavaScript because Ecto does not execute in the browser. The duplicate browser `nearby` normalizers were removed.

No remaining source definition was found to own an unschematized fixed record with more than three fields under the audit rule.

## Runtime Semantics Preserved

- Unknown provider keys are preserved only in explicit extension maps and are never atomized.
- Explicit `nil` versus absent item fields remains distinguishable where the wire contract requires it.
- Runtime pids, monitor references, functions, adapters, and settings stay virtual and do not enter durable dumps.
- Foreground handoff still compacts large tool input/output while retaining bounded head and tail context.
- Turn-owner monitor cleanup and finalization crash/retry/ack behavior remain monitor-driven.
- Legacy finalization state is cast into one typed subsystem; invalid legacy active workers have their monitors removed and are killed at the hot-state migration boundary.

## Verification Record

- Schema-authority guard: 3 passed.
- Workspace regression directory: 75 passed.
- Simultaneous LiveView terminal-finalization case: 1 passed, 124 excluded by location filter.
- Combined workspace/agent regression: 112 passed and one timing-sensitive queue test missed its two-second event window; the same test passed immediately in isolation. No timeout was widened.
- Final `mix precommit`: 993 passed, 5 excluded, exit status 0.

The work is committed on branch `normalization-schema-surgery`. It is not merged or pushed by this record.
