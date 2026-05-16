## Revision history
- 2026-05-15: Pivot from Matter-primary to Document-primary product framing. Document is now the primary user-facing object; Matter remains the internal context container. Routes reorganized to document-first; matter_id becomes optional on most Actions. UI label "Matter" → "Workspace" (or hidden). DocumentSession is the per-Document live coordinator.
- 2026-05-16: Add Context Reservoir as the persistent left-side projection of contract context...
- 2026-05-16 (v0.5): Substantial revision. Rename Action → Command. Move Engine → Session.Reducer (internal). REMOVE Matter entirely (Document.owner_id replaces it). Add new persistent schemas: ChatThread, SourceDocument, SourceClaim, EvidenceSnapshot, AgentRun, ToolCall, BlobRef. Replace Contract.IO with Contract.Blobs + Contract.Providers. Expand Contract.MCP to full resource+tool surface (20 tools, 16 resources). Add Lawyer packet as export format. StudioLive handle_event names switch to dotted notation ("document.edit", "chat.submit", "source_claim.confirm", ...). Context Reservoir REMOVED from this draft — left rail becomes optional outline / related-docs.

---

SPEC.md

Status: Draft v0.5
Primary stack: Elixir / Phoenix / LiveView
Core design: Document + ChatThread + SourceDocument + Command + Change

⸻

1. Purpose

This system is an AI-assisted contract writing and editing studio.

The product lets a user:

* discuss a contract with an always-open agent,
* upload an existing source document,
* let the agent parse and interpret that source document,
* supervise the agent’s interpretation,
* create or edit a working contract document,
* revoke prior changes,
* export a clean draft and lawyer-review packet.

The system is document-primary.

The user is not expected to create or manage a “Matter,” “Case,” or “ContextScope” in v1.

⸻

2. Final Product Model

Document
  = the contract the user edits
ChatThread
  = the conversation with the agent
SourceDocument
  = an uploaded/imported document-shaped source used as evidence/input
SourceClaim
  = the agent/parser’s supervised interpretation of a SourceDocument
Command
  = incoming intent
Change
  = durable reversible result
Mark
  = soft annotation/question/warning/explanation/link
Session
  = live coordinator for one active Document
Store
  = durable truth
Agent
  = semantic interpreter and editor
MCP
  = bounded tool/resource access for agents
Blobs
  = S3/R2/local object storage
Providers
  = OpenAI, Upstage, Korea-law-MCP, export renderers

⸻

3. Non-Goals

v1 does not attempt to:

* provide final legal responsibility,
* manage contract obligations after signing,
* implement full CLM,
* track payment/delivery/renewal execution after contract signing,
* support active-active multi-region editing of the same document,
* expose a user-facing “Matter” concept,
* build a full legal ontology,
* make Markdown the canonical document format,
* make PDF the editable format,
* treat generic images or random files as first-class context objects.

Optional v1 output:

* post-signing checklist extraction.

Not v1:

* post-signing obligation management.

⸻

4. UI Layout

The main product surface is one LiveView.

Top    = document title, contract type, metadata, export/share
Center = working contract document
Right  = always-open agent chat rail
Left   = optional outline / related documents later; not required in v1

The chat rail renders:

* normal agent/user messages,
* tool-call progress,
* source-document interpretation,
* questions,
* change summaries,
* revoke conflicts,
* export status,
* legal evidence summaries.

These are rendered as LiveView components.

They are not persisted as a Card or WorkCard abstraction.

⸻

5. Routes

Use LiveView for normal product behavior.

No browser /api routes are needed for regular document actions.

defmodule ContractWeb.Router do
  use ContractWeb, :router
  scope "/", ContractWeb do
    pipe_through [:browser, :authenticated]
    live "/studio", StudioLive
    live "/documents/:document_id", StudioLive
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

⸻

6. Shared Types

