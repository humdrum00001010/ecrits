# Contract Studio SPEC.md

Status: Draft v0.5 (Document-primary)  
Primary target: Elixir / Phoenix / LiveView  
Core model: **Action in → Change out → Store is truth → Session coordinates → Agent reasons → Studio renders**

---

## Revision history

- 2026-05-16: Add Context Reservoir as the persistent left-side projection of contract context (brief / shared fields / open questions / related docs / sources / evidence / recent changes / readiness). All reservoir edits go through Action → Runtime → Session → Engine → Store. Reservoir is projection, not truth. Studio layout: Left = Context Reservoir, Center = Document Canvas, Right = Agent Rail.
- 2026-05-15: Pivot from Matter-primary to Document-primary product framing. Document is now the primary user-facing object; Matter remains the internal context container. Routes reorganized to document-first; matter_id becomes optional on most Actions. UI label "Matter" → "Workspace" (or hidden). DocumentSession is the per-Document live coordinator.

---

## Required framing

- User-facing primary object: Document
- Internal context scope: Matter
- Main UI surface: Contract Studio
- Durable edit unit: Change
- Soft semantic layer: Mark
- Live coordinator: DocumentSession

### Role definitions

**Document is the primary user-facing product object.** A Document is the contract draft/file the user is actively creating, importing, editing, converting, reviewing, revoking, exporting, and sharing with a lawyer. Examples: NDA, Service Agreement, Lease, Statement of Work, Converted NDA variant, Lawyer-review draft.

**Matter is the internal context container around one contract-related situation.** A Matter is not the main UX object. It groups background context that may be shared across related documents. Matter may contain: pre-document discussion / Matter Brief, reusable party facts, source uploads, related contract variants, Slack context, law/evidence snapshots, lawyer packet context, migration lineage, related documents.

The user should not need to understand or create a Matter manually. If a user uploads or creates a Document without an existing Matter, the backend may auto-create a hidden Matter.

The product hierarchy is: **Document → Studio → optional Matter context.** It is NOT: Matter → Documents → Studio.

User-facing label policy: 워크스페이스 (Workspace) or hidden; do NOT show "사건" (Matter) in casual UI unless the audience is law-firm operators.

---

## 0. Stress Test Result

I found one design-flipping blocker:

**If v1 requires active-active multi-region writes to the same contract document, this design is not enough.**

Active-active writing would require CRDT-like semantics or a substantially different conflict model.  
This spec therefore assumes:

**Each document has exactly one write-home region at a time.**

Read/render can be distributed. Writes route to the document’s home region.

Under that assumption, no hard blocker remains. Dirty crashes, LiveView restarts, duplicate session processes, agent streaming, revokes, type conversion, field migration, and MCP routing are handled by the design below.

---

## 1. Design Principle

The product is built around the **Document** as the primary user-facing actor. The user creates, imports, edits, reviews, revokes, converts, exports, and shares Documents. **Matter** is an internal context container — a scope grouping facts, sources, and related documents that may be shared across Documents in the same situation. Most users never need to think about Matter; the backend may auto-create a hidden Matter when a Document is created.

The system is not primarily a "matters module," "documents module," "migration module," "marks module," or "agent module."

The real abstraction is:

```text
Studio
  user-facing surface

Runtime
  routes actions

Engine
  compiles/applies actions to document state

Session
  transient commit coordinator

Lease
  fencing guard for duplicate sessions

Store
  durable truth

Agent
  semantic interpreter

Gateway
  external ingress: MCP, Slack, route refs

IO
  providers: Upstage, OpenAI, law MCP, export renderers
```

The product rule:

```text
Action in.
Change out.
Store is truth.
Session is reconstructable.
LiveView is disposable.
Agent decides meaning.
Backend enforces mechanics.
```

---

## 2. Non-Negotiable Invariants

1. A LiveView process MUST NOT own document truth.
2. A BEAM PID MUST NOT be exposed to OpenAI, MCP, Slack, or the browser as routing authority.
3. A Session process MAY disappear, duplicate, or become stale.
4. Store + ChangeLog are durable truth.
5. Only the current lease holder may commit.
6. Every commit carries revision and idempotency semantics.
7. PubSub is notification only.
8. Missed PubSub messages are repaired by `sync_since`.
9. Agent streams are UI-progress only until they emit a final Action.
10. User/agent edits apply immediately but are revokable.
11. Revoke appends a new Change; it never deletes history.
12. Type selection is metadata. Type conversion is a migration workflow.
13. Large type conversion should create a new document variant by default.
14. Field migration moves reusable facts with lineage instead of emitting massive text diffs.
15. Soft meaning belongs in Marks, not in a giant hard legal ontology.

---

## 3. Core Types

These are coarse aliases for specs. They do not replace Ecto schemas.

