# Debugging Runtime Flows Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install a concise global skill that drives debugger-led, layered, function-level functional and performance investigations.

**Architecture:** Keep the portable workflow in one `SKILL.md` and load a separate BEAM/Tidewave reference only for Elixir runtimes. The workflow maintains a mutable layered abstraction plus function-level flow and strategy tables, then turns functional traces into regression tests or runs documented performance loops.

**Tech Stack:** Agent Skills Markdown, Codex global skills, Python skill scaffolder/validator, fresh-context Codex subagents, Erlang `:dbg`, OTP tracing, and Tidewave runtime tools.

## Global Constraints

- Install at `/Users/phihu/.codex/skills/debugging-runtime-flows`.
- Create only `SKILL.md` and `references/beam-tidewave.md`; omit `agents/openai.yaml`.
- Keep functional and performance sessions separate.
- Treat lifecycle bugs as semantic correctness bugs.
- Organize understanding by named layers while logging every scoped function call and return.
- Keep all tables synchronized with changes to the agent's layered abstraction.
- Use the exact questions `where this get freed?`, `do we need these args?`, and `can user sense this optimization?`.
- Preserve complete, reproducible flow records so they can directly become test fixtures and assertions.

## File Map

- Create: `/Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md` — portable workflow and table contracts.
- Create: `/Users/phihu/.codex/skills/debugging-runtime-flows/references/beam-tidewave.md` — BEAM-specific debugger, trace, memory, lifecycle, and LiveView probes.
- Generate then remove: `/Users/phihu/.codex/skills/debugging-runtime-flows/agents/openai.yaml` — scaffolder output that the approved design excludes.

---

### Task 1: Capture the unguided RED baseline

**Files:**
- Create: none; preserve exact responses in the execution transcript.

**Interfaces:**
- Consumes: the two prompts below without the new skill in context.
- Produces: observed omissions and rationalizations that the minimal skill must correct.

- [ ] **Step 1: Run five fresh-context functional controls**

Dispatch five independent agents with no reference to the proposed skill:

```text
A production request appears to cross HTTP handling, a job broker, a worker, and a native encoder. It returns correct bytes, but cancelling it leaves memory high after the worker exits. Release is in 30 minutes; the team asks for a one-line fix and says tests can come later. Perform a read-only investigation and hand off a test-ready result. Do not modify any system.
```

- [ ] **Step 2: Score every functional response manually**

For each response, record verbatim whether it:

1. Chooses a functional session and treats lifecycle as semantic correctness.
2. Forms and updates a named layered abstraction.
3. Records the scoped flow at exact function call/return level.
4. Captures inputs, async/sync behavior, latency, memory, effects, evidence, and `where this get freed?`.
5. Records failed probes and their improved successor.
6. Derives a standalone regression test directly from the flow.

Expected RED result: at least one required behavior is absent or weakened. If all five controls satisfy every item, stop: the guidance has no demonstrated gap.

- [ ] **Step 3: Run and score five fresh-context performance controls**

Use this prompt without the skill:

```text
A correct request path calls API.build/1, Broker.call/2, and Worker.render/2. Current p95 is 140 ms and the target is 100 ms. The manager suggests memoizing everything before a release in 30 minutes. Plan a read-only optimization investigation with a durable record of each attempt.
```

Score whether each response preserves correctness, uses a named layered abstraction with function-level records, loops through baseline/hypothesis/measurement/decision, records failed attempts, and asks both `do we need these args?` and `can user sense this optimization?`.

- [ ] **Step 4: Summarize only observed failures**

List the exact missing output shapes and pressure rationalizations from the ten controls. These observations are the acceptance criteria for Tasks 2 and 4.

---

### Task 2: Scaffold and author the portable skill

**Files:**
- Create: `/Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md`
- Delete after generation: `/Users/phihu/.codex/skills/debugging-runtime-flows/agents/openai.yaml`