defmodule Contract.Types do
  @type id :: Ecto.UUID.t()
  @type ctx :: Contract.Context.t()
  @type result(value) :: {:ok, value} | {:error, term()}
  @type tenant_id :: id()
  @type user_id :: id()
  @type document_id :: id()
  @type chat_thread_id :: id()
  @type source_document_id :: id()
  @type source_claim_id :: id()
  @type change_id :: id()
  @type mark_id :: id()
  @type agent_run_id :: id()
  @type tool_call_id :: id()
  @type export_id :: id()
  @type evidence_id :: id()
  @type blob_ref_id :: id()
  @type revision :: non_neg_integer()
  @type idempotency_key :: String.t()
  @type contract_type_key :: String.t()
  @type route_ref_token :: String.t()
  @type params :: map()
  @type attrs :: map()
  @type opts :: keyword()
  @type upload :: Phoenix.LiveView.UploadEntry.t()
  @type socket :: Phoenix.LiveView.Socket.t()
end

⸻

7. Persistent Schemas

7.1 Document

Document is the primary user-facing object.

defmodule Contract.Document do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "documents" do
    field :owner_id, :binary_id
    field :title, :string
    field :type_key, :string
    field :metadata, :map, default: %{}
    field :status, Ecto.Enum,
      values: [:draft, :importing, :editing, :reviewing, :export_ready, :archived],
      default: :draft
    field :current_revision, :integer, default: 0
    field :state_snapshot, :map, default: %{}
    has_many :changes, Contract.Change
    has_many :marks, Contract.Mark
    has_many :source_documents, Contract.SourceDocument
    has_many :exports, Contract.Export
    timestamps()
  end
  def changeset(document, attrs)
end

Document.type_key is the selected contract type.

Changing type_key is metadata only.
It does not rewrite contract content.

⸻

7.2 ChatThread

A ChatThread is conversation.

It may exist before a Document.

defmodule Contract.ChatThread do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "chat_threads" do
    field :document_id, :binary_id
    field :owner_id, :binary_id
    field :status, Ecto.Enum,
      values: [:active, :attached, :archived],
      default: :active
    field :messages, {:array, :map}, default: []
    field :metadata, :map, default: %{}
    timestamps()
  end
  def changeset(thread, attrs)
end

Plain chat is not over-mystified into a separate context object.

If chat produces useful structured context, that context becomes a Mark, Command, SourceClaim, or Change.

⸻

7.3 SourceDocument

A SourceDocument is an uploaded or imported document-shaped source that needs parsing and supervised interpretation.

Examples:

* PDF contract,
* HWP/HWPX source,
* DOCX source,
* scanned contract treated as a document,
* government form,
* prior draft,
* counterparty draft.

Not examples:

* arbitrary image,
* random attachment,
* plain chat,
* Slack text.

defmodule Contract.SourceDocument do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "source_documents" do
    field :document_id, :binary_id
    field :chat_thread_id, :binary_id
    field :blob_ref, :map
    field :parser, :string
    field :parser_snapshot_ref, :map
    field :status, Ecto.Enum,
      values: [:uploaded, :parsing, :parsed, :interpreting, :ready, :failed],
      default: :uploaded
    field :regions, {:array, :map}, default: []
    field :metadata, :map, default: %{}
    has_many :claims, Contract.SourceClaim
    timestamps()
  end
  def changeset(source_document, attrs)
end

A SourceDocument is source evidence.
It is not the working contract unless explicitly converted/imported into a Document.

⸻

7.4 SourceClaim

A SourceClaim is a supervised interpretation of a SourceDocument.

It is visible and correctable.

defmodule Contract.SourceClaim do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "source_claims" do
    field :source_document_id, :binary_id
    field :document_id, :binary_id
    field :region_ref, :map
    field :label, :string
    field :value, :map
    field :confidence, Ecto.Enum,
      values: [:low, :medium, :high, :confirmed]
    field :status, Ecto.Enum,
      values: [:proposed, :confirmed, :corrected, :rejected, :superseded],
      default: :proposed
    field :linked_ref, :map
    field :metadata, :map, default: %{}
    timestamps()
  end
  def changeset(claim, attrs)
end

Examples:

"This appears to be Party A."
"This looks like the effective date."
"This blank likely maps to contract_amount."
"This clause appears to be a termination clause."