```elixir
defmodule Contract.Types do
  @type id :: Ecto.UUID.t()
  @type ctx :: Contract.Context.t()
  @type result(value) :: {:ok, value} | {:error, term()}

  @type user_id :: id()
  @type tenant_id :: id()
  # matter_id is OPTIONAL / CONTEXTUAL.
  # Document is the primary user-facing object; Matter is an internal
  # context container. Most Actions carry only document_id. matter_id is
  # only required for grouping, shared-field, or pre-document actions.
  @type matter_id :: id()
  @type document_id :: id()
  @type artifact_id :: id()
  @type change_id :: id()
  @type mark_id :: id()
  @type field_id :: id()
  @type migration_id :: id()
  @type agent_run_id :: id()
  @type export_id :: id()
  @type route_ref_token :: String.t()

  @type revision :: non_neg_integer()
  @type contract_type_key :: String.t()
  @type idempotency_key :: String.t()

  @type params :: %{optional(String.t()) => term()}
  @type attrs :: %{optional(atom() | String.t()) => term()}
  @type opts :: keyword()
  @type upload :: Phoenix.LiveView.UploadEntry.t()
  @type socket :: Phoenix.LiveView.Socket.t()
end
```

---

## 4. Routes

The normal product UI is LiveView-only. No browser `/api` is needed for regular user actions.

Routes are **document-first**. The Matter route is **optional and secondary**, used only for workspace/lawyer surfaces — do NOT make `/matters/:matter_id/...` the primary product path. User-facing label policy: 워크스페이스 (Workspace) or hidden; do NOT show "사건" (Matter) in casual UI unless the audience is law-firm operators.

```elixir
defmodule ContractWeb.Router do
  use ContractWeb, :router

  scope "/", ContractWeb do
    pipe_through [:browser, :authenticated]

    # Primary product surface — document-first.
    live "/studio", StudioLive
    live "/documents/:document_id", StudioLive
    live "/documents/:document_id/review", StudioLive

    # Optional / secondary — internal "Workspace" (Matter) surface.
    # User-facing label: 워크스페이스 (Workspace) or hidden; do NOT show
    # "사건" in casual UI unless the audience is law-firm operators.
    live "/workspaces/:matter_id", StudioLive

    get "/exports/:export_id/download", ExportDownloadController, :show
  end

  scope "/mcp", ContractWeb.MCP do
    pipe_through [:mcp]
    forward "/", MCPPlug
  end

  scope "/slack", ContractWeb do
    pipe_through [:slack]

    post "/events", SlackController, :events
    post "/actions", SlackController, :actions
    post "/commands", SlackController, :commands
  end
end
```

`/mcp`, `/slack`, OAuth callbacks, webhooks, and export downloads are external ingress/egress.  
The browser product flow is the Studio LiveView, opened around a Document.

---

## 5. Action

`Action` is the one intent shape.

Users, agents, Slack, MCP, import jobs, export jobs, and system jobs all normalize into Actions.

Most Actions are **document-first**: rename document, update metadata, set contract type, edit content, add mark, agent change, revoke change, request export, start type conversion, create converted variant. `matter_id` is **optional / contextual** — only required when the Action is about grouping, shared fields across documents, or pre-document context (e.g. Matter Brief discussion before any Document exists). All other Actions carry `document_id` as the primary scope.

```elixir
defmodule Contract.Action do
  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @primary_key false

  embedded_schema do
    field :kind, Ecto.Enum,
      values: [
        :open_document,
        :create_document,
        :upload_document,
        :duplicate_document,
        :archive_document,
        :restore_document,

        :rename_document,
        :update_metadata,
        :set_contract_type,

        :edit_document,
        :add_mark,
        :update_mark,

        :start_type_conversion,
        :set_field_migration_strategy,
        :create_converted_variant,

        :chat_message,
        :agent_change,
        :revoke_change,
        :resolve_revoke,

        :request_export
      ]

    # matter_id is OPTIONAL / CONTEXTUAL.
    # Only required for grouping, shared-field, or pre-document Actions.
    # All document-scoped Actions carry document_id; matter_id may be nil.
    field :matter_id, :binary_id
    field :document_id, :binary_id
    field :change_id, :binary_id
    field :agent_run_id, :binary_id

    field :actor_type, Ecto.Enum, values: [:user, :agent, :lawyer, :slack, :system]
    field :actor_id, :binary_id

    field :base_revision, :integer
    field :idempotency_key, :string

    field :payload, :map, default: %{}
    field :message, :string
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(action, attrs)
end
```

Examples:

```text
rename document       → Action(:rename_document)
edit clause           → Action(:edit_document)
user chat             → Action(:chat_message)
agent edit            → Action(:agent_change)
undo                  → Action(:revoke_change)
convert to NDA        → Action(:start_type_conversion)
create NDA variant    → Action(:create_converted_variant)
```

Context Reservoir edits become normal Actions. Editing Party A becomes `Action(:edit_document)` or `Action(:update_metadata)`. Answering an open question becomes `Action(:add_mark)` or `Action(:update_mark)`. Changing jurisdiction becomes `Action(:update_metadata)`. Opening a related source document becomes `Action(:open_document)`. Marking evidence as relevant becomes `Action(:add_mark)`. The Context Reservoir does NOT create a separate context-mutation system.

---

## 6. Change

`Change` is the durable reversible result of an Action.

