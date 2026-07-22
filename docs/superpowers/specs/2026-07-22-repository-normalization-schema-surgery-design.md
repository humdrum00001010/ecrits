# Repository Normalization Schema Surgery

## Goal

Apply this repository rule to authored Elixir code:

> If a normalizer or sanitizer handles one logical payload with more than three fields, that payload must be represented by an Ecto schema.

The surgery replaces manual field registries, mixed atom/string key handling, defaulting, coercion, and validation with changeset-owned boundaries. Existing JSONL, ACP, PubSub, VFS, and browser wire shapes remain unchanged.

## Boundary

The rule applies to Elixir normalization and sanitization boundaries. It does not require schemas for:

- scalar normalization;
- a logical payload of three fields or fewer;
- arbitrary recursive JSON or key transformations without a fixed record;
- collection pruning that does not define or validate an element record;
- resource cleanup despite a function name containing `clean` or `cleanup`.

Browser-only geometry normalization is an explicit runtime boundary, because Ecto cannot execute inside browser JavaScript. Five-field rectangles remain browser-local. Browser copies of server-owned normalization, such as `nearby` options, are removed and consume server-normalized values instead.

Generated files under `priv/static`, dependencies, and build output are not source boundaries.

## Architecture

Every affected boundary follows one flow:

`raw map -> discriminator -> Ecto changeset -> typed struct -> existing wire map`

The discriminator may read only the minimum fields needed to select a semantic schema, normally `role`, `type`, or `op`. It must not normalize the selected payload itself.

Each semantic schema owns:

- accepted fields and key casting;
- defaults and empty-value behavior;
- enum coercion;
- required-field and cross-field validation;
- sanitization and bounded values;
- conversion back to the existing external representation.

Schemas expose a consistent boundary API:

- `cast(attrs)` returns `{:ok, struct}` or `{:error, changeset}`;
- `cast!(attrs)` returns the struct or raises `ArgumentError` at internal invariant boundaries;
- `dump(struct)` returns the existing atom- or string-keyed wire map expected by consumers.

Names may vary where an existing context already has equivalent public functions, but the behavior and error contract stay uniform.

## Polymorphic Payloads

Polymorphic records use one schema per semantic variant rather than a single nullable mega-schema.

`Ecrits.Agent.Dialog` remains the ordered transcript aggregate. Its `items` storage may remain an array of maps because Ecto does not provide native polymorphic embeds, but every item must first pass through an `Ecrits.Agent.Item.*` schema and be dumped back to the existing item map. No caller may append an unvalidated item map.

`Ecrits.Doc.Op` uses the same pattern. The `op` discriminator selects a verb-specific schema. Shared helpers may own common fields, but variants with different invariants remain separate. Arbitrary engine properties stay in an explicit `props` map and are not converted into atoms.

## Schema Families

### Agent

1. **`Ecrits.Agent.Item.*`** owns transcript item variants, including file activity and edit preview. This replaces the 50-plus-key registry in `Ecrits.Agent` and the second file-activity normalizer in `Ecrits.AcpAgent.Session`.
2. **`Ecrits.AcpAgent.Content.*`** owns text, image, audio, file, and document-reference blocks. File and media variants can reach four fields.
3. **`Ecrits.Agent.DurableState`** owns restored and handed-off agent state. `Ecrits.AcpAgent.Session` and `Ecrits.WorkspaceHandoff` must use the same schema instead of maintaining seven- and eight-field normalizers.
4. **`Ecrits.Agent.AdapterOptions`** owns the six persisted adapter options and rejects non-scalar persisted values through its changeset.

### Document and VFS

5. **`Ecrits.Doc.Op.*`** owns discriminated edit operations. Existing operation maps and browser/server dispatch remain wire-compatible.
6. **`Ecrits.Doc.Read.Nearby`** owns `before`, `after`, `row`, `column`, and `headers`. Browser readers receive its dumped result and do not normalize the options again.
7. **`Ecrits.Doc.ToolPayload.CompactDeck`** owns the four-field compact presentation summary emitted by the tool payload sanitizer.
8. **`Ecrits.Doc.EditLifecycleEvent`** owns the candidate, committed, rejected, and snapshot-ready VFS edit event. Both publication and LiveView consumption use the same schema.
9. **`Ecrits.Fuse.OpenDocs.Lifecycle`** owns committed bytes, dirty owner, generation, in-flight stage, and pending canonical stage.

