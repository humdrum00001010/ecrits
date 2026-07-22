# Workspace Normalization Schemas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace workspace foreground, session-document, turn-owner, and turn-finalization manual record normalization with Ecto schemas without changing workspace attachment, handoff, or process-lifecycle behavior.

**Architecture:** Durable fields use ordinary embedded-schema fields and nested Agent durable state. Runtime-only pids, references, waiters, settings, and functions use `:any, virtual: true` plus explicit changeset validation. The workspace GenServer stores typed records and collection helpers only index, merge, or prune those records.

**Tech Stack:** Elixir 1.20, Ecto 3.13, OTP GenServer/monitor semantics, ExUnit, Phoenix PubSub.

## Global Constraints

- A normalizer or sanitizer handling more than three fields must use an Ecto schema.
- Preserve workspace attachment, restart, hot-state repair, handoff JSON, and PubSub behavior.
- Runtime pids/references must remain virtual and must never enter durable dumps.
- Do not replace monitor-based synchronization with sleeps or `Process.alive?/1` assertions in tests.
- Use `start_supervised!/1`, `Process.monitor/1`, and `:sys.get_state/1` where applicable.
- Write and run a failing test before each production change.

---

### Task 1: Convert workspace session documents to an embedded schema

**Files:**
- Modify: `lib/ecrits/workspace/session/document.ex`
- Modify: `lib/ecrits/workspace/session.ex`
- Modify: `test/ecrits/workspace/session_document_state_test.exs`

**Interfaces:**
- Consumes: atom maps, string maps, or existing `%Document{}` values.
- Produces: `Document.cast/1`, `cast!/1`, and `%Document{path, id, pool_document_id, scroll_top, scroll_left}`.

- [ ] **Step 1: Add failing schema tests**

```elixir
test "session document casts string keys and scroll defaults" do
  assert {:ok,
          %Document{
            path: "drafts/reference.docx",
            id: "doc-id",
            pool_document_id: "pool-id",
            scroll_top: 0,
            scroll_left: 0
          }} =
           Document.cast(%{
             "path" => "drafts/reference.docx",
             "id" => "doc-id",
             "pool_document_id" => "pool-id"
           })
end

test "session document rejects unsafe paths and negative scroll" do
  assert {:error, %Ecto.Changeset{}} =
           Document.cast(%{path: "../outside.docx", scroll_top: -1})
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mise exec -- mix test test/ecrits/workspace/session_document_state_test.exs`

Expected: compilation fails because `Document.cast/1` does not exist.

- [ ] **Step 3: Implement the schema and route Session**

Add `use Ecto.Schema`, an `embedded_schema` with the existing five fields, and a changeset that requires a safe relative `path`, defaults scroll coordinates to `0`, rounds non-negative floats before casting, and rejects negative values. Replace `session_document/2` field-by-field reconstruction with `Document.cast/1`; merge existing values into incoming attrs before casting. Rename `normalize_session_documents/1` to `cast_session_documents/1` and make it only enumerate entries and call `Document.cast/1`.

- [ ] **Step 4: Run tests and commit**

Run: `mise exec -- mix test test/ecrits/workspace/session_document_state_test.exs test/ecrits/workspace/session_restart_test.exs`

Expected: document tab, active document, scroll, unsafe path, and restart tests pass.

```bash
git add lib/ecrits/workspace/session/document.ex lib/ecrits/workspace/session.ex test/ecrits/workspace/session_document_state_test.exs test/ecrits/workspace/session_restart_test.exs
git commit -m "Model workspace session documents with Ecto"
```

### Task 2: Share a typed foreground record between Session and handoff

**Files:**
- Create: `lib/ecrits/workspace/foreground.ex`
- Create: `test/ecrits/workspace/foreground_test.exs`
- Modify: `lib/ecrits/workspace/session.ex`
- Modify: `lib/ecrits/workspace_handoff.ex`
- Modify: `test/ecrits/workspace/session_orchestration_test.exs`
- Modify: `test/ecrits/workspace/session_restart_test.exs`