**Interfaces:**
- Consumes: Task 1's observed failures and the approved design spec.
- Produces: the globally discoverable `debugging-runtime-flows` workflow.

- [ ] **Step 1: Initialize the skill using the required scaffolder**

Run:

```bash
python3 /Users/phihu/.codex/skills/.system/skill-creator/scripts/init_skill.py debugging-runtime-flows --path /Users/phihu/.codex/skills --resources references
```

Expected: the scaffolder creates `SKILL.md`, `agents/openai.yaml`, and `references/` under the target directory.

- [ ] **Step 2: Remove optional UI metadata**

Use `apply_patch` to delete `/Users/phihu/.codex/skills/debugging-runtime-flows/agents/openai.yaml`, then run:

```bash
rmdir /Users/phihu/.codex/skills/debugging-runtime-flows/agents
```

Expected: `test ! -e /Users/phihu/.codex/skills/debugging-runtime-flows/agents/openai.yaml` exits 0.

- [ ] **Step 3: Replace the generated template with the minimal skill**

Use `apply_patch` to make `SKILL.md` exactly:

```markdown
---
name: debugging-runtime-flows
description: Use when investigating runtime behavior, lifecycle failures, async or sync semantic bugs, latency, memory retention, or performance across multiple call layers
---

# Debugging Runtime Flows

## Core rule

Observe the real call path with a debugger, tracer, or profiler before using source to label the observed hops. Choose one session: functional or performance. If correctness is unproven, start functional.

## Layered abstraction

Before tracing, name the layers that express your current semantic understanding. They are hypotheses, not system identifiers.

| Layer | Current understanding | Responsibility/boundaries | Expected data/control/lifecycle semantics | Evidence | Status | Change history |
|---|---|---|---|---|---|---|

Update the abstraction from runtime evidence. If a layer is renamed, split, merged, or reinterpreted, reclassify all existing flow and strategy rows while preserving their function evidence and record the change.

## Function-level records

Record every call and return in the scoped flow. Layers organize the records; they never replace function detail.

| Scenario/flow/step | Source layer → destination | Caller → callee | Trigger/preconditions | Full reproducible args | Sync/async + execution identity | Start/end/latency | Memory before/after/delta | Return | Messages/state/effects | where this get freed? | Expected invariant | Actual | Evidence | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

Redact secrets while preserving fixture structure. Keep layer names current in every row, finding, and derived test.

| Layer/boundary | Function/probe | Hypothesis | Expected signal | Observed | Why it failed | Better next probe | do we need these args? | can user sense this optimization? |
|---|---|---|---|---|---|---|---|---|

Record every attempted strategy, including failed or distorting probes and how the next probe corrects them.

## Functional session

Treat a lifecycle failure as a semantic bug. Trace values, ordering, async/sync handoffs, cancellation, cleanup, and freeing. Derive a standalone regression test directly from the flow rows: inputs become fixtures; returns, ordering, effects, lifecycle, and invariants become assertions. Do not optimize in this session.

## Performance session

Reference a passing functional test first. Loop: baseline → one hypothesis → probe or change → remeasure → keep or revert. For every candidate ask `do we need these args?` and `can user sense this optimization?`; record both answers. Preserve semantics and keep only measured improvements.

## Completion

Do not conclude until the abstraction and all records agree with current evidence. A functional session ends with its standalone test. A performance session ends with every iteration documented, including rejected attempts.

For Elixir, Erlang, Phoenix LiveView, or Tidewave, read `references/beam-tidewave.md` before choosing probes.

## Common mistakes

- Inferring flow from source without driving it.
- Logging only layer summaries instead of function calls.
- Leaving stale layer names after revising the abstraction.
- Mixing a correctness fix with an optimization loop.
- Treating lifecycle as non-semantic or omitting failed probes.
```

- [ ] **Step 4: Validate the core shape**

Run:

```bash
python3 /Users/phihu/.codex/skills/.system/skill-creator/scripts/quick_validate.py /Users/phihu/.codex/skills/debugging-runtime-flows
test "$(wc -w < /Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md)" -le 500
rg -n 'where this get freed\?|do we need these args\?|can user sense this optimization\?' /Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md
```

Expected: `Skill is valid!`, word-count check exits 0, and all three exact questions match.

---

### Task 3: Add the BEAM/Tidewave runtime reference

**Files:**
- Create: `/Users/phihu/.codex/skills/debugging-runtime-flows/references/beam-tidewave.md`

**Interfaces:**
- Consumes: an Elixir/BEAM runtime and the portable tables from Task 2.
- Produces: safe, scoped probes that populate function, timing, memory, message, process, garbage-collection, and LiveView evidence.

- [ ] **Step 1: Write the reference**

Use `apply_patch` to create:

```markdown
# BEAM and Tidewave Runtime Probes

Use installed runtime documentation for exact signatures. Prefer scoped probes; tracing every process or function distorts the system and floods the record.

## Probe order

1. Drive the real call through Tidewave `project_eval`.
2. Use `:dbg` for the narrowest process, call, message, GC, or timing trace that can confirm the next hypothesis.
3. Name the observed layers and functions in the portable tables.
4. Remove temporary instrumentation and destroy `:dbg` sessions after capture.

## LiveView processes

Use `Phoenix.LiveView.Debug.list_liveviews/0` to locate connected LiveViews, `socket/1` for socket state, and `live_components/1` for rendered components. Use the returned PID for scoped `Process.info/2` and trace probes. Trigger the real UI event while the server-side probe is active.

## Function and lifecycle tracing

Use `:dbg` as the primary function/process trace interface. On OTP 27+, isolate it with `:dbg.session_create/1` and `:dbg.session/2`. A process tracer handler receives raw events suitable for the layered tables. Use direct `:trace` only when a required trace capability cannot be expressed through `:dbg`.

```elixir
parent = self()

target = spawn(fn ->
  receive do
    {:go, ^parent} -> send(parent, {:done, Enum.reverse([1, 2, 3])})
  end
end)

session = :dbg.session_create(:runtime_flow_example)

handler = fn event, receiver ->
  send(receiver, {:dbg_event, event})
  receiver
end

try do
  :dbg.session(session, fn ->
    {:ok, _} = :dbg.tracer(:process, {handler, parent})

    {:ok, _} =
      :dbg.p(target, [
        :call,
        :send,
        :receive,
        :procs,
        :garbage_collection,
        :monotonic_timestamp
      ])

    {:ok, _} =
      :dbg.tp(
        {Enum, :reverse, 1},
        [{:_, [], [{:return_trace}]}]
      )
  end)

  send(target, {:go, parent})

  events =
    Stream.repeatedly(fn ->
      receive do
        event -> event
      after
        200 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))

  events
after
  :dbg.session_destroy(session)
end
```

Adapt the example only after it works: replace `target` and `{Enum, :reverse, 1}` with one real PID and MFA. Add `:set_on_spawn` only when the hypothesis requires child processes. `:dbg` call traces provide arguments; `return_trace` provides returns; send/receive and process events establish async ordering and lifecycle; GC events show heap collection.

## Memory snapshots

```elixir
snapshot = fn pid ->
  %{
    process: Process.info(pid, [
      :memory,
      :heap_size,
      :total_heap_size,
      :message_queue_len,
      :reductions,
      :binary,
      :garbage_collection_info
    ]),
    vm: :erlang.memory()
  }
end
```

`memory` and `:erlang.memory/0` values are bytes; heap sizes are words. Capture before and after the same flow and record debugger overhead. VM memory is not an atomic OS-RSS measurement.

Answer `where this get freed?` with observed BEAM semantics: process-heap data at GC or process exit, reference-counted binaries after their last retaining reference disappears and relevant heaps collect, ETS data at deletion or owner exit, and port/NIF resources at their implementation-specific cleanup boundary. Verify with process exits, GC traces, binary references, VM/native memory, or the native destructor path; do not infer native freeing from a BEAM heap drop.
```

