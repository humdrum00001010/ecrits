# Debugging Runtime Flow Records Revision Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the debugger skill's table-heavy records with abstraction paragraphs, an arrow-aggregated layered flow, and one cumulative strategy table, then prove the new shape with fresh functional and performance runs.

**Architecture:** Keep the language-agnostic workflow in `SKILL.md` and the BEAM/Tidewave probes in one conditional reference. The abstraction is prose, the flow is a named-layer `->` chain containing function evidence, and the strategy table is the only table. Forward tests exercise both session modes before structural validation.

**Tech Stack:** Agent Skills Markdown, Codex global skills, Python skill validator, fresh-context agent runs, Erlang `:dbg`, and Tidewave runtime tools.

## Global Constraints

- Keep functional and performance sessions separate.
- Treat lifecycle failures as semantic bugs.
- Use debugger or runtime-trace evidence before source labels the flow.
- Abstraction is named paragraphs, never a table.
- Flow is `Layer {function observations} -> Layer {function observations}`, never a table.
- The strategy table has exactly `Layer/function | Experiment | Hypothesis | Observation | Conclusion/next`.
- Ask `where this get freed?`, `do we need these args?`, and `can user sense this optimization?` as workflow prompts, never as fields.
- Record every strategy experiment, including baselines, failures, distortion, rejection, and success.
- Use Erlang `:dbg`, not Elixir `dbg/1`, in the BEAM reference.
- Do not create `agents/openai.yaml`.
- The global skill directory is not a Git repository; report it as a local-only installation.

## File Map

- Modify: `/Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md` — portable record shapes and mode workflows.
- Modify: `/Users/phihu/.codex/skills/debugging-runtime-flows/references/beam-tidewave.md` — terminology aligned to the new records; probe behavior remains unchanged.
- Test: fresh-context functional and performance agent outputs plus structural shell checks.

---

### Task 1: Establish the revised-format RED baseline

**Files:**
- Read: `/Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md`

**Interfaces:**
- Consumes: the currently installed table-based skill.
- Produces: raw failures showing abstraction or flow rendered as tables, or questions rendered as fields.

- [ ] **Step 1: Run five fresh functional samples against the current skill**

Use this request without disclosing the intended output:

```text
Use the installed debugging-runtime-flows skill. An async export reports success, but a native buffer appears retained after cancellation. No trace has been captured. Produce the functional investigation record and pending test contract without inventing evidence.
```

- [ ] **Step 2: Verify RED**

Read every output. Expected failure: at least one response renders the abstraction or flow as a table, or places an exact lifecycle/optimization question in a table header. Record the raw failure shape in Task Board task `#482`.

- [ ] **Step 3: Run five fresh performance samples against the current skill**

```text
Use the installed debugging-runtime-flows skill. A passing functional test covers API.build/1 -> Broker.call/2 -> Worker.render/2. End-to-end p95 is 140 ms and the target is 100 ms; no per-hop trace exists. Produce the initial performance investigation record without changing code.
```

- [ ] **Step 4: Verify RED**

Expected failure: the old strategy table exposes the optimization questions as fields, or abstraction/flow remain tables.

---

### Task 2: Implement the approved record shapes

**Files:**
- Modify: `/Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md`
- Modify: `/Users/phihu/.codex/skills/debugging-runtime-flows/references/beam-tidewave.md`

**Interfaces:**
- Consumes: runtime observations and named semantic layer hypotheses.
- Produces: abstraction paragraphs, an evidence-only layered flow chain, one cumulative strategy table, and session-specific test or performance records.

- [ ] **Step 1: Replace `SKILL.md` with the minimal approved workflow**