User can:

* confirm,
* correct,
* reject,
* link to working document.

⸻

7.5 Command

Command is the only incoming intent shape.

Use embedded_schema.

defmodule Contract.Command do
  use Ecto.Schema
  import Ecto.Changeset
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
        :source_claim_confirm,
        :source_claim_correct,
        :source_claim_reject,
        :source_claim_link_to_document,
        :chat_message,
        :agent_change,
        :start_type_conversion,
        :set_field_migration_strategy,
        :create_converted_variant,
        :revoke_change,
        :resolve_revoke,
        :request_export
      ]
    field :document_id, :binary_id
    field :chat_thread_id, :binary_id
    field :source_document_id, :binary_id
    field :source_claim_id, :binary_id
    field :change_id, :binary_id
    field :agent_run_id, :binary_id
    field :actor_type, Ecto.Enum,
      values: [:user, :agent, :lawyer, :slack, :system]
    field :actor_id, :binary_id
    field :base_revision, :integer
    field :idempotency_key, :string
    field :payload, :map, default: %{}
    field :message, :string
  end
  def changeset(command, attrs)
  def user(user_id, kind, attrs)
  def agent(agent_run_id, kind, attrs)
  def system(system_actor, kind, attrs)
end

Commands may come from:

* LiveView events,
* agent output,
* MCP tools,
* Slack actions,
* background jobs,
* import/export flows.

⸻

7.6 Change

Change is the durable reversible result of a Command.

defmodule Contract.Change do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "changes" do
    field :document_id, :binary_id
    field :chat_thread_id, :binary_id
    field :source_document_id, :binary_id
    field :command_kind, :string
    field :actor_type, Ecto.Enum,
      values: [:user, :agent, :lawyer, :slack, :system]
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
  def changeset(change, attrs)
  def active?(change)
  def revoked?(change)
  def touches?(change, affected_ref)
end

Every durable mutation is a Change:

title edit
metadata edit
contract type edit
document text edit
agent edit
source claim confirmation
mark update
conversion
export request
revoke

⸻

7.7 Mark

Mark is the durable soft annotation layer.

It may be renamed to Annotation, but this spec uses Mark.

defmodule Contract.Mark do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "marks" do
    field :document_id, :binary_id
    field :chat_thread_id, :binary_id
    field :source_document_id, :binary_id
    field :target_type, Ecto.Enum,
      values: [
        :document,
        :node,
        :field,
        :change,
        :source_document,
        :source_claim,
        :evidence,
        :export,
        :tool_call
      ]
    field :target_id, :binary_id
    field :intent, Ecto.Enum,
      values: [:ask, :explain, :flag, :label, :link]
    field :text, :string
    field :confidence, Ecto.Enum,
      values: [:low, :medium, :high, :confirmed]
    field :source, Ecto.Enum,
      values: [:user, :agent, :lawyer, :slack, :law_mcp, :system]
    field :status, Ecto.Enum,
      values: [:active, :resolved, :superseded, :hidden],
      default: :active
    field :data, :map, default: %{}
    timestamps()
  end
  def changeset(mark, attrs)
end

A Mark can represent:

* question,
* explanation,
* warning,
* label,
* legal evidence link,
* lawyer note,
* export warning,
* agent reason.

It does not mutate contract text.

⸻

7.8 EvidenceSnapshot

Legal MCP outputs become immutable evidence snapshots.

defmodule Contract.EvidenceSnapshot do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "evidence_snapshots" do
    field :document_id, :binary_id
    field :source_document_id, :binary_id
    field :change_id, :binary_id
    field :provider, :string
    field :query, :string
    field :citation, :string
    field :payload, :map
    field :raw_ref, :map
    field :status, Ecto.Enum,
      values: [:retrieved, :verified, :weak, :conflicting, :stale, :failed],
      default: :retrieved
    timestamps()
  end
  def changeset(snapshot, attrs)
end

EvidenceSnapshots are immutable after creation.

⸻

7.9 AgentRun and ToolCall