```elixir
defmodule Contract.Change do
  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "changes" do
    field :matter_id, :binary_id
    field :document_id, :binary_id
    field :artifact_id, :binary_id

    field :action_kind, :string

    field :actor_type, Ecto.Enum, values: [:user, :agent, :lawyer, :slack, :system]
    field :actor_id, :binary_id

    field :base_revision, :integer
    field :applied_revision, :integer
    field :idempotency_key, :string

    field :ops, {:array, :map}, default: []
    field :marks, {:array, :map}, default: []
    field :message, :string

    field :affected_refs, {:array, :map}, default: []
    field :preimage, :map
    field :inverse_ops, {:array, :map}, default: []

    field :status, Ecto.Enum,
      values: [:active, :revoked, :partially_revoked, :superseded],
      default: :active

    timestamps()
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(change, attrs)
end
```

Every meaningful mutation becomes a Change:

```text
title rename
metadata edit
contract type selection
paragraph edit
agent rewrite
field migration
variant creation
mark addition
revoke
```

---

## 7. Operation and Mark

`Operation` is mechanical.  
`Mark` is soft meaning.

```elixir
defmodule Contract.Operation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @primary_key false

  embedded_schema do
    field :op, Ecto.Enum,
      values: [
        :create_node,
        :delete_node,
        :move_node,
        :replace_content,
        :set_field,
        :set_attr,
        :bind_ref,
        :unbind_ref,
        :create_projection,
        :add_mark,
        :update_mark
      ]

    field :target_type, Ecto.Enum,
      values: [:artifact, :document, :node, :field, :mark, :projection]

    field :target_id, :binary_id
    field :args, :map, default: %{}
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(operation, attrs)
end
```

```elixir
defmodule Contract.MarkInput do
  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @primary_key false

  embedded_schema do
    field :target_type, Ecto.Enum,
      values: [:artifact, :document, :node, :field, :change, :op, :evidence, :projection]

    field :target_id, :binary_id
    field :intent, Ecto.Enum, values: [:ask, :explain, :flag, :label, :link]
    field :text, :string
    field :confidence, Ecto.Enum, values: [:low, :medium, :high, :confirmed]
    field :source, Ecto.Enum, values: [:user, :agent, :lawyer, :slack, :law_mcp, :system]
    field :data, :map, default: %{}
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(mark, attrs)
end
```

The backend MUST NOT bake a large legal ontology into hard node types.  
The agent may attach soft marks such as:

```text
label: "payment clause"
flag: "legal review suggested"
ask: "Which payment deadline do you prefer?"
explain: "Changed because user asked for stricter payment."
link: evidence_id
```

---

## 8. Studio

`Contract.Studio` is the product façade for the one big LiveView. It is **document-first**: `Studio.load/2` should prefer Document context (via `document_id`) over Matter context. Matter context is loaded only when needed (workspace surface, shared-field context, lawyer packet). If `params` carry both, Document wins as the primary scope.

```elixir
defmodule Contract.Studio do
  alias Contract.Types, as: T

  @spec load(T.ctx(), T.params()) :: T.result(Contract.Studio.State.t())
  def load(ctx, params)

  @spec reload(T.ctx(), Contract.Studio.State.t()) :: T.result(Contract.Studio.State.t())
  def reload(ctx, state)

  @spec select_document(T.ctx(), Contract.Studio.State.t(), T.document_id()) ::
          T.result(Contract.Studio.State.t())
  def select_document(ctx, state, document_id)

  @spec submit(T.ctx(), Contract.Studio.State.t(), Contract.Action.t()) ::
          T.result(Contract.Studio.State.t())
  def submit(ctx, state, action)

  @spec sync(T.ctx(), Contract.Studio.State.t(), T.revision()) ::
          T.result(Contract.Studio.State.t())
  def sync(ctx, state, from_revision)

  @spec subscribe(T.ctx(), Contract.Studio.State.t()) :: T.result(:ok)
  def subscribe(ctx, state)

  @spec load_context_reservoir(Contract.Types.ctx(), Contract.Studio.State.t()) ::
          Contract.Types.result(Contract.Studio.ContextReservoir.t())
  def load_context_reservoir(ctx, state)

  @spec refresh_context_reservoir(Contract.Types.ctx(), Contract.Studio.State.t()) ::
          Contract.Types.result(Contract.Studio.State.t())
  def refresh_context_reservoir(ctx, state)

  @spec submit_context_action(
          Contract.Types.ctx(),
          Contract.Studio.State.t(),
          Contract.Action.t()
        ) :: Contract.Types.result(Contract.Studio.State.t())
  def submit_context_action(ctx, state, action)
end
```

`Studio` handles product-level orchestration:

```text
load studio (document-first; matter context optional)
select/create/import document
submit action
sync after crash/reconnect
subscribe to document updates
load/refresh context reservoir
submit context-reservoir edits as Actions
```

---

## 9. Studio State

LiveView state is not DB state.

