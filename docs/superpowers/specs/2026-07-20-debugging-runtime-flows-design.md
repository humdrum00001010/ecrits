# Debugging Runtime Flows

## Goal

Create a global, language-agnostic skill for debugger-led runtime investigation, with a separate BEAM/Tidewave reference.

## Workflow

Choose one session mode and keep it isolated:

- **Functional:** trace the real flow; verify values, lifecycle, and async/sync semantics; then preserve the finding as a standalone regression test.
- **Performance:** begin from a correct flow and repeat baseline, hypothesis, change, and remeasurement. Record every iteration and revert regressions.

Before tracing, model the flow as ordered, named layers. Each named layer is the agent's current semantic understanding of a responsibility and its boundaries, not a system identifier or established fact. Runtime evidence must update that understanding and record whether it was confirmed, refuted, or revised.

## Records

Maintain three concise tables:

1. A named-layer model containing each layer's name, the agent's current understanding, proposed responsibility and boundaries, expected data/control/lifecycle semantics, evidence, status, and change history.
2. A complete layered-flow table that is the canonical source for a later test set. State every hop as behavior within one named layer or a transfer across two named layer boundaries. Record scenario and flow IDs, order, source and destination layer names, trigger and preconditions, boundary, full reproducible inputs and arguments, sync/async behavior, execution identity, timestamps and latency, memory before/after/delta, result, messages and state changes, side effects, lifecycle/free point, expected invariant, actual outcome, evidence source, and pass/fail status. Redact secrets without removing the structure needed to reproduce the flow.
3. A layer-strategy log. Scope every attempted probe to a named layer or named layer boundary and record the expected signal, observed result, why it failed, and how the next attempt should improve that layer's investigation.

Update the named-layer model as evidence arrives. Every flow row, strategy entry, finding, and derived test must reference the applicable layer names.

The lifecycle/free-point field answers: **where this get freed?**

The functional regression test must be derived directly from the flow rows: recorded inputs become fixtures, while results, ordering, effects, lifecycle, and invariants become assertions.

## Files

- `SKILL.md`: portable workflow, mode boundary, table contracts, and completion criteria.
- `references/beam-tidewave.md`: `dbg`, Tidewave `project_eval`, process tracing, reductions, heaps, binaries, garbage collection, and LiveView debugging.

Install at `~/.codex/skills/debugging-runtime-flows`.

## Validation

Run matched unguided and guided scenarios for each mode. The guided functional run must trace a flow, emit both tables, use the exact lifecycle question, and extract a regression test. The guided performance run must keep every optimization attempt in a documented measurement loop.