### Workspace

10. **`Ecrits.Workspace.Foreground`** owns agent id, provider, owner session id, optional agent state, and optional runtime settings. Live session and durable handoff use the same semantic record.
11. **`Ecrits.Workspace.Session.Document`** becomes an embedded schema for path, ids, and scroll coordinates instead of a manually reconstructed plain struct.
12. **`Ecrits.Workspace.TurnOwner`** owns owner pid, owner monitor reference, task pid, and status.
13. **`Ecrits.Workspace.TurnFinalizationState`** owns the finalization map, order, queue, waiters, and active record.

Runtime-only values such as pids, references, functions, and test adapters use named `:any` virtual fields with explicit changeset validation. They are never passed to `Ecto.embedded_dump/2`. Durable schemas contain only serializable fields.

## Existing Compliant Boundaries

The surgery preserves and reuses existing Ecto-backed boundaries:

- `Ecrits.Agent.Dialog` for the dialog aggregate;
- `Ecrits.MarkdownEditorState` and its changeset-owned selection normalization;
- editor surface, canvas, toolbar, layout, search, and agent configuration schemas;
- existing `cast_embed` relationships.

The dialog schema is only partially compliant today because `items` is an unvalidated polymorphic map array. That gap belongs to `Ecrits.Agent.Item.*`, not a replacement dialog mega-schema.

## Error Handling

External inputs return `{:error, changeset}` or the context's existing translated error tuple. Internal restoration and hot-upgrade bridges may drop invalid legacy entries only where current behavior already does so; the failed changeset must remain inspectable in tests and logs.

The surgery must not silently preserve unknown fields in a fixed semantic record. Forward-compatible arbitrary maps are allowed only in fields explicitly declared for that purpose, such as engine `props`.

Changeset errors are translated at the existing public boundary. Wire consumers must not receive `%Ecto.Changeset{}` values.

## Migration Order

The work proceeds in three independently testable plans:

1. **Agent schemas:** item variants, content blocks, durable state, and adapter options.
2. **Document and VFS schemas:** operations, nearby options, tool summaries, edit lifecycle events, and OpenDocs lifecycle.
3. **Workspace schemas:** foreground, session document, turn owner, and turn finalization state.

Each plan first introduces schemas beside the current boundary, switches all producers and consumers, proves wire compatibility, then removes the manual normalizer. A boundary must never have two active normalization authorities after its migration.

## Testing

Every schema migration follows a red-green cycle:

1. Add a failing schema test for valid atom- and string-keyed input, defaults, invalid fields, and cross-field invariants.
2. Add a failing compatibility test asserting the dumped representation equals the current wire map.
3. Implement the schema and switch one boundary.
4. Run the focused context tests.
5. Run integration tests covering transcript persistence, ACP restoration, document editing, VFS lifecycle publication, LiveView consumption, workspace handoff, and hot-state repair as applicable.

Polymorphic dispatch tests must prove every advertised discriminator maps to exactly one schema and unknown discriminators fail without creating atoms.

Runtime schemas must prove pid/reference validation and must prove those virtual values never enter durable dumps.

The final verification is `mix precommit` plus focused live runtime checks for the Agent transcript and document-edit flow. UI navigation is required only where a migrated PubSub or canvas boundary changes data transport; visual/CSS validation is outside this surgery.

## Completion Criteria

The repository-wide surgery is complete only when:

- all 13 schema families are implemented and used by every audited producer and consumer;
- no affected manual field registry or greater-than-three-field normalizer remains authoritative;
- browser `nearby` duplicates are removed while browser-only geometry remains documented and local;
- existing wire formats are unchanged or an explicitly approved migration is provided;
- focused and integration tests pass;
- `mix precommit` passes;
- the Agent transcript and document-edit runtime flows are verified on the live application.
