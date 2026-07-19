# Debugging Runtime Flows

## Goal

Create a global, language-agnostic skill for debugger-led runtime investigation, with a separate BEAM/Tidewave reference.

## Workflow

Choose one session mode and keep it isolated:

- **Functional:** trace the real flow; verify values, lifecycle, and async/sync semantics; then preserve the finding as a standalone regression test.
- **Performance:** begin from a correct flow and repeat baseline, hypothesis, change, and remeasurement. Record every iteration and revert regressions.

At lifecycle boundaries, ask exactly:

> where this get freed?

Do not expand this into additional lifecycle questions.

## Records

Maintain two concise tables:

1. A flow table containing hop, arguments, result/effect, sync/async behavior, latency, memory, lifecycle, and evidence.
2. A strategy log containing the attempted probe, expected signal, observed result, why it failed, and how to improve the next attempt.

## Files

- `SKILL.md`: portable workflow, mode boundary, table contracts, and completion criteria.
- `references/beam-tidewave.md`: `dbg`, Tidewave `project_eval`, process tracing, reductions, heaps, binaries, garbage collection, and LiveView debugging.
- `agents/openai.yaml`: discovery metadata.

Install at `~/.codex/skills/debugging-runtime-flows`.

## Validation

Run matched unguided and guided scenarios for each mode. The guided functional run must trace a flow, emit both tables, use the exact lifecycle question, and extract a regression test. The guided performance run must keep every optimization attempt in a documented measurement loop.
