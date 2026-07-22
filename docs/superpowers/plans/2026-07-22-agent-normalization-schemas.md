# Agent Normalization Schemas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Agent transcript, multimodal content, and durable-state manual normalization with per-semantic Ecto embedded schemas while preserving existing ACP and JSON wire shapes.

**Architecture:** `Ecrits.Agent.Item` and `Ecrits.AcpAgent.Content.Block` read only their discriminator, delegate to a bounded embedded schema, and dump the typed result back to the existing map contract. Durable session restoration and handoff share `Ecrits.Agent.DurableState` and nested `Ecrits.Agent.AdapterOptions` schemas.

**Tech Stack:** Elixir 1.20, Ecto 3.13 embedded schemas and changesets, ExUnit, Phoenix/OTP runtime tests.

## Global Constraints

- A normalizer or sanitizer handling more than three fields must use an Ecto schema.
- Preserve JSONL, ACP, transcript, and workspace-handoff wire shapes.
- Do not create atoms from input.
- Use bounded semantic schemas; do not create one nullable item mega-schema.
- Keep discriminator logic limited to `role` or `type` selection.
- Write and run a failing test before each production change.
- Stage only files named by the task.

---

### Task 1: Introduce the typed Agent item boundary

**Files:**
- Create: `lib/ecrits/agent/item.ex`
- Create: `lib/ecrits/agent/item/text.ex`
- Create: `lib/ecrits/agent/item/tool.ex`
- Create: `lib/ecrits/agent/item/file_activity.ex`
- Create: `lib/ecrits/agent/item/edit_preview.ex`
- Create: `test/ecrits/agent/item_test.exs`
- Modify: `lib/ecrits/agent.ex`
- Modify: `lib/ecrits/agent/dialog.ex`

**Interfaces:**
- Consumes: atom- or string-keyed transcript item maps.
- Produces: `Ecrits.Agent.Item.cast/1`, `cast!/1`, and `dump/1`; schemas validate one item at a time and Dialog continues storing the dumped runtime map.

- [ ] **Step 1: Write the failing dispatcher test**

```elixir
defmodule Ecrits.Agent.ItemTest do
  use ExUnit.Case, async: true

  alias Ecrits.Agent.Item
  alias Ecrits.Agent.Item.{EditPreview, FileActivity, Text, Tool}

  test "dispatches every transcript role to one bounded schema" do
    assert {:ok, %Text{role: :user, body: "hello"}} =
             Item.cast(%{"role" => "user", "body" => "hello"})

    assert {:ok, %Text{role: :thinking, segment: 2}} =
             Item.cast(%{role: :thinking, body: "inspect", segment: 2})

    assert {:ok, %Tool{name: "Bash", status: :completed}} =
             Item.cast(%{role: :tool, name: "Bash", status: "completed", input: "pwd"})

    assert {:ok, %FileActivity{file_operation_id: "file-1"}} =
             Item.cast(%{
               role: :file_activity,
               file_operation_id: "file-1",
               operation: "read_text_file",
               path: "contract.jsonl",
               status: :running
             })

    assert {:ok, %EditPreview{edit_id: "edit-1", document_id: "doc-1"}} =
             Item.cast(%{
               role: :edit_preview,
               turn_id: "turn-1",
               edit_id: "edit-1",
               document_id: "doc-1"
             })
  end

  test "rejects an unknown role without creating an atom" do
    assert {:error, %Ecto.Changeset{}} = Item.cast(%{"role" => "new-provider-role"})
  end

  test "dump preserves provider extension keys" do
    attrs = %{
      "role" => "tool",
      "name" => "Bash",
      "status" => "completed",
      "input" => "pwd",
      "provider_metadata" => %{"request_id" => "req-1"}
    }

    assert {:ok, item} = Item.cast(attrs)

    assert Item.dump(item) == %{
             role: :tool,
             name: "Bash",
             status: :completed,
             input: "pwd",
             "provider_metadata" => %{"request_id" => "req-1"}
           }
  end
end
```

- [ ] **Step 2: Run the item test and verify RED**

Run: `mise exec -- mix test test/ecrits/agent/item_test.exs`

Expected: compilation fails because the item dispatcher and four schemas do not exist.

- [ ] **Step 3: Implement the bounded schemas and discriminator**