```elixir
defmodule Contract.Studio.State do
  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @primary_key false

  embedded_schema do
    field :matter_id, :binary_id
    field :selected_document_id, :binary_id
    field :selected_node_id, :binary_id

    field :last_seen_revision, :integer

    field :chat_open?, :boolean, default: true
    field :document_picker_open?, :boolean, default: false
    field :metadata_panel_open?, :boolean, default: false
    field :migration_panel_open?, :boolean, default: false
    field :upload_panel_open?, :boolean, default: false

    field :agent_run_id, :binary_id

    field :mode, Ecto.Enum,
      values: [:no_document, :briefing, :editing, :reviewing]

    embeds_one :context_reservoir, Contract.Studio.ContextReservoir
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(state, attrs)
end
```

The Context Reservoir is the persistent left-side projection of contract context (see §10a). It is UI/projection state, not durable truth, so it is an embedded schema on Studio.State.

```elixir
defmodule Contract.Studio.ContextReservoir do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :brief, :map, default: %{}
    field :shared_fields, {:array, :map}, default: []
    field :open_questions, {:array, :map}, default: []
    field :related_documents, {:array, :map}, default: []
    field :sources, {:array, :map}, default: []
    field :evidence, {:array, :map}, default: []
    field :recent_changes, {:array, :map}, default: []
    field :recent_revokes, {:array, :map}, default: []
    field :readiness, :map, default: %{}
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(reservoir, attrs)
end
```

---

## 10. StudioLive

Disposable UI process.

It does not own document truth.

Studio layout:

```text
Left   = Context Reservoir (live projection of contract context)
Center = Current Document (Canvas — Briefing/Editor/Review)
Right  = Agent Chat / Actions
Top    = Document title, type, metadata
```

The left rail is the Context Reservoir (see §10a), not a raw document list or document picker. Documents appear in the reservoir only as contextual related documents with human labels. The center rail is the Document Canvas. The right rail is the Agent Chat / Actions.

StudioLive should open around a **Document** when possible. When mounted from `/documents/:document_id` or `/documents/:document_id/review`, the LiveView assigns that Document as the selected scope. When mounted from `/studio` (no document) or from `/workspaces/:matter_id` (workspace surface) with no selected Document, the always-open agent chat MUST ask the user whether to:

1. upload an existing contract,
2. open a recent document,
3. create a blank contract,
4. draft from discussion (pre-document Matter Brief),
5. create a variant from another document.

This 5-option prompt is the only required behavior for the no-document state; the rest of the UI surface (chat rail, recent list, upload panel) remains the same disposable LiveView projection.

```elixir
defmodule ContractWeb.StudioLive do
  use ContractWeb, :live_view

  alias Contract.Types, as: T

  @spec mount(T.params(), map(), T.socket()) :: {:ok, T.socket()}
  def mount(params, session, socket)

  @spec handle_event(String.t(), T.params(), T.socket()) :: {:noreply, T.socket()}
  def handle_event(event, params, socket)

  @spec handle_info(term(), T.socket()) :: {:noreply, T.socket()}
  def handle_info(message, socket)

  @spec dispatch(T.socket(), Contract.Action.t()) :: T.result(T.socket())
  def dispatch(socket, action)

  @spec sync(T.socket(), T.revision()) :: T.result(T.socket())
  def sync(socket, from_revision)

  @spec render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns)
end
```

`handle_event/3` converts UI events into Actions.

Examples:

```text
"rename_document"       → Action(:rename_document)
"set_contract_type"     → Action(:set_contract_type)
"edit_document"         → Action(:edit_document)
"send_chat_message"     → Action(:chat_message)
"revoke_change"         → Action(:revoke_change)
"upload_document"       → Action(:upload_document)
"create_variant"        → Action(:create_converted_variant)
```

### Studio visual principle

The Studio should feel like:

```text
Left:   what we know
Center: what we are writing
Right:  who helps us write
```

The Context Reservoir is the contract's memory.
The Document Canvas is the contract's text.
The Agent Rail is the contract's operator.

---

## 10a. Context Reservoir

StudioLive MUST include a persistent left-side Context Reservoir.

The Context Reservoir is a live projection of matter/document context. It is not the primary document editor and not a raw document navigator.

It SHOULD show:
- brief / purpose
- reusable fields
- open questions
- related documents
- source snapshots
- evidence snapshots
- important marks
- recent changes
- recent revokes
- export/readiness state

The Context Reservoir MAY allow direct editing of fields, answers, metadata, and context marks.

All edits from the Context Reservoir MUST become Actions and commit as Changes through Runtime, Session, Engine, and Store.

The agent MAY use the Context Reservoir as part of its context frame.

The Context Reservoir MUST NOT be the source of truth. Store + ChangeLog remain truth.

### What the Context Reservoir should contain

**Brief**
- purpose
- current drafting goal
- user role
- counterparty role
- status

**Shared fields**
- Party A
- Party B
- Effective date
- Jurisdiction
- Project name
- Permitted purpose
- Signers

**Open questions**
- Is this mutual or one-way?
- What is the confidentiality period?
- Which jurisdiction applies?

**Related documents**
- current draft
- uploaded source
- converted variant
- lawyer packet

**Sources**
- original upload
- Upstage parse snapshot
- imported HWPX/DOCX/PDF source

**Evidence**
- Korea-law-MCP result
- citation verification
- official/government comment
- source-preserved text

