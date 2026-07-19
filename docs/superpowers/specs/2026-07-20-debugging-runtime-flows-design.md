# Debugging Runtime Flows

## Goal

Create a global, language-agnostic skill for debugger-led runtime investigation, with a separate BEAM/Tidewave reference.

## Workflow

Choose one session mode and keep it isolated:

- **Functional:** trace the real flow; verify values, lifecycle, and async/sync semantics; then preserve the finding as a standalone regression test. Treat every lifecycle bug as a semantic correctness bug.
- **Performance:** begin from a correct flow and repeat baseline, hypothesis, change, and remeasurement. For every candidate, ask **do we need these args?** and **can user sense this optimization?** Record the answers with every iteration and revert regressions.

Before tracing, form a layered abstraction of ordered, named layers. Each named layer is the agent's current semantic understanding of a responsibility and its boundaries, not a system identifier or established fact. Runtime evidence must update that abstraction and record whether it was confirmed, refuted, or revised.

## Records

Maintain three concise tables:

1. A layered abstraction containing each layer's name, the agent's current understanding, proposed responsibility and boundaries, expected data/control/lifecycle semantics, evidence, status, and change history.
2. A complete layered-flow table that is the canonical source for a later test set. Record every observed function-level call and return while referencing the named source and destination layers. Include scenario and flow IDs, order, exact caller and callee functions, source and destination layer names, trigger and preconditions, boundary, full reproducible inputs and arguments, sync/async behavior, execution identity, timestamps and latency, memory before/after/delta, result, messages and state changes, side effects, **where this get freed?**, expected invariant, actual outcome, evidence source, and pass/fail status. Redact secrets without removing the structure needed to reproduce the flow.
3. A layer-strategy log. Record every attempted probe at function level, including the exact function or call boundary, while referring to its named layer or layer boundary. Include the expected signal, observed result, why it failed, and how the next attempt should improve that layer's investigation.

Layers organize the logs semantically; they never replace function-level detail.

Update the layered abstraction as evidence arrives. The layered-flow table and layer-strategy log must always reflect the agent's current abstraction. When a layer is renamed, split, merged, or reinterpreted, update the layer references and boundary classifications in every existing row while preserving its function-level evidence; record the reclassification in the abstraction's change history. Every finding and derived test must also reference the current layer names.

The functional regression test must be derived directly from the flow rows: recorded inputs become fixtures, while results, ordering, effects, lifecycle, and invariants become assertions.

## Files

- `SKILL.md`: portable workflow, mode boundary, table contracts, and completion criteria.
- `references/beam-tidewave.md`: Tidewave `project_eval`, `:dbg`, reductions, heaps, binaries, garbage collection, and LiveView debugging.

Install at `~/.codex/skills/debugging-runtime-flows`.

## Validation

Run matched unguided and guided scenarios for each mode. The guided functional run must trace a flow, emit all three tables, use the exact lifecycle question, and extract a regression test. The guided performance run must keep every optimization attempt in a documented measurement loop.
