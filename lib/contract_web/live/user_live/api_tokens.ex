defmodule ContractWeb.UserLive.ApiTokens do
  @moduledoc """
  `/settings/api-tokens` — stub LiveView for the API-tokens sub-page of
  the settings hub.

  Wave 3C2 added `Contract.Gateway.issue_route_ref/2` (signed, time-
  bounded route_ref tokens for MCP / deep-link auth). This page is the
  user-facing surface for that primitive: list the user's issued tokens
  and let them revoke any. However...

  ## What's stubbed (and why)

  Token persistence does not yet exist. There is no `user_api_tokens`
  Ecto schema, no migration, and no `Contract.ApiTokens` context. This
  page therefore:

    * Renders an empty state (no tokens to list).
    * Wires a "Generate token" modal that calls
      `handle_event("create_token", ...)` but does NOT persist anything;
      it flashes a success message and clears the modal.
    * Marks `list_user_tokens/1` as a stub returning `[]`.

  The goal for Wave 3C0-B is the **hub UX skeleton**, not a full token
  lifecycle. A later wave will:

    * Add a `user_api_tokens` table + `Contract.ApiTokens` context.
    * Have `create_token` call `Contract.Gateway.issue_route_ref/2`
      under the hood and persist the row.
    * Wire revoke buttons to delete the row + invalidate any cached
      verification of the token.

  Don't redesign `Contract.Gateway.issue_route_ref/2` when wiring real
  persistence — its signature is the contract. See SPEC.md §4 / §21.
  """
  use ContractWeb, :live_view

  alias ContractWeb.UserLive.SettingsHub

  # TODO Wave-X: real token storage table.
  @default_ttl_hours 168

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, dgettext("settings", "API tokens"))
      |> assign(:active_item, :api_tokens)
      |> assign(:show_modal, false)
      |> assign(:tokens, list_user_tokens(socket.assigns.current_scope))
      |> assign(:matters, list_user_matters(socket.assigns.current_scope))
      |> assign(:default_ttl_hours, @default_ttl_hours)
      |> assign(:form, to_form(%{}, as: :token))

    {:ok, socket}
  end

  @impl true
  def handle_event("open_modal", _params, socket) do
    {:noreply, assign(socket, :show_modal, true)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  def handle_event("create_token", _params, socket) do
    # TODO Wave-X: persist the token. For now we acknowledge the form
    # submission, flash a confirmation, and close the modal. We do NOT
    # actually call `Contract.Gateway.issue_route_ref/2` here — once
    # persistence lands, that call will move into a context module and
    # this handler will simply delegate.
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> put_flash(
       :info,
       dgettext("settings", "Generated: <hidden> — persistence ships in a later wave.")
     )}
  end

  def handle_event("revoke_token", %{"id" => _id}, socket) do
    # TODO Wave-X: delete the persisted token row. Stub for now so the
    # button is wired in the rendered HTML without crashing.
    {:noreply, put_flash(socket, :info, dgettext("settings", "Token revoked."))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="default">
      <SettingsHub.settings_layout active_item={@active_item}>
        <section id="api-tokens-page" class="space-y-6">
          <header class="space-y-1">
            <p class="text-xs font-medium tracking-wide uppercase text-base-content/50">
              {dgettext("settings", "Settings · API tokens")}
            </p>
            <h1 class="text-2xl font-semibold tracking-tight">
              {dgettext("settings", "API tokens")}
            </h1>
            <p class="text-sm text-base-content/60">
              {dgettext(
                "settings",
                "Route-ref tokens grant access to Contract Studio's MCP endpoint. Tokens are signed; revoke any time by deleting."
              )}
            </p>
          </header>

          <%= if @tokens == [] do %>
            <div
              id="api-tokens-empty"
              class="rounded-box border border-dashed border-base-300 p-10 text-center bg-base-200/30"
            >
              <.icon name="hero-key-mini" class="size-8 text-base-content/30 mx-auto" />
              <p class="font-medium mt-3">{dgettext("settings", "No API tokens yet")}</p>
              <p class="text-sm text-base-content/60 mt-1 max-w-sm mx-auto">
                {dgettext(
                  "settings",
                  "Generate a token to authenticate MCP requests from external clients."
                )}
              </p>
              <.button
                id="generate-token-button"
                variant="primary"
                class="mt-5"
                phx-click="open_modal"
              >
                <.icon name="hero-plus" class="size-4" /> {dgettext("settings", "Generate token")}
              </.button>
            </div>
          <% else %>
            <%!-- TODO Wave-X: real token storage table — when this lands the
                 list will be non-empty and the rows below will render. --%>
            <ul id="api-tokens-list" class="rounded-box border border-base-200 divide-y divide-base-200 bg-base-100">
              <li
                :for={token <- @tokens}
                class="px-4 py-3 flex items-center gap-4"
              >
                <.icon name="hero-key-mini" class="size-4 text-base-content/40 shrink-0" />
                <div class="flex-1 min-w-0">
                  <p class="text-sm font-medium truncate">{token.purpose}</p>
                  <p class="text-xs text-base-content/50">
                    {dgettext("settings", "Expires %{at}", at: token.expires_at)}
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="revoke_token"
                  phx-value-id={token.id}
                  class="btn btn-ghost btn-sm text-error"
                >
                  {dgettext("settings", "Revoke")}
                </button>
              </li>
            </ul>
          <% end %>
        </section>

        <%!-- Generate-token modal --%>
        <div
          :if={@show_modal}
          id="generate-token-modal"
          class="modal modal-open"
          phx-window-keydown="close_modal"
          phx-key="escape"
        >
          <div class="modal-box max-w-lg">
            <div class="flex items-start justify-between gap-4">
              <div>
                <h3 class="font-semibold text-lg tracking-tight">
                  {dgettext("settings", "Generate API token")}
                </h3>
                <p class="text-sm text-base-content/60">
                  {dgettext(
                    "settings",
                    "Scoped MCP route-ref. Stored signed; copy the token once after creation."
                  )}
                </p>
              </div>
              <button
                type="button"
                phx-click="close_modal"
                class="btn btn-sm btn-ghost btn-square"
                aria-label={dgettext("settings", "Close")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <.form
              for={%{}}
              as={:token}
              id="generate-token-form"
              phx-submit="create_token"
              class="space-y-3 mt-4"
            >
              <.input
                name="token[purpose]"
                value=""
                type="text"
                label={dgettext("settings", "Purpose")}
                placeholder={dgettext("settings", "e.g. mcp-cli, slack-bridge")}
              />
              <%!-- TODO Wave-X: list real matters from Contract.Matters once
                   that context exists. Today @matters is [] so only the
                   prompt is shown and the select is disabled. --%>
              <.input
                field={@form[:matter_id]}
                type="select"
                label={dgettext("settings", "Matter")}
                prompt={dgettext("settings", "No matters yet — token will be account-scoped")}
                options={Enum.map(@matters, &{&1.name, &1.id})}
                disabled={@matters == []}
              />
              <.input
                name="token[ttl_hours]"
                value={@default_ttl_hours}
                type="number"
                label={dgettext("settings", "TTL (hours)")}
                min="1"
              />
              <div class="flex items-center justify-end gap-2 pt-2">
                <button
                  type="button"
                  phx-click="close_modal"
                  class="btn btn-ghost btn-sm"
                >
                  {dgettext("settings", "Cancel")}
                </button>
                <button type="submit" class="btn btn-primary btn-sm">
                  {dgettext("settings", "Generate")}
                </button>
              </div>
            </.form>
          </div>
          <button
            type="button"
            phx-click="close_modal"
            class="modal-backdrop"
            aria-label={dgettext("settings", "Close modal")}
          >
            {dgettext("settings", "close")}
          </button>
        </div>
      </SettingsHub.settings_layout>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Stubs — replace once persistence lands.
  # ---------------------------------------------------------------------------

  # TODO Wave-X: real token storage table. Until then, no tokens.
  defp list_user_tokens(_scope), do: []

  # TODO Wave-X: list real matters via Contract.Matters.list_for_scope/1.
  # Empty list disables the matter select in the modal — by design.
  defp list_user_matters(_scope), do: []
end
