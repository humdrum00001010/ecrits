defmodule Contract.Command do
  @moduledoc """
  The one intent shape. Users, agents, Slack, MCP, import jobs, export jobs,
  and system jobs all normalize into `Contract.Command`. See SPEC.md §7.5.

  Pre-v0.5 this module was named `Contract`.`Action`. Renamed for the v0.5
  Command/Change vocabulary shift.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @type t :: %__MODULE__{}

  # Command kinds that always require a `document_id` to be resolvable.
  @document_scoped_kinds [
    :edit_document,
    :edit_text,
    :rename_document,
    :update_metadata,
    :set_contract_type,
    :add_mark,
    :update_mark,
    :revoke_change,
    :resolve_revoke,
    :request_export
  ]

  # Source-claim-scoped kinds always require a `source_claim_id`.
  @source_claim_scoped_kinds [
    :source_claim_confirm,
    :source_claim_correct,
    :source_claim_reject,
    :source_claim_link_to_document,
    :source_claim_unlink_from_document
  ]

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
        :edit_text,
        :add_mark,
        :update_mark,
        :source_claim_confirm,
        :source_claim_correct,
        :source_claim_reject,
        :source_claim_link_to_document,
        :source_claim_unlink_from_document,
        :start_type_conversion,
        :set_field_migration_strategy,
        :create_converted_variant,
        :chat_message,
        :agent_change,
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
      values: [:user, :agent, :lawyer, :slack, :system],
      default: :user

    field :actor_id, :binary_id

    field :base_revision, :integer
    field :idempotency_key, :string

    field :payload, :map, default: %{}
    field :message, :string
  end

  @doc """
  The Command.kind values that require a `:document_id` on the command.
  """
  @spec document_scoped_kinds() :: [atom()]
  def document_scoped_kinds, do: @document_scoped_kinds

  @doc """
  The Command.kind values that require a `:source_claim_id` on the command.
  """
  @spec source_claim_scoped_kinds() :: [atom()]
  def source_claim_scoped_kinds, do: @source_claim_scoped_kinds

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(command, attrs) do
    command
    |> cast(attrs, [
      :kind,
      :document_id,
      :chat_thread_id,
      :source_document_id,
      :source_claim_id,
      :change_id,
      :agent_run_id,
      :actor_type,
      :actor_id,
      :base_revision,
      :idempotency_key,
      :payload,
      :message
    ])
    |> validate_required([:kind])
    |> ensure_actor_type_default()
    |> validate_required([:actor_type])
    |> validate_length(:idempotency_key, min: 6, max: 128)
    |> validate_document_id_when_required()
    |> validate_source_claim_id_when_required()
  end

  defp ensure_actor_type_default(changeset) do
    case get_field(changeset, :actor_type) do
      nil -> put_change(changeset, :actor_type, :user)
      _ -> changeset
    end
  end

  defp validate_document_id_when_required(changeset) do
    kind = get_field(changeset, :kind)

    if kind in @document_scoped_kinds do
      validate_required(changeset, [:document_id])
    else
      changeset
    end
  end

  defp validate_source_claim_id_when_required(changeset) do
    kind = get_field(changeset, :kind)

    if kind in @source_claim_scoped_kinds do
      validate_required(changeset, [:source_claim_id])
    else
      changeset
    end
  end
end