defmodule Contract.AgentRun do
  use Ecto.Schema
  import Ecto.Changeset
  schema "agent_runs" do
    field :document_id, :binary_id
    field :chat_thread_id, :binary_id
    field :status, Ecto.Enum,
      values: [:created, :streaming, :tool_calling, :completed, :failed, :cancelled]
    field :provider, :string
    field :model, :string
    field :skill_key, :string
    field :input_message, :string
    field :final_message, :string
    field :final_command, :map
    field :started_revision, :integer
    field :completed_revision, :integer
    field :metadata, :map, default: %{}
    timestamps()
  end
  def changeset(run, attrs)
end
defmodule Contract.ToolCall do
  use Ecto.Schema
  import Ecto.Changeset
  schema "tool_calls" do
    field :agent_run_id, :binary_id
    field :document_id, :binary_id
    field :source_document_id, :binary_id
    field :evidence_id, :binary_id
    field :tool_name, :string
    field :args, :map
    field :result, :map
    field :status, Ecto.Enum,
      values: [:started, :streaming, :completed, :failed],
      default: :started
    timestamps()
  end
  def changeset(tool_call, attrs)
end

Tool calls may be persisted for:

* audit,
* replay,
* UI display,
* legal evidence traceability.

⸻

7.10 Export

defmodule Contract.Export do
  use Ecto.Schema
  import Ecto.Changeset
  schema "exports" do
    field :document_id, :binary_id
    field :format, Ecto.Enum,
      values: [:pdf, :hwpx, :docx, :markdown, :lawyer_packet]
    field :source_revision, :integer
    field :status, Ecto.Enum,
      values: [:queued, :rendering, :available, :failed]
    field :blob_ref, :map
    field :metadata, :map, default: %{}
    timestamps()
  end
  def changeset(export, attrs)
end

⸻

8. Core Public Modules

Only these are public core modules:

ContractWeb.StudioLive
Contract.Studio
Contract.Session
Contract.Store
Contract.Agent
Contract.MCP
Contract.Slack
Contract.Blobs
Contract.Providers

Internal helpers:

Contract.Session.Reducer
Contract.Session.Lease
Contract.Session.Revocation
Contract.Studio.Import
Contract.Studio.Export

Schemas/data:

Contract.Document
Contract.ChatThread
Contract.SourceDocument
Contract.SourceClaim
Contract.Command
Contract.Change
Contract.Mark
Contract.EvidenceSnapshot
Contract.AgentRun
Contract.ToolCall
Contract.Export
Contract.BlobRef

⸻

9. StudioLive Protocol

StudioLive is the only primary UI surface.

Use handle_info/2 directly. Do not hide the protocol behind vague modules.