Use `embedded_schema`, `Ecto.Enum` for `role` and `status`, and `field :extensions, :map, virtual: true, default: %{}`. Implement this dispatcher exactly:

```elixir
def cast(attrs) when is_map(attrs) do
  case fetch_role(attrs) do
    role when role in [:user, :agent, :thinking] -> Text.cast(attrs)
    :tool -> Tool.cast(attrs)
    :file_activity -> FileActivity.cast(attrs)
    :edit_preview -> EditPreview.cast(attrs)
    role -> {:error, invalid_role_changeset(role)}
  end
end

def cast(_attrs), do: {:error, invalid_role_changeset(nil)}

def cast!(attrs) do
  case cast(attrs) do
    {:ok, item} -> item
    {:error, changeset} -> raise ArgumentError, inspect(changeset.errors)
  end
end

def dump(%module{} = item)
    when module in [Text, Tool, FileActivity, EditPreview],
    do: module.dump(item)
```

Known field lists:

- `Text`: `role`, `status`, `body`, `reason`, `segment`, `turn_id`, `name`, `title`, `picks`.
- `Tool`: `role`, `status`, `body`, `reason`, `tool_call_id`, `name`, `title`, `kind`, `input`, `output`, `turn_id`.
- `FileActivity`: `role`, `status`, `body`, `reason`, `file_operation_id`, `tool_call_id`, `operation`, `name`, `kind`, `input`, `output`, `turn_id`, `path`, `relative_path`, `query`.
- `EditPreview`: every current key from `document_path` through `composed_tool_call_ids`, plus `role`, `status`, `body`, `reason`, and `turn_id`.

Unrecognized keys go into `extensions` without atomization and are merged by `dump/1`. Dumps omit nil fields. Required fields are: `role` for `Text`; `role` and `name` for `Tool`; `role`, `file_operation_id`, and `operation` for `FileActivity`; `role` for `EditPreview`.

- [ ] **Step 4: Route dialogs through `Ecrits.Agent.Item`**

Delete the item key/role/status registries and `normalize_item/1`. Make `Agent.new_dialog/1`, `append_dialog_item/2`, and `upsert_dialog_item/3` pass every item through `Item.cast!/1 |> Item.dump()` before storing it in `Dialog.items`. `Agent.load_dialog/1` performs the same validation after JSON decoding. This preserves `Dialog.items` as `{:array, :map}` while making schemas the only item normalization authority.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run: `mise exec -- mix test test/ecrits/agent/item_test.exs test/ecrits/agent_test.exs`

Expected: all tests pass and provider metadata still round-trips through JSON.

- [ ] **Step 6: Commit the item boundary**

```bash
git add lib/ecrits/agent.ex lib/ecrits/agent/dialog.ex lib/ecrits/agent/item.ex lib/ecrits/agent/item/text.ex lib/ecrits/agent/item/tool.ex lib/ecrits/agent/item/file_activity.ex lib/ecrits/agent/item/edit_preview.ex test/ecrits/agent/item_test.exs test/ecrits/agent_test.exs
git commit -m "Model agent transcript items with Ecto schemas"
```

### Task 2: Model multimodal ACP content blocks

**Files:**
- Create: `lib/ecrits/acp_agent/content/block.ex`
- Create: `lib/ecrits/acp_agent/content/text.ex`
- Create: `lib/ecrits/acp_agent/content/media.ex`
- Create: `lib/ecrits/acp_agent/content/file.ex`
- Create: `lib/ecrits/acp_agent/content/document_ref.ex`
- Modify: `lib/ecrits/acp_agent/content.ex`
- Modify: `test/ecrits/acp_agent/content_test.exs`

**Interfaces:**
- Consumes: existing atom- or string-keyed content block maps.
- Produces: typed block structs internally and the same canonical maps from `Content.normalize/1`.

- [ ] **Step 1: Add a failing schema-boundary test**

```elixir
test "file and media payloads are changeset validated" do
  attrs = %{
    type: :file,
    uri: "file:///tmp/x.pdf",
    name: "x.pdf",
    mime_type: "application/pdf"
  }

  assert {:ok, %Ecrits.AcpAgent.Content.File{}} =
           Ecrits.AcpAgent.Content.Block.cast(attrs)

  assert {:ok, [file]} = Content.normalize([attrs])

  assert file == %{
           type: :file,
           uri: "file:///tmp/x.pdf",
           name: "x.pdf",
           mime_type: "application/pdf"
         }

  assert {:error, {:invalid_block, :image}} =
           Content.normalize([%{type: :image, mime_type: "image/png"}])
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mise exec -- mix test test/ecrits/acp_agent/content_test.exs`