**Recent change context**
- agent changed clause
- user revoked agent edit
- contract type changed
- field migrated from another document

**Readiness**
- unresolved questions
- source-modified notes
- export warnings
- lawyer packet status

### What should not happen

Do not make the left sidebar a long raw list like:

    Document 5cad856e
    Document 8a0cf5bb
    Document 6a5c1bb0

Documents may appear in the reservoir, but only as contextual related documents with useful human labels:

    상호 비밀유지계약서 — current draft
    원본 업로드 — source
    NDA variant — generated variant
    변호사용 패킷 — review export

---

## 11. StudioLive Protocol Messages

`handle_info/2` is the LiveView protocol surface.

```text
{:studio_loaded, studio_state}
{:document_selected, document_id, revision}
{:change_committed, change}
{:change_revoked, change}
{:revoke_requested, request}
{:change_reconciled, change}
{:marks_changed, marks}
{:agent_stream, agent_run_id, stream_event}
{:agent_completed, agent_run_id, result}
{:agent_failed, agent_run_id, reason}
{:session_stale, document_id}
{:session_recovered, document_id, revision}
{:import_completed, document}
{:import_failed, import_id, reason}
{:export_ready, export}
{:export_failed, export_id, reason}
```

Rules:

1. LiveView MUST track `last_seen_revision`.
2. On any uncertainty, LiveView MUST call `Studio.sync/3`.
3. PubSub events are advisory; Store is truth.
4. If LiveView misses messages, `sync_since` repairs it.
5. Agent stream messages never mutate document state.
6. Only committed Changes mutate document projection.

On the following messages, StudioLive MUST refresh the Context Reservoir in addition to its other handling:

```text
{:change_committed, change}
{:change_revoked, change}
{:marks_changed, marks}
{:import_completed, document}
{:evidence_attached, evidence}
{:export_ready, export}
{:agent_completed, agent_run_id, result}
```

For these, StudioLive MUST update:

- document projection
- last_seen_revision
- context_reservoir
- agent rail state

The reservoir is a projection, so if LiveView crashes or misses messages, it must be rebuilt from Store + ChangeLog on mount/reconnect.

---

## 12. Runtime

`Runtime` routes Actions into the correct execution path. Routing is **matter-optional**: it keys off `document_id` for document-scoped Actions and only consults `matter_id` for grouping, shared-field, or pre-document Actions. A nil `matter_id` on a document-scoped Action is normal.

```elixir
defmodule Contract.Runtime do
  alias Contract.Types, as: T

  @spec load(T.ctx(), T.document_id()) :: T.result(Contract.Runtime.State.t())
  def load(ctx, document_id)

  @spec sync_since(T.ctx(), T.document_id(), T.revision()) ::
          T.result([Contract.Change.t()])
  def sync_since(ctx, document_id, revision)

  @spec apply(T.ctx(), Contract.Action.t()) ::
          T.result(Contract.Change.t() | Contract.Agent.Run.t() | Contract.Export.Job.t())
  def apply(ctx, action)

  @spec revoke(T.ctx(), Contract.Action.t()) ::
          T.result(Contract.Change.t() | Contract.RevokeRequest.t())
  def revoke(ctx, action)

  @spec subscribe(T.ctx(), T.document_id()) :: T.result(:ok)
  def subscribe(ctx, document_id)

  @spec ensure_session(T.ctx(), T.document_id()) :: T.result(pid())
  def ensure_session(ctx, document_id)
end
```

Routing:

```text
:create_document              → Engine/Store
:upload_document              → IO import
:rename_document              → Session/Engine/Store
:update_metadata              → Session/Engine/Store
:set_contract_type            → Session/Engine/Store
:edit_document                → Session/Engine/Store
:chat_message                 → Agent
:agent_change                 → Session/Engine/Store
:start_type_conversion        → Agent/Engine
:create_converted_variant     → Engine/Store
:request_export               → IO export
:revoke_change                → Engine/Store
```

---

## 13. Engine

Pure mechanics.

No LiveView.  
No OpenAI.  
No Slack.  
No MCP.

```elixir
defmodule Contract.Engine do
  alias Contract.Types, as: T

  @spec compile(Contract.Action.t(), Contract.Runtime.State.t()) ::
          T.result(Contract.ChangeInput.t())
  def compile(action, state)

  @spec validate(Contract.ChangeInput.t(), Contract.Runtime.State.t()) ::
          T.result(:ok)
  def validate(input, state)

  @spec preimage(Contract.ChangeInput.t(), Contract.Runtime.State.t()) ::
          T.result(map())
  def preimage(input, state)

  @spec inverse(Contract.ChangeInput.t(), map()) ::
          T.result([Contract.Operation.t()])
  def inverse(input, preimage)

  @spec apply(Contract.ChangeInput.t(), Contract.Runtime.State.t()) ::
          T.result(Contract.Runtime.State.t())
  def apply(input, state)

  @spec affected_refs(Contract.ChangeInput.t(), Contract.Runtime.State.t()) ::
          T.result([map()])
  def affected_refs(input, state)

  @spec build_change(Contract.Action.t(), Contract.ChangeInput.t(), Contract.Runtime.State.t()) ::
          T.result(Contract.Change.t())
  def build_change(action, input, state)
end
```