defmodule ContractWeb.StudioLive do
  use ContractWeb, :live_view
  # Boot
  def mount(params, session, socket)
  # Client events → Command
  def handle_event("chat.submit", params, socket)
  def handle_event("document.open", params, socket)
  def handle_event("document.create", params, socket)
  def handle_event("document.upload", params, socket)
  def handle_event("document.rename", params, socket)
  def handle_event("document.metadata.update", params, socket)
  def handle_event("document.type.set", params, socket)
  def handle_event("document.edit", params, socket)
  def handle_event("document.duplicate", params, socket)
  def handle_event("document.archive", params, socket)
  def handle_event("document.restore", params, socket)
  def handle_event("source_claim.confirm", params, socket)
  def handle_event("source_claim.correct", params, socket)
  def handle_event("source_claim.reject", params, socket)
  def handle_event("source_claim.link_to_document", params, socket)
  def handle_event("conversion.start", params, socket)
  def handle_event("conversion.field_strategy.set", params, socket)
  def handle_event("conversion.variant.create", params, socket)
  def handle_event("change.revoke", params, socket)
  def handle_event("revoke.resolve", params, socket)
  def handle_event("export.request", params, socket)
  def handle_event("ui.toggle_expand", params, socket)
  # Document/change protocol
  def handle_info({:document_selected, document_id, revision}, socket)
  def handle_info({:change_committed, document_id, change}, socket)
  def handle_info({:change_revoked, document_id, change}, socket)
  def handle_info({:revoke_requested, document_id, request}, socket)
  def handle_info({:change_reconciled, document_id, change}, socket)
  # Agent/tool stream protocol
  def handle_info({:agent_stream, agent_run_id, event}, socket)
  def handle_info({:agent_completed, agent_run_id, result}, socket)
  def handle_info({:agent_failed, agent_run_id, reason}, socket)
  def handle_info({:tool_call_started, agent_run_id, tool_call}, socket)
  def handle_info({:tool_call_delta, agent_run_id, tool_call_id, delta}, socket)
  def handle_info({:tool_call_completed, agent_run_id, tool_call_id, result}, socket)
  def handle_info({:tool_call_failed, agent_run_id, tool_call_id, reason}, socket)
  # Source document protocol
  def handle_info({:source_document_uploaded, source_document}, socket)
  def handle_info({:source_document_parse_started, source_document_id}, socket)
  def handle_info({:source_document_parsed, source_document}, socket)
  def handle_info({:source_interpretation_ready, source_document_id, claims}, socket)
  def handle_info({:source_claim_updated, claim}, socket)
  # Evidence protocol
  def handle_info({:evidence_created, evidence}, socket)
  def handle_info({:evidence_attached, evidence, mark}, socket)
  # Session recovery protocol
  def handle_info({:session_stale, document_id}, socket)
  def handle_info({:session_recovered, document_id, revision}, socket)
  # Import/export protocol
  def handle_info({:import_started, import_id}, socket)
  def handle_info({:import_completed, document}, socket)
  def handle_info({:import_failed, import_id, reason}, socket)
  def handle_info({:export_started, export_id}, socket)
  def handle_info({:export_ready, export}, socket)
  def handle_info({:export_failed, export_id, reason}, socket)
  # Fallback
  def handle_info(message, socket)
end

StudioLive invariants

LiveView tracks selected_document_id.
LiveView tracks last_seen_revision.
LiveView never owns truth.
LiveView never owns Session.
LiveView never calls OpenAI directly.
PubSub is notification only.
If revision gap appears, LiveView syncs from Store.
Agent streams/tool deltas mutate only UI.
Only committed Change updates document projection.

⸻

10. Studio

Studio is the product façade.

defmodule Contract.Studio do
  def open(ctx, params)
  def command(ctx, command)
  def sync(ctx, document_id, from_revision)
  def subscribe(ctx, document_id)
  def route_ref(ctx, document_or_thread, opts)
end

Behavior:

document mutation command → Session.command
chat command → Agent.start
source upload command → Blobs + Providers + Session.command
export command → Providers.render_export + Blobs

⸻

11. Session

One live coordinator per active Document.

defmodule Contract.Session do
  use GenServer
  def ensure(ctx, document_id)
  def command(document_id, command)
  def current(document_id)
  def sync_since(document_id, revision)
  def renew_lease(pid)
  def shutdown_if_stale(pid)
end

Session is reconstructable.
Session is not truth.

⸻

12. Store

Store is durable truth.

defmodule Contract.Store do
  def load(document_id)
  def append(document_id, change, fencing_token)
  def changes_since(document_id, revision)
  def latest_revision(document_id)
  def idempotency_seen?(document_id, idempotency_key)
  def previous_result(document_id, idempotency_key)
  def transaction(fun)
end

⸻

13. Session Helpers

These are internal helpers.
Do not promote them to top-level architecture.

defmodule Contract.Session.Reducer do
  def compile(command, document_state)
  def validate(input, document_state)
  def preimage(input, document_state)
  def inverse(input, preimage)
  def affected_refs(input, document_state)
  def apply(input, document_state)
  def build_change(command, input, document_state)
end
defmodule Contract.Session.Lease do
  def acquire(document_id, owner_ref)
  def renew(document_id, owner_ref, fencing_token)
  def release(document_id, owner_ref, fencing_token)
  def assert_current!(document_id, fencing_token)