**Interfaces:**
- Consumes: foreground metadata from live Session state and durable handoff JSON.
- Produces: `Foreground.cast/1`, `cast!/1`, `dump/1`, and `dump_durable/1`; nested agent state uses `Ecrits.Agent.DurableState` from the Agent plan.

- [ ] **Step 1: Write the failing foreground test**

```elixir
defmodule Ecrits.Workspace.ForegroundTest do
  use ExUnit.Case, async: true

  alias Ecrits.Workspace.Foreground

  test "casts durable fields and keeps settings runtime-only" do
    attrs = %{
      agent_id: "agent-1",
      provider: "codex",
      owner_session_id: "browser-1",
      settings: [access_control: "ask"]
    }

    assert {:ok, %Foreground{settings: [access_control: "ask"]} = foreground} =
             Foreground.cast(attrs)

    refute Map.has_key?(Foreground.dump_durable(foreground), "settings")
  end

  test "requires stable agent and owner ids" do
    assert {:error, %Ecto.Changeset{}} = Foreground.cast(%{provider: "codex"})
  end
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mise exec -- mix test test/ecrits/workspace/foreground_test.exs`

Expected: compilation fails because `Foreground` does not exist.

- [ ] **Step 3: Implement the foreground schema**

Fields are `agent_id`, `provider`, `owner_session_id`, `embeds_one :agent_state, Ecrits.Agent.DurableState`, and `field :settings, :any, virtual: true`. Require non-empty agent and owner ids; allow a nil provider; validate settings as a keyword list. `dump/1` retains runtime settings, while `dump_durable/1` emits only JSON-safe fields.

- [ ] **Step 4: Replace both foreground normalizers**

In Session, replace `normalize_foregrounds/1` with a collection caster that calls `Foreground.cast/1`; active foreground and LiveView-index pruning remain collection helpers. In WorkspaceHandoff, replace `normalize_foreground/2` with the same schema and check that nested durable state id equals `agent_id`.

- [ ] **Step 5: Run tests and commit**

Run: `mise exec -- mix test test/ecrits/workspace/foreground_test.exs test/ecrits/workspace/session_orchestration_test.exs test/ecrits/workspace/session_restart_test.exs`

Expected: foreground reattachment, settings retention, and durable restart tests pass.

```bash
git add lib/ecrits/workspace/foreground.ex lib/ecrits/workspace/session.ex lib/ecrits/workspace_handoff.ex test/ecrits/workspace/foreground_test.exs test/ecrits/workspace/session_orchestration_test.exs test/ecrits/workspace/session_restart_test.exs
git commit -m "Share workspace foreground schema"
```

### Task 3: Model exact Agent turn ownership

**Files:**
- Create: `lib/ecrits/workspace/turn_owner.ex`
- Create: `test/ecrits/workspace/turn_owner_test.exs`
- Modify: `lib/ecrits/workspace/session.ex`
- Modify: `test/ecrits/workspace/session_orchestration_test.exs`

**Interfaces:**
- Consumes: runtime owner maps keyed by `{agent_id, instance_id, turn_id}`.
- Produces: `%TurnOwner{owner_pid, owner_ref, task_pid, status}` with all process values virtual.

- [ ] **Step 1: Write the failing runtime schema test**

```elixir
defmodule Ecrits.Workspace.TurnOwnerTest do
  use ExUnit.Case, async: true

  alias Ecrits.Workspace.TurnOwner

  test "validates pids, monitor reference, and status" do
    owner_ref = Process.monitor(self())

    assert {:ok,
            %TurnOwner{
              owner_pid: owner_pid,
              owner_ref: ^owner_ref,
              task_pid: task_pid,
              status: :active
            }} =
             TurnOwner.cast(%{
               owner_pid: self(),
               owner_ref: owner_ref,
               task_pid: self(),
               status: :active
             })

    assert owner_pid == self()
    assert task_pid == self()
    Process.demonitor(owner_ref, [:flush])
  end
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mise exec -- mix test test/ecrits/workspace/turn_owner_test.exs`

Expected: compilation fails because `TurnOwner` does not exist.

