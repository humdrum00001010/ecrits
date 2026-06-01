defmodule Contract.Command do
  @moduledoc """
  The one intent shape. Users, agents, MCP, and system jobs normalize into
  `Contract.Command`. See SPEC.md §7.5.

  Pre-v0.5 this module was named `Contract`.`Action`. Renamed for the v0.5
  Command/Change vocabulary shift.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @type t :: %__MODULE__{}

  # Command kinds that always require a `document_id` to be resolvable.
  @document_scoped_kinds [
    :doc_write,
    :edit_document,
    :edit_text,
    :rename_document,
    :update_metadata,
    :set_contract_type
  ]

  @primary_key false

  embedded_schema do
    field :kind, Ecto.Enum,
      values: [
        :open_document,
        :create_document,
        :rename_document,
        :update_metadata,
        :set_contract_type,
        :doc_write,
        :edit_document,
        :edit_text,
        :agent_change
      ]

    field :document_id, :binary_id
    field :chat_thread_id, :binary_id
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

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(command, attrs) do
    command
    |> cast(attrs, [
      :kind,
      :document_id,
      :chat_thread_id,
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
end