```markdown
---
name: debugging-runtime-flows
description: Use when investigating runtime behavior, lifecycle failures, async or sync semantic bugs, latency, memory retention, or performance across multiple call layers
---

# Debugging Runtime Flows

## Rule

Drive the real call with a debugger, tracer, or profiler first; use source only to name observed hops. Choose one session: functional or performance. If correctness is unproven, start functional.

A symptom proves only itself. Until runtime evidence attributes it, conclude `unattributed`; do not diagnose, fix, or invent calls, arguments, ownership, free sites, or outcomes. Missing evidence stays `unknown` or `unobserved`, and its required probe goes into the strategy table.

Every session maintains synchronized abstraction paragraphs, a layered flow, and the strategy table.

## Abstraction

Give each semantic layer a name and a short paragraph explaining the current hypothesis about its responsibility, boundaries, and data, control, and lifecycle semantics. Cite the supporting evidence and say when the hypothesis is confirmed, refuted, or revised. These names express the agent's understanding, not system IDs.

When evidence renames, splits, merges, or reinterprets a layer, revise its paragraph, reaggregate the flow, and update every strategy reference without losing function evidence.

## Layered flow

Render observed flow as `Layer A {function observations} -> Layer B {function observations}`. Never use a flow table. Aggregate each layer's calls and returns in execution order. For every observed function preserve reproducible arguments, trigger, sync/async execution identity, timing and latency, memory before/after/delta, return, messages, state, effects, lifecycle evidence, invariant, actual outcome, evidence, and status. Redact secrets without changing fixture structure.

Before tracing, render only `Unattributed {supplied facts; unsupported details: unknown}`; never invent arrows or plausible APIs.

At lifecycle boundaries ask exactly: `where this get freed?` Incorporate the evidence-backed answer into the relevant function observation, never into a field.

## Strategy

| Layer/function | Experiment | Hypothesis | Observation | Conclusion/next |
|---|---|---|---|---|

Append every baseline, probe, change, failure, distortion, rejection, and success. Keep function detail and current layer names. Explain failed experiments and the corrective next probe.

## Functional session

Lifecycle failures are semantic bugs. Trace values, order, async/sync handoffs, cancellation, cleanup, and freeing. After attribution, derive a standalone regression test: traced inputs become fixtures; returns, ordering, effects, lifecycle, and invariants become assertions. Before attribution, emit only a pending contract with unknown fixtures and calls. Never optimize here.

## Performance session

Reference a passing functional test. Loop: baseline -> one hypothesis -> probe or change -> remeasure -> keep or revert. Before concluding each experiment ask exactly `do we need these args?` and `can user sense this optimization?`; incorporate both answers into the conclusion prose, never table fields. Preserve semantics and keep only measured improvements.

For Elixir, Erlang, Phoenix LiveView, or Tidewave, read `references/beam-tidewave.md` before choosing probes.
```

- [ ] **Step 2: Align the BEAM reference terminology**

Replace `portable tables` with `portable records` and describe raw `:dbg` events as inputs to the abstraction, layered flow, and strategy table. Do not change the tested `:dbg` example or add `dbg/1`.

- [ ] **Step 3: Run structural validation**

```bash
python3 /Users/phihu/.codex/skills/.system/skill-creator/scripts/quick_validate.py /Users/phihu/.codex/skills/debugging-runtime-flows
test "$(wc -w < /Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md)" -le 500
```

Expected: `Skill is valid!`; both commands exit 0.

---

### Task 3: Forward-test and refine the record contract

**Files:**
- Modify only if an evidenced gap appears: `/Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md`

**Interfaces:**
- Consumes: the two Task 1 scenarios.
- Produces: convergent functional and performance records matching the approved form.

- [ ] **Step 1: Run five fresh guided functional samples**

Each response must contain named abstraction paragraphs, one `->` layered flow or the single pre-trace `Unattributed {...}` node, exactly one strategy table with the approved five headers, and a derived test or pending contract. It must not invent evidence or render abstraction/flow as tables.

- [ ] **Step 2: Run five fresh guided performance samples**

Each response must cite a passing functional test, maintain abstraction paragraphs and the layered flow, accumulate every experiment in the strategy table, run the measured loop, and ask both optimization questions outside the header.

- [ ] **Step 3: Read every sample and refine only evidenced gaps**

For wrong output shape, tighten the positive output recipe. For invented evidence, strengthen the pre-trace `Unattributed` contract. Re-run five fresh samples after every wording change.

---

### Task 4: Final validation and handoff

**Files:**
- Verify: `/Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md`
- Verify: `/Users/phihu/.codex/skills/debugging-runtime-flows/references/beam-tidewave.md`

**Interfaces:**
- Produces: evidence that the global skill is valid, concise, has the approved record shapes, and remains local-only.

- [ ] **Step 1: Run final structural checks**

```bash
python3 /Users/phihu/.codex/skills/.system/skill-creator/scripts/quick_validate.py /Users/phihu/.codex/skills/debugging-runtime-flows
test "$(wc -w < /Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md)" -le 500
test ! -e /Users/phihu/.codex/skills/debugging-runtime-flows/agents/openai.yaml
rg -F 'Layer A {function observations} -> Layer B {function observations}' /Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md
rg -F '| Layer/function | Experiment | Hypothesis | Observation | Conclusion/next |' /Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md
if rg '^\|.*(where this get freed\?|do we need these args\?|can user sense this optimization\?).*\|' /Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md; then exit 1; fi
if rg -F '| Scenario/flow/step |' /Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md; then exit 1; fi
find /Users/phihu/.codex/skills/debugging-runtime-flows -maxdepth 2 -type f -print | sort
```

Expected: validation succeeds; the questions occur only in prose; no flow-table header appears; only `SKILL.md` and `references/beam-tidewave.md` are listed.

- [ ] **Step 2: Re-run the harmless BEAM `:dbg` example**

Use Tidewave `project_eval` with the reference example. Expected: correlated call, return, process-exit, and garbage-collection events; the isolated `:dbg` session is destroyed afterward.

- [ ] **Step 3: Report exact installation state**

Report the global skill as installed and tested locally. Do not claim a push or PR: `/Users/phihu/.codex/skills` is not a Git repository.
