defmodule EcritsWeb.Workspace.AgentProviderSetupLive do
  @moduledoc """
  Local agent provider setup instructions.
  """

  use EcritsWeb, :live_view

  alias Ecrits.AcpAgent

  @impl true
  def mount(%{"provider" => provider_id} = params, _session, socket) do
    case AcpAgent.provider_setup(provider_id) do
      {:ok, provider} ->
        integration = provider_integration(provider.id)

        {:ok,
         socket
         |> assign(:page_title, "#{provider.label} setup")
         |> assign(:provider, provider)
         |> assign(:integration, integration)
         |> assign(:return_to, safe_return_to(params["return_to"]))}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Agent provider is unavailable.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant="default" show_footer={false}>
      <div
        id="agent-provider-setup"
        data-provider={@provider.id}
        data-status={to_string(@integration.status)}
        class="min-h-full bg-base-100 px-4 py-8 text-base-content sm:px-6"
      >
        <section class="mx-auto max-w-2xl rounded-md border border-base-300 bg-base-100">
          <header class="flex items-center justify-between gap-4 border-b border-base-300 px-4 py-3">
            <div class="flex min-w-0 items-center gap-3">
              <img
                src={@provider.favicon_src}
                alt=""
                class="size-5 shrink-0 opacity-85"
              />
              <div class="min-w-0">
                <h1 class="truncate text-base font-semibold">{@provider.label} setup</h1>
                <p
                  id="agent-provider-current-status"
                  class="truncate text-xs text-base-content/60"
                >
                  {provider_setup_status(@integration)}
                </p>
              </div>
            </div>
            <.link
              :if={@return_to}
              id="agent-provider-return"
              navigate={@return_to}
              class="inline-flex h-8 shrink-0 items-center gap-1 rounded border border-base-300 px-2 text-xs font-medium text-base-content/70 transition-colors hover:border-base-content/30 hover:text-base-content"
            >
              <.icon name="hero-arrow-left" class="size-3.5" />
              <span>Workspace</span>
            </.link>
          </header>

          <div class="space-y-5 px-4 py-4">
            <div class="rounded border border-base-300 bg-base-200/35 px-3 py-2">
              <p class="text-sm font-medium">Install</p>
              <code
                id="agent-provider-install-command"
                class="mt-2 block overflow-x-auto rounded bg-base-100 px-2 py-1.5 text-xs text-base-content"
              >
                {@provider.install_command}
              </code>
            </div>

            <div class="rounded border border-base-300 bg-base-200/35 px-3 py-2">
              <p class="text-sm font-medium">Log in</p>
              <code
                id="agent-provider-login-command"
                class="mt-2 block overflow-x-auto rounded bg-base-100 px-2 py-1.5 text-xs text-base-content"
              >
                {@provider.login_command}
              </code>
            </div>

            <div class="rounded border border-base-300 bg-base-200/35 px-3 py-2">
              <p class="text-sm font-medium">Check</p>
              <code
                id="agent-provider-check-command"
                class="mt-2 block overflow-x-auto rounded bg-base-100 px-2 py-1.5 text-xs text-base-content"
              >
                {@provider.check_command}
              </code>
            </div>

            <p
              id="agent-provider-next-step"
              class="border-t border-base-300 pt-4 text-sm leading-6 text-base-content/70"
            >
              After the command succeeds, return to the workspace and select {@provider.label} again from the provider menu.
            </p>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp provider_integration(provider_id) do
    AcpAgent.integration_options()
    |> Enum.find(&(&1.id == provider_id))
    |> case do
      nil -> %{status: :missing, detail: ""}
      integration -> integration
    end
  end

  defp provider_setup_status(%{status: :ready, detail: detail})
       when is_binary(detail) and detail != "" do
    "Ready - #{detail}"
  end

  defp provider_setup_status(%{status: :ready}), do: "Ready"

  defp provider_setup_status(%{status: :login_required, detail: detail})
       when is_binary(detail) and detail != "" do
    "Login required - #{detail}"
  end

  defp provider_setup_status(%{status: :missing, detail: detail})
       when is_binary(detail) and detail != "" do
    "Install required - #{detail}"
  end

  defp provider_setup_status(_integration), do: "Setup required"

  defp safe_return_to("/" <> rest) do
    if String.starts_with?(rest, "/"), do: nil, else: "/" <> rest
  end

  defp safe_return_to(_return_to), do: nil
end