Expected: the new schema assertion fails until block casting is changeset-owned.

- [ ] **Step 3: Implement and route the block schemas**

`Block.cast/1` reads only `type`. `Media` uses `Ecto.Enum` values `[:image, :audio]` and validates either non-empty `data` plus `mime_type`, or non-empty `uri`. `File` casts `type`, `uri`, `name`, and `mime_type`; `DocumentRef` casts `type`, `document_id`, and `ref`; `Text` casts `type` and `text`.

```elixir
defp normalize_block(block) do
  case Block.cast(block) do
    {:ok, typed} -> {:ok, Block.dump(typed)}
    {:error, type, _changeset} -> {:error, {:invalid_block, type}}
    {:error, {:unknown_block_type, type}} -> {:error, {:unknown_block_type, type}}
  end
end
```

Delete `atomize_keys/1`, `do_normalize_block/2`, `normalize_media/2`, and `put_opt/3` after all variants use schemas.

- [ ] **Step 4: Run focused tests and commit**

Run: `mise exec -- mix test test/ecrits/acp_agent/content_test.exs test/ecrits/acp_agent/session_queue_test.exs`

Expected: all multimodal normalization, ACP mapping, and transcript tests pass.

```bash
git add lib/ecrits/acp_agent/content.ex lib/ecrits/acp_agent/content/block.ex lib/ecrits/acp_agent/content/text.ex lib/ecrits/acp_agent/content/media.ex lib/ecrits/acp_agent/content/file.ex lib/ecrits/acp_agent/content/document_ref.ex test/ecrits/acp_agent/content_test.exs
git commit -m "Validate ACP content with embedded schemas"
```

### Task 3: Share durable Agent state and adapter-option schemas

**Files:**
- Create: `lib/ecrits/agent/adapter_options.ex`
- Create: `lib/ecrits/agent/durable_state.ex`
- Create: `test/ecrits/agent/durable_state_test.exs`
- Modify: `lib/ecrits/acp_agent/session.ex`
- Modify: `lib/ecrits/workspace_handoff.ex`
- Modify: `test/ecrits/acp_agent/session_memory_test.exs`
- Modify: `test/ecrits/workspace/session_restart_test.exs`

**Interfaces:**
- Consumes: durable maps from ACP snapshots and workspace handoff JSON.
- Produces: `DurableState.cast/1`, `cast!/1`, and `dump/1`, with `AdapterOptions` as an embedded child.

- [ ] **Step 1: Write failing durable-state tests**

```elixir
defmodule Ecrits.Agent.DurableStateTest do
  use ExUnit.Case, async: true

  alias Ecrits.Agent.{AdapterOptions, DurableState}

  test "casts JSON state and dumps the same durable shape" do
    attrs = %{
      "id" => "agent-1",
      "instance_id" => "instance-1",
      "provider_session_id" => "provider-1",
      "thread_covers_from" => 2,
      "title" => "Contract",
      "title_user_edited?" => true,
      "transcript" => [],
      "adapter_opts" => %{"model" => "gpt-5", "reasoning_effort" => "high"}
    }

    assert {:ok, %DurableState{adapter_opts: %AdapterOptions{model: "gpt-5"}} = state} =
             DurableState.cast(attrs)

    assert DurableState.dump(state) == attrs
  end

  test "rejects non-scalar persisted adapter options" do
    assert {:error, %Ecto.Changeset{}} =
             DurableState.cast(%{
               id: "agent-1",
               transcript: [],
               adapter_opts: %{model: %{unexpected: true}}
             })
  end
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mise exec -- mix test test/ecrits/agent/durable_state_test.exs`

Expected: compilation fails because the durable schemas do not exist.

- [ ] **Step 3: Implement the two durable schemas**

