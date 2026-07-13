defmodule Ecrits.AgentConfig.Access do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :id, :string
    field :label, :string
    field :title, :string
    field :approval_policy, Ecto.Enum, values: [:on_write, :never]
    field :adapter_approval_policy, :string
    field :sandbox, :string
    field :permission_mode, :string
  end

  def changeset(access, attrs) do
    access
    |> cast(attrs, [
      :id,
      :label,
      :title,
      :approval_policy,
      :adapter_approval_policy,
      :sandbox,
      :permission_mode
    ])
    |> validate_required([
      :id,
      :label,
      :title,
      :approval_policy,
      :adapter_approval_policy,
      :sandbox,
      :permission_mode
    ])
    |> validate_inclusion(:id, ~w(read-only ask full-workspace))
    |> validate_inclusion(:adapter_approval_policy, ~w(on_write never))
    |> validate_inclusion(:sandbox, ~w(read-only workspace-write))
    |> validate_inclusion(:permission_mode, ~w(plan default dontAsk))
  end

  def all, do: Enum.map(~w(read-only ask full-workspace), &resolve/1)

  def resolve("ask") do
    build(%{
      id: "ask",
      label: "Ask",
      title: "Read and request approval before local writes.",
      approval_policy: :on_write,
      adapter_approval_policy: "on_write",
      sandbox: "workspace-write",
      permission_mode: "default"
    })
  end

  def resolve("full-workspace") do
    build(%{
      id: "full-workspace",
      label: "Full workspace",
      title: "Allow workspace writes without per-tool approval.",
      approval_policy: :never,
      adapter_approval_policy: "never",
      sandbox: "workspace-write",
      permission_mode: "dontAsk"
    })
  end

  def resolve(_access_control) do
    build(%{
      id: "read-only",
      label: "Read only",
      title: "Read workspace context. Write tools stay gated.",
      approval_policy: :on_write,
      adapter_approval_policy: "on_write",
      sandbox: "read-only",
      permission_mode: "plan"
    })
  end

  defp build(attrs), do: struct!(__MODULE__, attrs)
end