The Engine compiles all hard work:

```text
rename title
update metadata
set contract type
edit content
add mark
create variant
field migration
revoke
```

---

## 14. Session (DocumentSession)

Ephemeral coordinator, **per Document**.

`Contract.Session` IS the DocumentSession — one Session GenServer per Document. There is no MatterSession. The module name remains `Contract.Session` for code-path stability; the conceptual name is **DocumentSession**, and every reference below ("Session") means "the per-Document live coordinator."

Reconstructable.

Not truth.

```elixir
defmodule Contract.Session do
  # DocumentSession: one per Document. No MatterSession exists.
  use GenServer

  alias Contract.Types, as: T

  @spec start_link(document_id: T.document_id()) :: GenServer.on_start()
  def start_link(opts)

  @spec commit(pid() | T.document_id(), Contract.Action.t()) ::
          T.result(Contract.Change.t())
  def commit(session_or_document_id, action)

  @spec revoke(pid() | T.document_id(), Contract.Action.t()) ::
          T.result(Contract.Change.t() | Contract.RevokeRequest.t())
  def revoke(session_or_document_id, action)

  @spec current(pid() | T.document_id()) :: T.result(Contract.Runtime.State.t())
  def current(session_or_document_id)

  @spec sync_since(pid() | T.document_id(), T.revision()) ::
          T.result([Contract.Change.t()])
  def sync_since(session_or_document_id, revision)

  @spec heartbeat(pid()) :: T.result(:ok)
  def heartbeat(pid)

  @spec shutdown_if_stale(pid()) :: T.result(:ok)
  def shutdown_if_stale(pid)
end
```

Session starts:

```text
acquire lease
hydrate from Store
renew lease
accept commits while fenced
broadcast after commit
stop if stale
```

---

## 15. Lease

Lease is the current live-writer guard.

It prevents duplicated Session processes from committing.

```elixir
defmodule Contract.Lease do
  alias Contract.Types, as: T

  @spec acquire(T.document_id(), owner_ref :: String.t()) ::
          T.result(Contract.Lease.Record.t())
  def acquire(document_id, owner_ref)

  @spec renew(T.document_id(), owner_ref :: String.t(), fencing_token :: integer()) ::
          T.result(Contract.Lease.Record.t())
  def renew(document_id, owner_ref, fencing_token)

  @spec release(T.document_id(), owner_ref :: String.t(), fencing_token :: integer()) ::
          T.result(:ok)
  def release(document_id, owner_ref, fencing_token)

  @spec assert_current!(T.document_id(), fencing_token :: integer()) :: :ok | no_return()
  def assert_current!(document_id, fencing_token)
end
```

The current Session holder is:

```text
the Session process with the current lease and fencing token
```

The durable holder is:

```text
Store + ChangeLog
```

---

## 16. Store

Durable truth.

```elixir
defmodule Contract.Store do
  alias Contract.Types, as: T

  @spec load(T.document_id()) :: T.result(Contract.Runtime.State.t())
  def load(document_id)

  @spec snapshot(T.document_id(), T.revision()) ::
          T.result(Contract.Runtime.State.t())
  def snapshot(document_id, revision)

  @spec append(T.document_id(), Contract.Change.t(), fencing_token :: integer()) ::
          T.result(Contract.Change.t())
  def append(document_id, change, fencing_token)

  @spec changes_since(T.document_id(), T.revision()) ::
          T.result([Contract.Change.t()])
  def changes_since(document_id, revision)

  @spec latest_revision(T.document_id()) :: T.result(T.revision())
  def latest_revision(document_id)

  @spec idempotency_seen?(T.document_id(), T.idempotency_key()) :: boolean()
  def idempotency_seen?(document_id, idempotency_key)

  @spec previous_result(T.document_id(), T.idempotency_key()) ::
          T.result(Contract.Change.t())
  def previous_result(document_id, idempotency_key)

  @spec transaction((-> T.result(term()))) :: T.result(term())
  def transaction(fun)
end
```

Commit order lives here.

Not in LiveView.

Not in Agent.

Not in Session alone.

---

## 17. Revocation

Revocation is a Change.

```elixir
defmodule Contract.Revocation do
  alias Contract.Types, as: T

  @spec revoke(T.ctx(), T.document_id(), T.change_id(), T.opts()) ::
          T.result(Contract.Change.t() | Contract.RevokeRequest.t())
  def revoke(ctx, document_id, change_id, opts)

  @spec clean_revoke(T.ctx(), Contract.Runtime.State.t(), Contract.Change.t()) ::
          T.result(Contract.Change.t())
  def clean_revoke(ctx, state, change)

  @spec request_reconciliation(
          T.ctx(),
          Contract.Runtime.State.t(),
          Contract.Change.t(),
          [Contract.Change.t()]
        ) :: T.result(Contract.RevokeRequest.t())
  def request_reconciliation(ctx, state, change, overlaps)

  @spec resolve_reconciliation(
          T.ctx(),
          Contract.RevokeRequest.t(),
          Contract.Action.t()
        ) :: T.result(Contract.Change.t())
  def resolve_reconciliation(ctx, request, action)
end
```