`AdapterOptions` casts the persisted allowlist `model`, `reasoning_effort`, `sandbox`, `permission_mode`, `approval_policy`, and `access_control` as scalar fields; preserve the current six-key allowlist exactly and make `dump/1` omit nil fields. `DurableState` casts `id`, `instance_id`, `provider_session_id`, `thread_covers_from`, `title`, `title_user_edited?`, and `transcript`, then `cast_embed(:adapter_opts)`. Require non-empty `id`; default the count to `0`, edited flag to `false`, transcript to `[]`, and adapter options to an empty schema.

```elixir
def dump(%__MODULE__{} = state) do
  %{
    "id" => state.id,
    "instance_id" => state.instance_id,
    "provider_session_id" => state.provider_session_id,
    "thread_covers_from" => state.thread_covers_from,
    "title" => state.title,
    "title_user_edited?" => state.title_user_edited?,
    "transcript" => Enum.map(state.transcript, &Agent.dump_dialog/1),
    "adapter_opts" => AdapterOptions.dump(state.adapter_opts)
  }
end
```

- [ ] **Step 4: Replace duplicate durable normalizers**

In `Ecrits.AcpAgent.Session`, replace `normalize_durable_restore/2` with `DurableState.cast/1` plus the expected-id check. In `Ecrits.WorkspaceHandoff`, replace `normalize_agent_state/1` and `normalize_adapter_opts/1` with the same schema. Preserve current invalid-legacy behavior at each public boundary.

- [ ] **Step 5: Run durable integration tests**

Run: `mise exec -- mix test test/ecrits/agent/durable_state_test.exs test/ecrits/acp_agent/session_memory_test.exs test/ecrits/workspace/session_restart_test.exs`

Expected: provider-session reuse, restart restoration, and handoff tests pass.

- [ ] **Step 6: Commit durable schemas**

```bash
git add lib/ecrits/agent/adapter_options.ex lib/ecrits/agent/durable_state.ex lib/ecrits/acp_agent/session.ex lib/ecrits/workspace_handoff.ex test/ecrits/agent/durable_state_test.exs test/ecrits/acp_agent/session_memory_test.exs test/ecrits/workspace/session_restart_test.exs
git commit -m "Share durable agent state schemas"
```

### Task 4: Remove duplicate file-activity normalization and verify Agent flow

**Files:**
- Modify: `lib/ecrits/acp_agent/session.ex`
- Modify: `test/ecrits/acp_agent/session_queue_test.exs`
- Modify: `test/ecrits/agent_test.exs`
- Create: `test/ecrits/normalization_schema_boundary_test.exs`

**Interfaces:**
- Consumes: validated file-activity maps dumped by `Ecrits.Agent.Item.FileActivity` from Task 1.
- Produces: one authoritative file-activity cast path and unchanged transcript ordering/deduplication.

- [ ] **Step 1: Add a failing architecture assertion**

```elixir
defmodule Ecrits.NormalizationSchemaBoundaryTest do
  use ExUnit.Case, async: true

  test "ACP Session does not own a second file-activity normalizer" do
    source = File.read!("lib/ecrits/acp_agent/session.ex")
    refute source =~ "defp normalize_file_activity_item("
  end
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mise exec -- mix test test/ecrits/normalization_schema_boundary_test.exs`

Expected: the assertion fails while Session still defines `normalize_file_activity_item/1`.

- [ ] **Step 3: Delete the Session-owned normalizer**

Delete `normalize_file_activity_item/1`. Route event construction through `Item.cast!/1 |> Item.dump()`. Keep deduplication and terminal-status merge as semantic operations over validated maps and rename `normalize_file_activity_items/1` to `merge_file_activity_items/1` so it is not a second casting authority.

- [ ] **Step 4: Run the Agent regression set**

Run: `mise exec -- mix test test/ecrits/normalization_schema_boundary_test.exs test/ecrits/agent_test.exs test/ecrits/agent/item_test.exs test/ecrits/acp_agent/content_test.exs test/ecrits/agent/durable_state_test.exs test/ecrits/acp_agent/session_queue_test.exs test/ecrits/acp_agent/session_memory_test.exs test/ecrits/workspace/session_restart_test.exs`

Expected: all tests pass with typed runtime items and unchanged durable JSON.

- [ ] **Step 5: Commit the authority cleanup**

```bash
git add lib/ecrits/acp_agent/session.ex test/ecrits/acp_agent/session_queue_test.exs test/ecrits/agent_test.exs test/ecrits/normalization_schema_boundary_test.exs
git commit -m "Use one Agent item normalization boundary"
```