end
defmodule Contract.Session.Revocation do
  def revoke(ctx, document_state, change_id, opts)
  def clean_revoke(ctx, document_state, change)
  def request_reconciliation(ctx, document_state, change, overlaps)
  def resolve_reconciliation(ctx, request, command)
end

⸻

14. Agent

Agent performs semantic work and returns Commands.

defmodule Contract.Agent do
  def start(ctx, command)
  def cancel(ctx, agent_run_id)
  def run_skill(ctx, skill_key, input, opts)
  def build_context(ctx, command)
  def decode_command(provider_output)
  def observe_change(agent_run_id, change)
  def observe_revoke(agent_run_id, change)
end

Skills:

:studio_router
:document_selection
:context_gathering
:source_document_interpretation
:source_claim_mapping
:edit_document
:type_conversion
:field_migration
:revoke_reconciliation
:law_evidence
:lawyer_packet

A skill returns:

Command

or:

no-op message

It never writes Store directly.

⸻

15. Agent Streaming

Streaming is live UI only.

OpenAI stream
→ Agent process
→ StudioLive.handle_info({:agent_stream, ...})
→ chat rail updates

Streaming deltas do not mutate Store.

Only a final decoded Command may commit as a Change.

If the user edits during agent streaming:

unrelated edit → continue
same-target edit → invalidate/rebase/restart
contract type change → rebuild context
revoke prior agent edit → agent must observe and avoid reapplying
stale final command → reject or rebase

⸻

16. MCP

Contract.MCP is the external agent tool/resource layer.

It must capture behavior, not just list functions.

defmodule Contract.MCP do
  def initialize(conn_or_payload)
  def list_resources(ctx, route_ref)
  def read_resource(ctx, route_ref, uri)
  def list_tools(ctx, route_ref)
  def call_tool(ctx, route_ref, tool_name, args)
end

MCP rules

MCP reads expose projections.
MCP mutations emit Commands.
MCP tools never mutate Store directly.
MCP route_ref carries durable IDs, not PIDs.
MCP tools are scoped by tenant/user/document/thread permissions.

RouteRef

route_ref is a signed opaque token.

It may include:

tenant_id
user_id
document_id
chat_thread_id
agent_run_id
base_revision
home_region
expires_at

It must not include:

BEAM pid
fencing token
raw secrets
unrelated document IDs

⸻

MCP resources

chat_thread://{id}
chat_thread://{id}/messages
document://{id}/state
document://{id}/outline
document://{id}/nodes
document://{id}/fields
document://{id}/changes
document://{id}/revokes
document://{id}/marks
source_document://{id}
source_document://{id}/regions
source_document://{id}/claims
source_document://{id}/links
tool_call://{id}
evidence://{id}
evidence://{id}/raw
evidence://{id}/citation
evidence://{id}/links
export://{id}/readiness

⸻

MCP tools

document.open
document.read
document.search
document.submit_command
document.revoke_change
source_document.read
source_document.search_regions
source_document.propose_claims
source_document.confirm_claim
source_document.correct_claim
source_document.reject_claim
source_document.link_claim_to_document
law.search
law.get_text
law.search_precedents
law.verify_citation
evidence.attach_mark
collab.ask_user
collab.fetch_slack_context

MCP tool behavior

document.submit_command:

validates route_ref
normalizes args into Command
calls Studio.command
returns committed Change or error

source_document.propose_claims:

reads SourceDocument
runs agent/source interpretation
creates SourceClaims
returns proposed claims

law.search:

calls legal provider
creates immutable EvidenceSnapshot
returns evidence_id + summary

evidence.attach_mark:

normalizes into Command(:add_mark)
commits through Session/Store

⸻

17. Legal MCP / Evidence Protocol

Legal MCP is an evidence provider, not a document editor.

The system may use Korea-law-MCP or another legal MCP to:

* search laws,
* retrieve law text,
* search precedents,
* verify citations.

Legal MCP results that affect the product must be persisted as immutable EvidenceSnapshots.

Required flow:

agent asks legal question
→ MCP/legal provider tool call
→ EvidenceSnapshot persisted
→ Mark(:link or :flag) attached to document/source/change
→ optional agent edit Command
→ Change committed through Session/Store

