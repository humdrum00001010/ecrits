defmodule EcritsWeb.Local.LocalAgentConfig do
  @moduledoc """
  The bound local-agent settings as ONE typed assign (`:local_agent`) instead of
  six parallel `local_agent_*` assigns.

  `access` is the whole access-mode record (id + label/title + approval/sandbox/
  permission policy from `WorkspaceLive.local_agent_access_control/1`), so the
  five access-derived values read uniformly off `config.access.*` rather than
  fanning out into separate assigns. Update fields with
  `WorkspaceLive.put_local_agent/2` (or `put_local_agent_access/2` for the access
  record); the struct is never rebuilt wholesale outside `mount`.
  """

  @typedoc "An access-mode record (see `WorkspaceLive.local_agent_access_control/1`)."
  @type access :: %{
          id: String.t(),
          label: String.t(),
          title: String.t(),
          approval_policy: atom(),
          adapter_approval_policy: String.t(),
          sandbox: String.t(),
          permission_mode: String.t()
        }

  @type t :: %__MODULE__{
          provider: map(),
          provider_warning: String.t() | nil,
          model: String.t(),
          reasoning_effort: String.t(),
          access: access(),
          integrations: list()
        }

  @enforce_keys [:provider, :model, :reasoning_effort, :access]
  defstruct [
    :provider,
    :provider_warning,
    :model,
    :reasoning_effort,
    :access,
    integrations: []
  ]

  @doc """
  The canonical session-owned bundle the durable `WorkspaceSession` persists —
  the settings the agent OWNS (reasoning + the full access policy). Pure on the
  config: `access.*` already carries the UI id AND the adapter terms (approval/
  sandbox/permission), so no re-derivation is needed.
  """
  @spec session_opts(t()) :: keyword()
  def session_opts(%__MODULE__{access: access} = config) do
    [
      reasoning_effort: config.reasoning_effort,
      access_control: access.id,
      approval_policy: access.adapter_approval_policy,
      sandbox: access.sandbox,
      permission_mode: access.permission_mode
    ]
  end

  @doc """
  The ACP adapter options derived from the config + the workspace `cwd`: the
  session bundle plus `cwd`/`model`. `access_control` is the UI id (not an
  adapter key), so it's dropped here; the adapter takes `approval_policy` instead.
  """
  @spec adapter_opts(t(), Path.t()) :: keyword()
  def adapter_opts(%__MODULE__{} = config, cwd) do
    [cwd: cwd, model: adapter_model(config.model)] ++
      Keyword.delete(session_opts(config), :access_control)
  end

  # `"default"` is the adapter's "use the provider default" sentinel → nil; any
  # other (already-resolved) model id passes through.
  defp adapter_model("default"), do: nil
  defp adapter_model(model), do: model
end
