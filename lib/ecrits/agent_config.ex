defmodule Ecrits.AgentConfig do
  @moduledoc "Embedded state model for the active agent configuration."

  use Ecto.Schema

  import Ecto.Changeset

  alias __MODULE__.Access
  alias __MODULE__.Transition

  @primary_key false
  @reasoning_efforts ~w(minimal low medium high xhigh ultracode)

  embedded_schema do
    field :provider, :map, default: %{}
    field :provider_warning, :string
    field :model, :string, default: "default"
    field :reasoning_effort, :string, default: "medium"
    embeds_one :access, Access, on_replace: :update
    field :integrations, {:array, :map}, default: []
  end

  @type t :: %__MODULE__{}

  def new(attrs \\ %{}), do: apply_attrs(%__MODULE__{}, attrs)
  defdelegate put(config, attrs), to: Transition

  def changeset(%__MODULE__{} = config, attrs) when is_map(attrs) do
    config
    |> cast(config_params(attrs), [
      :provider,
      :provider_warning,
      :model,
      :reasoning_effort,
      :integrations
    ])
    |> cast_embed(:access, with: &Access.changeset/2)
    |> validate_required([:provider, :model, :reasoning_effort, :access])
    |> validate_length(:provider_warning, max: 1_000)
    |> validate_length(:model, max: 200)
    |> validate_inclusion(:reasoning_effort, @reasoning_efforts)
  end

  def selectable_provider(value, selectable_ids) when is_list(selectable_ids),
    do: allowed_provider(value, selectable_ids)

  def allowed_provider(value, allowed_ids) when is_list(allowed_ids) do
    provider = provider(value)
    if provider in allowed_ids, do: provider
  end

  def provider(value) do
    value =
      value
      |> normalize_string()
      |> case do
        value when value in ["codex", "codex_app_server"] -> "codex"
        value when value in ["claude", "claude_cli"] -> "claude"
        _value -> nil
      end

    changeset =
      {%{}, %{provider: :string}}
      |> cast(%{provider: value}, [:provider])
      |> validate_required([:provider])
      |> validate_inclusion(:provider, ~w(codex claude))

    if changeset.valid?, do: get_change(changeset, :provider)
  end

  def reasoning_effort(value, allowed_efforts) when is_list(allowed_efforts) do
    changeset =
      {%{}, %{reasoning_effort: :string}}
      |> cast(%{reasoning_effort: normalize_string(value)}, [:reasoning_effort])
      |> validate_required([:reasoning_effort])
      |> validate_inclusion(:reasoning_effort, allowed_efforts)

    if changeset.valid?, do: get_change(changeset, :reasoning_effort), else: "medium"
  end

  def access_control(value) do
    normalized =
      value
      |> normalize_string()
      |> case do
        value when value in ["read-only", "read_only", "readonly"] ->
          "read-only"

        value when value in ["ask", "on_write"] ->
          "ask"

        value when value in ["full", "full-workspace", "full_workspace", "workspace-write"] ->
          "full-workspace"

        _value ->
          nil
      end

    changeset =
      {%{}, %{access_control: :string}}
      |> cast(%{access_control: normalized}, [:access_control])
      |> validate_required([:access_control])
      |> validate_inclusion(:access_control, ~w(read-only ask full-workspace))

    if changeset.valid?, do: get_change(changeset, :access_control), else: "read-only"
  end

  def session_opts(%__MODULE__{access: %Access{} = access} = config) do
    [
      reasoning_effort: config.reasoning_effort,
      access_control: access.id,
      approval_policy: access.adapter_approval_policy,
      sandbox: access.sandbox,
      permission_mode: access.permission_mode
    ]
  end

  def adapter_opts(%__MODULE__{} = config, cwd) do
    [cwd: cwd, model: adapter_model(config.model)] ++
      Keyword.delete(session_opts(config), :access_control)
  end

  defp adapter_model("default"), do: nil
  defp adapter_model(model), do: model

  defp apply_attrs(config, attrs) do
    changeset = changeset(config, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: config
  end

  defp config_params(attrs) do
    case Map.get(attrs, :access, Map.get(attrs, "access")) do
      %Access{} = access ->
        key = if Map.has_key?(attrs, "access"), do: "access", else: :access
        Map.put(attrs, key, access |> Map.from_struct() |> Map.delete(:__meta__))

      _access ->
        attrs
    end
  end

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_string(_value), do: nil
end