- [ ] **Step 3: Implement and route the runtime schema**

Use virtual `:any` fields for the three process values and `Ecto.Enum` statuses `[:active, :awaiting_task_down, :crashed]`. Changeset validators require two pids and one reference. Store `%TurnOwner{}` values in `state.agent_turn_owners`; replace `normalize_agent_turn_owners/1` with a collection caster/pruner that accepts only valid structs.

- [ ] **Step 4: Run tests and commit**

Run: `mise exec -- mix test test/ecrits/workspace/turn_owner_test.exs test/ecrits/workspace/session_orchestration_test.exs`

Expected: exact ownership, owner/task DOWN, crash, and release behavior pass.

```bash
git add lib/ecrits/workspace/turn_owner.ex lib/ecrits/workspace/session.ex test/ecrits/workspace/turn_owner_test.exs test/ecrits/workspace/session_orchestration_test.exs
git commit -m "Model workspace turn ownership with Ecto"
```

### Task 4: Model turn-finalization subsystem state

**Files:**
- Create: `lib/ecrits/workspace/turn_finalization_state.ex`
- Create: `lib/ecrits/workspace/turn_finalization_state/active.ex`
- Create: `test/ecrits/workspace/turn_finalization_state_test.exs`
- Modify: `lib/ecrits/workspace/session.ex`
- Modify: `test/ecrits/workspace/session_file_events_test.exs`
- Modify: `test/ecrits/workspace/session_orchestration_test.exs`

**Interfaces:**
- Consumes: the five-field finalization subsystem extracted from Session state.
- Produces: `%TurnFinalizationState{finalizations, order, queue, waiters, active}` and `%TurnFinalizationState.Active{key, pid, ref, attempts}`.

- [ ] **Step 1: Write the failing subsystem test**

```elixir
defmodule Ecrits.Workspace.TurnFinalizationStateTest do
  use ExUnit.Case, async: true

  alias Ecrits.Workspace.TurnFinalizationState
  alias Ecrits.Workspace.TurnFinalizationState.Active

  test "casts coherent queue state and a runtime active record" do
    key = {"agent-1", "instance-1", "turn-1"}
    ref = Process.monitor(self())

    assert {:ok,
            %TurnFinalizationState{
              queue: [^key],
              active: %Active{key: ^key, pid: pid, ref: ^ref, attempts: 1}
            }} =
             TurnFinalizationState.cast(%{
               finalizations: %{key => %{status: :queued, attempts: 0}},
               order: [],
               queue: [key],
               waiters: %{},
               active: %{key: key, pid: self(), ref: ref, attempts: 1}
             })

    assert pid == self()
    Process.demonitor(ref, [:flush])
  end

  test "drops queue keys missing from finalizations" do
    key = {"agent-1", "instance-1", "turn-1"}
    assert {:ok, %TurnFinalizationState{queue: []}} =
             TurnFinalizationState.cast(%{finalizations: %{}, queue: [key]})
  end
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mise exec -- mix test test/ecrits/workspace/turn_finalization_state_test.exs`

Expected: compilation fails because the finalization schemas do not exist.

- [ ] **Step 3: Implement the subsystem schemas**

`TurnFinalizationState` uses virtual `:any` fields for finalizations, order, queue, and waiters, plus `embeds_one :active, Active`. Its changeset defaults empty collections, accepts only `{binary, binary, binary}` keys, prunes order/queue/waiters missing from `finalizations`, deduplicates order and queue, and validates waiter pids. `Active` uses virtual `:any` fields for key, pid, and ref plus non-negative integer attempts; it validates the key, pid, and reference.

- [ ] **Step 4: Store one typed subsystem in Session**

Replace the five top-level `turn_finalization_*` fields with one `turn_finalization_state` field in newly initialized state. Add compatibility accessors for hot state only while migrating existing processes. Replace `normalize_turn_finalizations/1` and `normalize_turn_finalization_active/1` with `TurnFinalizationState.cast!/1`; update enqueue/start/retry/complete helpers to use struct fields.

- [ ] **Step 5: Run finalization tests and commit**

