defmodule Ecrits.Agent.Item.EditPreview do
  @moduledoc "Typed durable edit-preview descriptor."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.Agent.Item

  @primary_key false
  @statuses [
    :pending,
    :running,
    :queued,
    :sent,
    :completed,
    :failed,
    :cancelled,
    :approval_required
  ]
  @fields [
    :role,
    :status,
    :body,
    :reason,
    :turn_id,
    :document_path,
    :document,
    :document_id,
    :doc,
    :applied,
    :failed,
    :composition_ops,
    :ops,
    :sets,
    :delta_count,
    :revision_count,
    :revision,
    :highlights,
    :preview_steps,
    :scroll,
    :marker,
    :summary,
    :source,
    :path,
    :relative_path,
    :backend,
    :format,
    :ref,
    :hash,
    :version,
    :mode,
    :preview_snapshot,
    :edit_id,
    :preview_identity,
    :preview_unavailable,
    :preview_error,
    :composed_tool_call_ids
  ]

  embedded_schema do
    field :role, Ecto.Enum, values: [:edit_preview]
    field :status, Ecto.Enum, values: @statuses
    field :body, :any, virtual: true
    field :reason, :string
    field :turn_id, :string
    field :document_path, :string
    field :document, :string
    field :document_id, :string
    field :doc, :string
    field :applied, :integer
    field :failed, :any, virtual: true
    field :composition_ops, :any, virtual: true
    field :ops, :any, virtual: true
    field :sets, :any, virtual: true
    field :delta_count, :integer
    field :revision_count, :integer
    field :revision, :any, virtual: true
    field :highlights, :any, virtual: true
    field :preview_steps, :any, virtual: true
    field :scroll, :any, virtual: true
    field :marker, :any, virtual: true
    field :summary, :string
    field :source, :any, virtual: true
    field :path, :string
    field :relative_path, :string
    field :backend, :any, virtual: true
    field :format, :any, virtual: true
    field :ref, :any, virtual: true
    field :hash, :any, virtual: true
    field :version, :any, virtual: true
    field :mode, :any, virtual: true
    field :preview_snapshot, :any, virtual: true
    field :edit_id, :string
    field :preview_identity, :any, virtual: true
    field :preview_unavailable, :boolean
    field :preview_error, :any, virtual: true
    field :composed_tool_call_ids, :any, virtual: true
    field :extensions, :map, virtual: true, default: %{}
    field :present_fields, :any, virtual: true, default: []
  end

  @type t :: %__MODULE__{}

  @spec cast(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(attrs) do
    %__MODULE__{}
    |> cast(Item.params(attrs, @fields), @fields ++ [:extensions, :present_fields],
      empty_values: []
    )
    |> validate_required([:role])
    |> apply_action(:insert)
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = item), do: Item.dump_fields(item, @fields)
end