Rule:

```text
No later overlap → clean inverse.
Later overlap → RevokeRequest.
```

---

## 18. Contract Type and Conversion

`Document.type_key` is the selected contract type. It is **selected after creation, not at creation**: a Document can exist with `type_key = nil` (untyped draft) and the user (or agent) sets it later via `Action(:set_contract_type)`. Setting/changing the type is a **document metadata Change**.

Converting type is a **document-to-document variant workflow** (see §19): default behavior for a major conversion is to create a new Document variant, not a massive in-place diff.

Contract type is a key.

No redundant IDs.

```elixir
defmodule Contract.ContractTypes do
  alias Contract.Types, as: T

  @spec list(T.ctx(), T.opts()) :: T.result([Contract.ContractTypes.TypeSpec.t()])
  def list(ctx, opts)

  @spec get(T.ctx(), T.contract_type_key()) ::
          T.result(Contract.ContractTypes.TypeSpec.t())
  def get(ctx, key)

  @spec compatible?(T.contract_type_key(), T.contract_type_key()) :: boolean()
  def compatible?(from_type, to_type)
end
```

Changing the type dropdown:

```text
Action(:set_contract_type)
```

This changes `Document.type_key`.

It does not rewrite content.

Converting to another type:

```text
Action(:start_type_conversion)
```

This starts migration.

---

## 19. Type Conversion and Field Migration

Type conversion avoids massive diffs by creating a variant and migrating fields.

**Field migration moves reusable values from the source Document to the target Document, optionally through Matter-level shared fields.** When two related Documents (e.g. an NDA and a Service Agreement variant) sit inside the same Matter, identity facts (party names, addresses, dates) can be linked to a Matter-level shared field so updates propagate; document-specific commercial terms are copied per-Document. Matter shared fields are an internal optimization — the user still operates on Documents.

```elixir
defmodule Contract.Conversion do
  alias Contract.Types, as: T

  @spec plan(T.ctx(), T.document_id(), T.contract_type_key(), T.opts()) ::
          T.result(Contract.Conversion.Plan.t())
  def plan(ctx, document_id, target_type_key, opts)

  @spec propose_fields(T.ctx(), Contract.Conversion.Plan.t()) ::
          T.result([Contract.Conversion.FieldPlan.t()])
  def propose_fields(ctx, plan)

  @spec set_field_strategy(
          T.ctx(),
          Contract.Conversion.Plan.t(),
          T.field_id(),
          strategy :: atom()
        ) :: T.result(Contract.Conversion.FieldPlan.t())
  def set_field_strategy(ctx, plan, source_field_id, strategy)

  @spec create_variant(T.ctx(), Contract.Conversion.Plan.t()) ::
          T.result(Contract.Change.t())
  def create_variant(ctx, plan)

  @spec adapt_in_place(
          T.ctx(),
          Contract.Conversion.Plan.t(),
          Contract.Action.t()
        ) :: T.result(Contract.Change.t())
  def adapt_in_place(ctx, plan, agent_action)
end
```

Strategies:

```text
copy_once
link_to_matter_field
derive
reference_only
ignore
ask_user
```

Default:

```text
identity facts → link/copy
document-specific commercial terms → copy or reference
ambiguous fields → ask_user
irrelevant fields → ignore/reference
```

---

## 20. Agent

Semantic interpreter.

Agent resolves targets.

Backend validates returned IDs.

```elixir
defmodule Contract.Agent do
  alias Contract.Types, as: T

  @spec start(T.ctx(), Contract.Action.t()) ::
          T.result(Contract.Agent.Run.t())
  def start(ctx, action)

  @spec cancel(T.ctx(), T.agent_run_id()) ::
          T.result(Contract.Agent.Run.t())
  def cancel(ctx, run_id)

  @spec observe_change(T.agent_run_id(), Contract.Change.t()) ::
          T.result(:ok)
  def observe_change(run_id, change)

  @spec observe_revoke(T.agent_run_id(), Contract.Change.t()) ::
          T.result(:ok)
  def observe_revoke(run_id, revoke_change)

  @spec build_context(T.ctx(), Contract.Action.t()) ::
          T.result(map())
  def build_context(ctx, action)

  @spec decode_action(map()) ::
          T.result(Contract.Action.t())
  def decode_action(provider_output)
end
```

Agent output is not a special `PatchBundle`.

It returns an Action, usually:

```text
Action(:agent_change)
```

The payload contains:

```text
ops
marks
message
```

Agent context SHOULD include:

```text
- current document state
- current selected node, if any
- recent changes
- recent revokes
- marks
- active questions
- Context Reservoir projection
- available related documents
- source/evidence summaries
```

The Context Reservoir is folded into the agent's context frame via:

```elixir
@spec include_context_reservoir(map(), Contract.Studio.ContextReservoir.t()) ::
        Contract.Types.result(map())
def include_context_reservoir(frame, reservoir)
```