Run: `mise exec -- mix test test/ecrits/workspace/turn_finalization_state_test.exs test/ecrits/workspace/session_file_events_test.exs test/ecrits/workspace/session_orchestration_test.exs`

Expected: queue serialization, retry, completion acknowledgement, task DOWN, and bounded history tests pass.

```bash
git add lib/ecrits/workspace/turn_finalization_state.ex lib/ecrits/workspace/turn_finalization_state/active.ex lib/ecrits/workspace/session.ex test/ecrits/workspace/turn_finalization_state_test.exs test/ecrits/workspace/session_file_events_test.exs test/ecrits/workspace/session_orchestration_test.exs
git commit -m "Model workspace turn finalization state"
```

### Task 5: Verify workspace authority and repository policy

**Files:**
- Modify only if a focused test proves a regression: files already named in Tasks 1-4.
- Modify: `test/ecrits/normalization_schema_boundary_test.exs`

**Interfaces:**
- Consumes: all four workspace schema families and the Agent durable-state schema.
- Produces: one schema-owned normalization authority for each audited workspace record.

- [ ] **Step 1: Record and prove old workspace authorities are gone**

Extend `normalization_schema_boundary_test.exs` with:

```elixir
test "workspace records have one schema authority" do
  sources =
    ["lib/ecrits/workspace/session.ex", "lib/ecrits/workspace_handoff.ex"]
    |> Enum.map_join("\n", &File.read!/1)

  for name <- [
        "normalize_agent_state",
        "normalize_adapter_opts",
        "normalize_foreground",
        "normalize_session_documents",
        "normalize_agent_turn_owners",
        "normalize_turn_finalizations",
        "normalize_turn_finalization_active"
      ] do
    refute sources =~ "defp #{name}("
  end
end
```

Run:

```bash
rg -n 'defp normalize_agent_state|defp normalize_adapter_opts|defp normalize_foreground\(|defp normalize_foregrounds\(|defp normalize_session_documents|defp normalize_agent_turn_owners|defp normalize_turn_finalizations|defp normalize_turn_finalization_active' lib/ecrits
```

Expected: no authoritative definitions remain. Collection helpers must be named for their actual index/prune/merge behavior.

- [ ] **Step 2: Run the full workspace regression set**

Run: `mise exec -- mix test test/ecrits/workspace test/ecrits/agent test/ecrits/acp_agent/session_memory_test.exs test/ecrits/acp_agent/session_queue_test.exs`

Expected: zero failures.

- [ ] **Step 3: Run repository verification**

Run: `mise exec -- mix precommit`

Expected: compilation with warnings as errors, unused-dependency check, formatting, and the full `test test` suite all pass.

- [ ] **Step 4: Verify live workspace restoration**

Use Tidewave `project_eval` to inspect one attached workspace Session and confirm its document, foreground, owner, and finalization values are typed structs. Refresh the shared browser tab with `browser_eval`, reattach the rail, and confirm the existing transcript and active document restore without a LiveView crash.

- [ ] **Step 5: Commit only verified regression fixes**

Run `git status --short`. If tests required fixes, stage only the exact changed files already named in Tasks 1-4 and commit them with:

```bash
git add lib/ecrits/workspace/session/document.ex lib/ecrits/workspace/session.ex lib/ecrits/workspace/foreground.ex lib/ecrits/workspace_handoff.ex lib/ecrits/workspace/turn_owner.ex lib/ecrits/workspace/turn_finalization_state.ex lib/ecrits/workspace/turn_finalization_state/active.ex test/ecrits/normalization_schema_boundary_test.exs test/ecrits/workspace/session_document_state_test.exs test/ecrits/workspace/session_restart_test.exs test/ecrits/workspace/foreground_test.exs test/ecrits/workspace/session_orchestration_test.exs test/ecrits/workspace/turn_owner_test.exs test/ecrits/workspace/turn_finalization_state_test.exs test/ecrits/workspace/session_file_events_test.exs
git commit -m "Verify workspace schema boundaries"
```

If no files changed, do not create an empty commit.