Forbidden flow:

legal MCP result → direct contract mutation

Legal claim rule

If the agent claims legal support, it should attach an EvidenceSnapshot.

If no evidence exists, the claim must be marked as:

uncited
uncertain
needs lawyer review

Lawyer packet

Lawyer packet should include:

* relevant EvidenceSnapshots,
* citation verification status,
* evidence-linked Marks,
* unresolved legal uncertainty flags,
* source claims used in drafting,
* changes made because of legal evidence.

⸻

18. SourceDocument Flow

User uploads source document
→ Blobs.put_upload
→ SourceDocument created
→ Providers.parse_document, usually Upstage
→ parser snapshot saved
→ regions extracted
→ agent proposes SourceClaims
→ chat rail renders source interpretation component
→ user confirms/corrects/rejects claims
→ confirmed claims may link to working Document

The source interpretation UI lives in the chat rail as expandable/collapsible components.

No separate persistent Card schema.

⸻

19. Blobs

Blobs is object storage only.

It handles S3/R2/MinIO/local storage.

defmodule Contract.Blobs do
  def put(ctx, binary, opts)
  def put_upload(ctx, upload, opts)
  def get(ctx, blob_ref)
  def signed_url(ctx, blob_ref, opts)
  def delete(ctx, blob_ref)
end

Blob usage:

uploaded source file
parser payload
exported PDF/HWPX/DOCX/Markdown
law evidence raw payload if large

⸻

20. Providers

Providers is external API calls only.

defmodule Contract.Providers do
  def parse_document(ctx, blob_ref, opts)
  def stream_agent(ctx, request, handler, opts)
  def search_law(ctx, query, opts)
  def get_law_text(ctx, law_ref, opts)
  def search_precedents(ctx, query, opts)
  def verify_citation(ctx, citation, opts)
  def render_export(ctx, document_state, format, opts)
end

Provider mapping:

parse_document → Upstage
stream_agent → OpenAI
search_law / verify_citation → Korea-law-MCP or legal provider
render_export → PDF/HWPX/DOCX/Markdown renderers

⸻

21. Provider Pipeline

Upload/import

Upload
→ Blob
→ SourceDocument
→ Upstage parse
→ parser snapshot
→ source regions
→ source claims
→ user supervision
→ optional working Document creation/edit

OpenAI is not the hard layout parser.

OpenAI is used for:

* target finding,
* dialog,
* source claim proposal,
* semantic labels,
* agent edits,
* conversion planning,
* field migration proposal,
* legal evidence explanation,
* lawyer packet summarization.

⸻

22. Export Path

Exports are projections from current Document state.

Supported exports:

pdf
hwpx
docx
markdown
lawyer_packet

PDF

Final/frozen/read-only style export.

HWPX/DOCX

Editable fallback exports.

The canonical truth remains the Document state and ChangeLog.

Offline-edited HWPX/DOCX files are treated as new SourceDocuments if re-imported.

Do not promise perfect round-trip.

Markdown

Semantic auxiliary export.

Useful for:

* clause text,
* review memo,
* agent-readable summary,
* lawyer packet text section.

Not primary legal-document export.

Lawyer packet

The lawyer packet should include:

* clean draft,
* document title/type/metadata,
* source documents used,
* confirmed/corrected/rejected source claims,
* relevant changes,
* revokes,
* unresolved questions,
* relevant Marks,
* EvidenceSnapshots,
* citation verification status,
* export timestamp,
* document revision.

Export flow

Command(:request_export)
→ Studio.command
→ Providers.render_export
→ Blobs.put
→ Export persisted
→ StudioLive.handle_info({:export_ready, export})

⸻

23. Contract Type and Conversion

Document.type_key is selected contract type.

Changing type_key is metadata only.

It commits a small Change and does not rewrite document content.

If the user wants conversion:

Command(:start_type_conversion)

Default strategy for major conversion:

create new Document variant

Do not produce massive in-place diffs by default.

Field migration strategies

copy_once
link_to_document_field
derive
reference_only
ignore
ask_user