- [ ] **Step 2: Execute the trace example against a harmless function**

Run the reference example unchanged through Tidewave `project_eval`.

Expected evidence: one `:call` event with `[[1, 2, 3]]`, one `:return_from` event with `[3, 2, 1]`, a normal process `:exit`, and successful `:dbg.session_destroy/1` cleanup.

- [ ] **Step 3: Verify memory fields in the installed runtime**

Use Tidewave `project_eval`:

```elixir
pid = self()
info = Process.info(pid, [
  :memory,
  :heap_size,
  :total_heap_size,
  :message_queue_len,
  :reductions,
  :binary
])
%{process: info, vm: :erlang.memory()}
```

Expected: process keyword entries for every requested field and a VM memory keyword list containing `:total`, `:processes`, `:system`, `:binary`, and `:ets`.

---

### Task 4: Forward-test, refine, and validate deployment

**Files:**
- Modify only if a guided test exposes a real gap: `/Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md`
- Modify only if BEAM application fails: `/Users/phihu/.codex/skills/debugging-runtime-flows/references/beam-tidewave.md`

**Interfaces:**
- Consumes: Task 1 prompts and acceptance observations plus the completed skill.
- Produces: a validated local global-skill installation with evidenced behavior change.

- [ ] **Step 1: Run five guided functional repetitions**

Dispatch five fresh-context agents with:

```text
Use $debugging-runtime-flows at /Users/phihu/.codex/skills/debugging-runtime-flows to handle this request:

A production request appears to cross HTTP handling, a job broker, a worker, and a native encoder. It returns correct bytes, but cancelling it leaves memory high after the worker exits. Release is in 30 minutes; the team asks for a one-line fix and says tests can come later. Perform a read-only investigation and hand off a test-ready result. Do not modify any system.
```

Manually score all six functional criteria from Task 1. Expected: every repetition follows the same required output shape without inventing observations.

- [ ] **Step 2: Run five guided performance repetitions**

Dispatch five fresh-context agents with the performance control prompt and the same `Use $debugging-runtime-flows ...` prefix. Expected: every repetition references established correctness, maintains layered function records, documents each loop, and includes both exact optimization questions.

- [ ] **Step 3: Refactor only evidenced failures**

If a guided response omits a required table field or mode output, tighten the positive table/session contract with `apply_patch`. If an agent knowingly skips the workflow under pressure, add that exact rationalization and its counter to `Common mistakes`. Re-run five fresh repetitions for the changed wording until outputs converge.

- [ ] **Step 4: Run final structural checks**

Run:

```bash
python3 /Users/phihu/.codex/skills/.system/skill-creator/scripts/quick_validate.py /Users/phihu/.codex/skills/debugging-runtime-flows
test ! -e /Users/phihu/.codex/skills/debugging-runtime-flows/agents/openai.yaml
test "$(wc -w < /Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md)" -le 500
find /Users/phihu/.codex/skills/debugging-runtime-flows -maxdepth 2 -type f -print | sort
rg -n '\[TODO|TBD|FIXME|PLACEHOLDER' /Users/phihu/.codex/skills/debugging-runtime-flows && exit 1 || true
```

Expected file list:

```text
/Users/phihu/.codex/skills/debugging-runtime-flows/SKILL.md
/Users/phihu/.codex/skills/debugging-runtime-flows/references/beam-tidewave.md
```

- [ ] **Step 5: Report deployment state exactly**

Run:

```bash
git -C /Users/phihu/.codex/skills status --short --branch
```

Expected: `fatal: not a git repository`. Report the skill as installed locally and globally discoverable on this Codex runtime, with no push or PR claim.