The agent observes the reservoir as a read-only projection. Agent mutations to context still flow through Actions; the reservoir is never written to directly.

---

## 21. Gateway

External ingress.

```elixir
defmodule Contract.Gateway do
  alias Contract.Types, as: T

  @spec issue_route_ref(T.ctx(), map()) :: T.result(T.route_ref_token())
  def issue_route_ref(ctx, attrs)

  @spec verify_route_ref(T.ctx(), T.route_ref_token()) ::
          T.result(Contract.RouteRef.t())
  def verify_route_ref(ctx, token)

  @spec mcp_tool(T.ctx(), tool_name :: String.t(), args :: map()) ::
          T.result(map())
  def mcp_tool(ctx, tool_name, args)

  @spec slack_event(map()) :: T.result(:ok)
  def slack_event(payload)

  @spec slack_action(map()) :: T.result(:ok)
  def slack_action(payload)

  @spec slack_command(map()) :: T.result(:ok)
  def slack_command(payload)
end
```

Route refs carry durable IDs.

They do not carry PIDs.

---

## 22. IO

Provider and export adapters.

```elixir
defmodule Contract.IO do
  alias Contract.Types, as: T

  # matter_id is optional here. If nil, the backend may auto-create a
  # hidden Matter to host the resulting Document. The user is not asked
  # to pick a Matter on upload.
  @spec import_upload(T.ctx(), T.matter_id() | nil, T.upload()) ::
          T.result(Contract.Action.t())
  def import_upload(ctx, matter_id, upload)

  @spec parse_source(T.ctx(), source_ref :: String.t(), opts :: T.opts()) ::
          T.result(map())
  def parse_source(ctx, source_ref, opts)

  @spec search_law(T.ctx(), query :: String.t(), opts :: T.opts()) ::
          T.result(map())
  def search_law(ctx, query, opts)

  @spec verify_citation(T.ctx(), citation :: String.t(), opts :: T.opts()) ::
          T.result(map())
  def verify_citation(ctx, citation, opts)

  @spec export(T.ctx(), T.document_id(), format :: atom(), opts :: T.opts()) ::
          T.result(Contract.Export.t())
  def export(ctx, document_id, format, opts)
end
```

---

## 23. Provider Pipeline

Imported document:

```text
Upload
→ SourceSnapshot
→ Upstage parse
→ ParserSnapshot
→ Engine normalizes hard IR
→ Document selected in Studio
→ Agent adds soft marks as needed
→ User/agent edits through Actions
```

OpenAI is not the hard parser.

OpenAI is used for:

```text
target finding
dialog
semantic marks
agent edits
conversion planning
field migration proposal
law/evidence explanation
```

---

## 24. Agent Streaming

Streaming is live UI only.

```text
OpenAI stream
→ Agent
→ StudioLive handle_info({:agent_stream, ...})
→ chat rail updates
```

Document mutation happens only when the agent returns an Action and Runtime commits it as a Change.

---

## 25. LiveView ↔ Session Protocol

Mount with document:

```text
Studio.load
Runtime.ensure_session
Runtime.load
Runtime.subscribe
assign state/revision
```

User event:

```text
handle_event
→ Action
→ Studio.submit
→ Runtime.apply
→ Session.commit
→ Engine
→ Store.append
→ PubSub
```

Receive event:

```text
handle_info({:change_committed, change})
→ update projection
→ advance last_seen_revision
```

Reconnect:

```text
Studio.load
Runtime.load
Runtime.sync_since if needed
Runtime.subscribe
```

---

## 26. Final Abstraction

The final abstraction is:

```text
ContractWeb.StudioLive
  disposable UI

Contract.Studio
  product façade

Contract.Action
  one intent shape

Contract.Runtime
  routes actions

Contract.Engine
  compiles/applies mechanics

Contract.Session
  reconstructable coordinator

Contract.Lease
  current writer fencing

Contract.Store
  durable truth

Contract.Change
  reversible durable edit

Contract.Mark
  soft meaning

Contract.Conversion
  type conversion + field migration

Contract.Agent
  semantic interpreter

Contract.Gateway
  MCP/Slack/route_ref ingress

Contract.IO
  provider/import/export adapters
```

Everything else is implementation detail, data shape, or UI component.

The system can be summarized as:

```text
User or agent submits Action.
Runtime routes Action.
Session coordinates if active.
Engine compiles and applies.
Store appends Change.
LiveView renders Change.
Agent observes Changes and Revokes.
Conversion creates variants instead of massive diffs.
```

---

## 27. Final Hard Assumption

This spec assumes:

```text
one write-home region per document
```

If the product later requires active-active collaborative writes across regions for the same document, the design must be revisited. That is the only blocker found that flips the architecture.

---

## 28. Closing Principle

The Context Reservoir MUST help the user understand and correct the contract context without turning the UI into a file manager or metadata editor.

It is a projection of durable state, not the durable state itself.

Document remains primary. Matter remains contextual. Agent uses the reservoir. Store remains truth.

> Document is the product.
> Context Reservoir is the memory.
> Matter is context.
> Studio is the surface.
> Session is per Document.
> Action in, Change out.
> Store is truth.