Conversion should show a summary:

Carried over:
- parties
- effective date
- jurisdiction
Derived:
- service purpose → NDA permitted purpose
Not carried:
- payment terms
- service deliverables
Needs answer:
- mutual or one-way NDA?
- confidentiality duration?

⸻

24. Revocation

Edits apply immediately but are revokable.

A revoke is another Change.

Clean revoke

If no later Change touched the same affected refs:

apply inverse_ops
commit revoke Change

Overlap revoke

If later overlapping Changes exist:

create RevokeRequest
show reconciliation UI
agent may help reconcile
user can accept/edit resolution

The system must never delete Change history.

⸻

25. Change Boundaries

Do not create a Change for every keystroke.

Recommended boundaries:

title edit → blur/debounce
metadata edit → field save
field edit → blur/enter
paragraph edit → save/blur
agent edit → one coherent target/purpose
source claim confirmation → one Change
revoke → one Change
export request → one Change or Export record

⸻

26. Session / Store / Fault Tolerance

Session coordinates active document writes.

Store is truth.

Session may crash, duplicate, or become stale.

Only the current lease holder can commit.

Session lease

Lease/fencing is an internal guard.

Session acquires lease
Session renews lease
Store verifies fencing token on append
stale Session cannot commit

Heartbeat is only lease renewal.

It is not product logic.

LiveView crash

LiveView dies
Session may continue
Agent may continue
Store remains truth
LiveView remounts
loads current state
syncs from revision

Session crash

Session dies
Store remains truth
new Session reconstructs from Store

⸻

27. UI Components

Components are UI-only.

No domain schema.

Examples:

ChatRail
ToolCallBlock
SourceInterpretationBlock
SourceClaimBlock
QuestionBlock
ChangeBlock
RevokeBlock
ExportStatusBlock
DocumentCanvas
TopBar

Expand/collapse is LiveView UI state:

socket.assigns.expanded

No Card, WorkCard, or ChatCard domain object.

⸻

28. Final Reduced Flow

User edit

StudioLive.handle_event("document.edit")
→ Command(:edit_document)
→ Studio.command
→ Session.command
→ Session.Reducer
→ Store.append(Change)
→ StudioLive.handle_info({:change_committed, ...})

Chat

StudioLive.handle_event("chat.submit")
→ Command(:chat_message)
→ Studio.command
→ Agent.start
→ agent streams to chat rail
→ agent returns Command(:agent_change)
→ Studio.command
→ Session.command
→ Store.append(Change)

Upload source document

StudioLive.handle_event("document.upload")
→ Command(:upload_document)
→ Studio.command
→ Blobs.put_upload
→ Providers.parse_document
→ SourceDocument + SourceClaims
→ StudioLive source-document messages
→ chat rail renders interpretation components

Confirm source interpretation

source_claim.confirm
→ Command(:source_claim_confirm)
→ Studio.command
→ Session.command
→ Store.append(Change)

Legal evidence

agent requests law evidence
→ MCP law.search
→ Providers.search_law
→ EvidenceSnapshot persisted
→ Mark attached
→ optional agent edit Command
→ Change committed

Revoke

change.revoke
→ Command(:revoke_change)
→ Studio.command
→ Session.command
→ clean inverse or RevokeRequest
→ Store.append(Change)

Export

export.request
→ Command(:request_export)
→ Providers.render_export
→ Blobs.put
→ Export persisted
→ export_ready signal

⸻

29. Known Design-Flipping Blocker

This design assumes:

one write-home region per document

If active-active multi-region writing to the same document is required, this design must be revisited.

That would likely require CRDT/OT-style conflict semantics or a different replication model.

⸻

30. Final Summary

Document is the product.
ChatThread is conversation.
SourceDocument is parsed source evidence.
SourceClaim is supervised interpretation.
Command is intent.
Change is durable work.
Mark is soft meaning.
EvidenceSnapshot is immutable legal evidence.
Session coordinates.
Store is truth.
Agent reasons.
MCP exposes bounded tools.
Blobs store files.
Providers call external APIs.
StudioLive renders everything live.
