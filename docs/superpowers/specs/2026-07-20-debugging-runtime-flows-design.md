# Debugging Runtime Flows

## Goal

Create a global, language-agnostic skill for debugger-led runtime investigation, with a separate BEAM/Tidewave reference.

## Workflow

Choose one session mode and keep it isolated:

- **Functional:** trace the real flow; verify values, lifecycle, and async/sync semantics; then preserve the finding as a standalone regression test. Treat every lifecycle bug as a semantic correctness bug.
- **Performance:** begin from a correct flow and repeat baseline, hypothesis, change, and remeasurement. For every candidate, ask **do we need these args?** and **can user sense this optimization?** Record the answers with every iteration and revert regressions.

Before tracing, form a layered abstraction of ordered, named layers. Each named layer is the agent's current semantic understanding of a responsibility and its boundaries, not a system identifier or established fact. Runtime evidence must update that abstraction and record whether it was confirmed, refuted, or revised.

## Records

Maintain three synchronized records:

1. **Layered abstraction paragraphs.** Give every layer a name, then explain the agent's current understanding of its responsibility, boundaries, and expected data, control, and lifecycle semantics in a short paragraph. State the supporting evidence and whether the hypothesis was confirmed, refuted, or revised. Preserve revisions in the paragraph rather than assigning layer IDs.
2. **Layered flow.** Render the flow as an ordered `Layer {function observations} -> Layer {function observations}` chain, never as a table. Aggregate each layer's observed function calls and returns inside its segment while preserving their order. Capture the complete reproducible arguments, sync/async behavior and execution identity, timing and latency, memory before/after/delta, returns, messages, state changes, effects, lifecycle evidence, expected invariant, actual outcome, evidence source, and status. At a lifecycle boundary, ask **where this get freed?** and incorporate the evidence-backed answer into the relevant function observation; the question is not a field. Redact secrets without removing fixture structure.
3. **Strategy table.** Accumulate every experiment and hypothesis in one table:

   | Layer/function | Experiment | Hypothesis | Observation | Conclusion/next |
   |---|---|---|---|---|

   Include baselines and successful, failed, distorting, and rejected experiments. Keep observations at function level while referencing the current layer. Explain why an attempt failed and how the next experiment improves it in `Conclusion/next`.

Layers organize the logs semantically; they never replace function-level detail.

Update the abstraction paragraphs as evidence arrives. The layered flow and strategy table must always reflect the current abstraction. When a layer is renamed, split, merged, or reinterpreted, rewrite its paragraph, reaggregate the flow, and update every strategy reference while preserving the original function-level evidence. Every finding and derived test must use the current layer names.

The functional regression test must be derived directly from the layered flow: recorded inputs become fixtures, while results, ordering, effects, lifecycle, and invariants become assertions.

## Files

- `SKILL.md`: portable workflow, mode boundary, record contracts, and completion criteria.
- `references/beam-tidewave.md`: Tidewave `project_eval`, `:dbg`, reductions, heaps, binaries, garbage collection, and LiveView debugging.

Install at `~/.codex/skills/debugging-runtime-flows`.

## Validation

Run matched unguided and guided scenarios for each mode. The guided functional run must produce abstraction paragraphs, an arrow-aggregated layered flow, the strategy table, use the exact lifecycle question as a prompt rather than a field, and extract a regression test. The guided performance run must keep every optimization experiment in the strategy table, ask the two exact optimization questions before each conclusion, and never use those questions as fields.
