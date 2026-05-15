defmodule ContractWeb.Components.CommandPalette do
  @moduledoc """
  Global Cmd+K / Ctrl+K command palette (Wave 3C0-B).

  Mounted once per authenticated page via `ContractWeb.Layouts.app/1`. The
  palette is a self-contained `Phoenix.LiveComponent` that:

    * binds a `Palette` JS hook on the root element so it can intercept
      `Cmd/Ctrl+K` from anywhere in the document and forward a `"toggle"`
      event back to this component;

    * holds its own open/closed/query/selected state — the parent LV does
      not need to know it exists;

    * filters commands by `@current_scope.perms` so personas without
      `:export` never see "Request export…", etc.;

    * dispatches navigation commands inline (via `Phoenix.LiveView.JS`)
      and emits a `command_palette_picked` browser event for action
      commands (Studio LV will intercept once Wave 3C1 lands).

  Commands available are grouped — Navigation, Documents (Studio-only),
  Search, Help — and matched against the query with a tiny in-module
  subsequence fuzzy matcher (no external dep, ~30 LOC of pure Elixir).

  ## Modes

  Internally the palette is in one of:

    * `:list` (default) — input + filtered command list.
    * `:info` — an in-palette panel ("what can the agent do?",
      "Keyboard shortcuts"). Returns to `:list` on Esc / back arrow.
    * `:search_documents` — local document substring search (debounced
      200ms client-side; stub backend until DocumentList lands).
    * `:search_law` — invokes `Contract.IO.LawMCP.search_law/2` and
      displays the returned list.

  Keyboard:

    * `Cmd/Ctrl+K` toggles open/closed (handled in JS hook).
    * `Up` / `Down` move the selection.
    * `Enter` fires the selected command.
    * `Esc` closes the palette (or backs out of an `:info`/search mode).
  """
  use ContractWeb, :live_component

  alias Contract.IO.LawMCP
  alias Phoenix.LiveView.JS

  defmodule Command do
    @moduledoc """
    A single palette entry. `action` is one of:

      * `{:navigate, path}` — fires `JS.navigate(path)` inline.
      * `{:emit, kind, payload}` — pushes `command_palette_picked` to the
        parent LV.
      * `{:mode, mode}` — switches the palette into a sub-mode without
        closing it (used for the in-palette info panels and the two
        search experiences).
    """
    @enforce_keys [:id, :label, :action, :group]
    defstruct [
      :id,
      :label,
      :hint,
      :action,
      :group,
      scopes_required: []
    ]

    @type action ::
            {:navigate, String.t()}
            | {:emit, atom(), map()}
            | {:mode, atom()}

    @type t :: %__MODULE__{
            id: atom(),
            label: String.t(),
            hint: String.t() | nil,
            action: action(),
            group: atom(),
            scopes_required: [atom()]
          }
  end

  @group_order [:navigation, :documents, :search, :help]
  @group_label %{
    navigation: "Navigation",
    documents: "Documents",
    search: "Search",
    help: "Help"
  }

  # --- Layout entrypoint ------------------------------------------------

  @doc """
  Layout wrapper: renders the live-component when the calling render is
  happening inside a LiveView, and a no-op otherwise (so dead controller
  views like the landing page don't blow up — `<.live_component>` is not
  supported outside a LiveView).

  The discriminator is whether `Phoenix.LiveView.Socket` is in the
  caller's process dictionary under the standard `$callers` /
  `$initial_call` markers Phoenix sets on every LV GenServer.
  """
  attr :current_scope, :any, default: nil

  def mount_if_live(assigns) do
    cond do
      is_nil(assigns.current_scope) ->
        ~H""

      controller_render?() ->
        # Plug.CSRFProtection sets `:plug_masked_csrf_token` in the
        # process dictionary during a controller pipeline (see
        # Phoenix.Controller.protect_from_forgery). LiveView's static
        # and live render paths do not — so this is a reliable
        # "we are inside a dead controller render" marker. We must
        # skip `<.live_component>` in that case because
        # `%Phoenix.LiveView.Component{}` is not handled by
        # `Phoenix.HTML.Safe.to_iodata/1`.
        ~H""

      true ->
        ~H"""
        <.live_component
          module={ContractWeb.Components.CommandPalette}
          id="cmd-k-palette"
          current_scope={@current_scope}
        />
        """
    end
  end

  defp controller_render?, do: Process.get(:plug_masked_csrf_token) != nil

  # --- LiveComponent callbacks -------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open?, false)
     |> assign(:query, "")
     |> assign(:selected_index, 0)
     |> assign(:mode, :list)
     |> assign(:info_target, nil)
     |> assign(:results, [])}
  end

  @impl true
  def update(assigns, socket) do
    current_scope = Map.get(assigns, :current_scope)

    socket =
      socket
      |> assign(:id, Map.get(assigns, :id, "cmd-k-palette"))
      |> assign(:current_scope, current_scope)
      |> assign(:available_commands, available_commands(current_scope))

    # `:initial_open?` is a test-only assign — set it from `render_component`
    # to force the modal open without simulating the Cmd+K keydown.
    socket =
      case Map.get(assigns, :initial_open?, false) do
        true -> assign(socket, :open?, true)
        _ -> socket
      end

    socket =
      case Map.get(assigns, :initial_mode) do
        nil -> socket
        mode -> assign(socket, :mode, mode)
      end

    socket =
      case Map.get(assigns, :initial_query) do
        nil -> socket
        q -> assign(socket, :query, q)
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    if socket.assigns.open? do
      {:noreply, close(socket)}
    else
      {:noreply, open(socket)}
    end
  end

  def handle_event("close", _params, socket) do
    {:noreply, close(socket)}
  end

  def handle_event("query", %{"value" => value}, socket) do
    filtered = filter_commands(socket.assigns.available_commands, value)

    {:noreply,
     socket
     |> assign(:query, value)
     |> assign(:selected_index, 0)
     |> assign(:filtered, filtered)}
  end

  def handle_event("key", params, socket) do
    case Map.get(params, "key") do
      "Escape" ->
        case socket.assigns.mode do
          :list -> {:noreply, close(socket)}
          _ -> {:noreply, back_to_list(socket)}
        end

      "ArrowDown" ->
        list = filter_commands(socket.assigns.available_commands, socket.assigns.query)
        max_idx = max(length(list) - 1, 0)
        next_idx = min(socket.assigns.selected_index + 1, max_idx)
        {:noreply, assign(socket, :selected_index, next_idx)}

      "ArrowUp" ->
        prev_idx = max(socket.assigns.selected_index - 1, 0)
        {:noreply, assign(socket, :selected_index, prev_idx)}

      "Enter" ->
        list = filter_commands(socket.assigns.available_commands, socket.assigns.query)

        case Enum.at(list, socket.assigns.selected_index) do
          nil -> {:noreply, socket}
          command -> fire(command, socket)
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("pick", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.available_commands, &(Atom.to_string(&1.id) == id)) do
      nil -> {:noreply, socket}
      command -> fire(command, socket)
    end
  end

  def handle_event("back", _params, socket) do
    {:noreply, back_to_list(socket)}
  end

  def handle_event("law_query", %{"value" => value}, socket) do
    {:noreply, run_law_search(socket, value)}
  end

  def handle_event("doc_query", %{"value" => value}, socket) do
    {:noreply, run_doc_search(socket, value)}
  end

  # --- Render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} phx-hook=".Palette" data-open={to_string(@open?)}>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Palette">
        export default {
          mounted() {
            this.handler = (e) => {
              const isModKey = e.metaKey || e.ctrlKey
              if (isModKey && e.key && e.key.toLowerCase() === "k") {
                e.preventDefault()
                this.pushEventTo(this.el, "toggle", {})
              }
            }
            window.addEventListener("keydown", this.handler)
          },
          destroyed() {
            window.removeEventListener("keydown", this.handler)
          }
        }
      </script>
      <button
        type="button"
        class="btn btn-ghost btn-xs gap-1 font-mono text-base-content/70 hover:text-base-content fixed top-3 right-3 z-40 backdrop-blur bg-base-100/70 border border-base-200/50"
        phx-click="toggle"
        phx-target={@myself}
        aria-label="Open command palette"
        data-role="palette-trigger"
      >
        <span>⌘K</span>
      </button>

      <div
        :if={@open?}
        id={"#{@id}-modal"}
        class="modal modal-open"
        role="dialog"
        aria-modal="true"
        aria-label="Command palette"
      >
        <div
          id={"#{@id}-keys-escape"}
          phx-window-keydown="key"
          phx-key="Escape"
          phx-target={@myself}
        />
        <div
          id={"#{@id}-keys-down"}
          phx-window-keydown="key"
          phx-key="ArrowDown"
          phx-target={@myself}
        />
        <div
          id={"#{@id}-keys-up"}
          phx-window-keydown="key"
          phx-key="ArrowUp"
          phx-target={@myself}
        />
        <div class="modal-backdrop" phx-click="close" phx-target={@myself} />
        <div
          class="modal-box w-[480px] max-w-[90vw] p-0 absolute left-1/2 -translate-x-1/2"
          style="top: 15vh;"
          data-role="palette-box"
        >
          <%= case @mode do %>
            <% :list -> %>
              {render_list(assigns)}
            <% :info -> %>
              {render_info(assigns)}
            <% :search_law -> %>
              {render_search_law(assigns)}
            <% :search_documents -> %>
              {render_search_documents(assigns)}
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp render_list(assigns) do
    assigns =
      assigns
      |> assign(:filtered, filter_commands(assigns.available_commands, assigns.query))
      |> assign(:group_order, @group_order)
      |> assign(:group_label, @group_label)

    ~H"""
    <form
      class="border-b border-base-200 px-3 py-2 flex items-center gap-2"
      phx-change="query"
      phx-submit="key"
      phx-target={@myself}
    >
      <span class="text-base-content/40 text-sm font-mono">⌘K</span>
      <input
        type="text"
        name="value"
        class="input input-ghost input-sm flex-1 focus:outline-none border-none bg-transparent"
        placeholder="Type a command…"
        value={@query}
        phx-debounce="50"
        autofocus
        data-role="palette-input"
      />
      <input type="hidden" name="key" value="Enter" />
    </form>

    <div class="max-h-[50vh] overflow-y-auto py-2" data-role="palette-list">
      <%= if Enum.empty?(@filtered) do %>
        <div class="px-4 py-6 text-center text-sm text-base-content/50">
          No matching commands.
        </div>
      <% else %>
        <%= for group <- @group_order, group_cmds = Enum.filter(@filtered, &(&1.group == group)), group_cmds != [] do %>
          <div class="px-3 pt-2 pb-1 text-xs uppercase tracking-wide text-base-content/60">
            {Map.fetch!(@group_label, group)}
          </div>
          <ul class="mb-1">
            <li :for={cmd <- group_cmds} class="list-none">
              <button
                type="button"
                class={[
                  "w-full text-left px-3 py-2 flex items-center justify-between gap-3 text-sm",
                  selected_class(cmd, @filtered, @selected_index)
                ]}
                phx-click={click_for(cmd, @myself)}
                phx-target={@myself}
                data-cmd-id={cmd.id}
                data-role="palette-row"
              >
                <span class="truncate">{cmd.label}</span>
                <span :if={cmd.hint} class="text-xs text-base-content/50 shrink-0">
                  {cmd.hint}
                </span>
              </button>
            </li>
          </ul>
        <% end %>
      <% end %>
    </div>

    <div class="border-t border-base-200 px-3 py-1.5 text-[10px] text-base-content/40 flex items-center gap-3">
      <span>↑↓ navigate</span>
      <span>↵ select</span>
      <span>esc close</span>
    </div>
    """
  end

  defp render_info(assigns) do
    ~H"""
    <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between">
      <h2 class="text-sm font-semibold">{info_title(@info_target)}</h2>
      <button
        type="button"
        class="btn btn-ghost btn-xs"
        phx-click="back"
        phx-target={@myself}
      >
        Back
      </button>
    </div>
    <div class="px-4 py-3 text-sm text-base-content/80 space-y-2" data-role="palette-info">
      {info_body(@info_target)}
    </div>
    """
  end

  defp render_search_law(assigns) do
    ~H"""
    <form
      class="px-3 py-2 border-b border-base-200 flex items-center gap-2"
      phx-change="law_query"
      phx-submit="law_query"
      phx-target={@myself}
    >
      <span class="text-xs uppercase text-base-content/60 tracking-wide">법령</span>
      <input
        type="text"
        name="value"
        class="input input-ghost input-sm flex-1 focus:outline-none border-none bg-transparent"
        placeholder="Search Korean law…"
        value={@query}
        phx-debounce="200"
        autofocus
      />
      <button type="button" class="btn btn-ghost btn-xs" phx-click="back" phx-target={@myself}>
        Back
      </button>
    </form>
    <div class="max-h-[50vh] overflow-y-auto px-3 py-2 text-sm" data-role="palette-law-results">
      <%= cond do %>
        <% @query == "" -> %>
          <p class="text-base-content/50">Enter a Korean statute or keyword.</p>
        <% match?({:error, _}, @results) -> %>
          <p class="text-error">Search failed — Law MCP unavailable.</p>
        <% match?({:ok, []}, @results) -> %>
          <p class="text-base-content/50">No results.</p>
        <% match?({:ok, _}, @results) -> %>
          <ul class="space-y-1">
            <li :for={item <- elem(@results, 1)} class="border-b border-base-200/60 pb-1">
              {law_label(item)}
            </li>
          </ul>
      <% end %>
    </div>
    """
  end

  defp render_search_documents(assigns) do
    ~H"""
    <form
      class="px-3 py-2 border-b border-base-200 flex items-center gap-2"
      phx-change="doc_query"
      phx-submit="doc_query"
      phx-target={@myself}
    >
      <span class="text-xs uppercase text-base-content/60 tracking-wide">Docs</span>
      <input
        type="text"
        name="value"
        class="input input-ghost input-sm flex-1 focus:outline-none border-none bg-transparent"
        placeholder="Search documents…"
        value={@query}
        phx-debounce="200"
        autofocus
      />
      <button type="button" class="btn btn-ghost btn-xs" phx-click="back" phx-target={@myself}>
        Back
      </button>
    </form>
    <div class="max-h-[50vh] overflow-y-auto px-3 py-2 text-sm" data-role="palette-doc-results">
      <%= cond do %>
        <% @query == "" -> %>
          <p class="text-base-content/50">Type to search your documents.</p>
        <% @results == [] -> %>
          <p class="text-base-content/50">No documents matched.</p>
        <% true -> %>
          <ul class="space-y-1">
            <li :for={doc <- @results} class="border-b border-base-200/60 pb-1">
              {doc[:title] || inspect(doc)}
            </li>
          </ul>
      <% end %>
    </div>
    """
  end

  # --- Click / action dispatch -----------------------------------------

  defp click_for(%Command{action: {:navigate, path}}, _target) do
    JS.navigate(path)
  end

  defp click_for(%Command{id: id}, target) do
    JS.push("pick", value: %{id: Atom.to_string(id)}, target: target)
  end

  defp fire(%Command{action: {:navigate, path}} = _cmd, socket) do
    {:noreply,
     socket
     |> close()
     |> push_navigate(to: path)}
  end

  defp fire(%Command{action: {:emit, kind, payload}} = _cmd, socket) do
    # `kind` is the browser-event name we push (always
    # `:command_palette_picked` today; left polymorphic for future
    # commands). `payload` already carries `action_kind` per
    # SPEC.md §12 routing — Studio LV (Wave 3C1) reads
    # `payload.action_kind` to dispatch.
    {:noreply,
     socket
     |> close()
     |> push_event(Atom.to_string(kind), payload)}
  end

  defp fire(%Command{action: {:mode, :info, target}}, socket) do
    {:noreply,
     socket
     |> assign(:mode, :info)
     |> assign(:info_target, target)
     |> assign(:results, [])
     |> assign(:query, "")}
  end

  defp fire(%Command{action: {:mode, :search_law}}, socket) do
    {:noreply,
     socket
     |> assign(:mode, :search_law)
     |> assign(:results, [])
     |> assign(:query, "")}
  end

  defp fire(%Command{action: {:mode, :search_documents}}, socket) do
    {:noreply,
     socket
     |> assign(:mode, :search_documents)
     |> assign(:results, [])
     |> assign(:query, "")}
  end

  defp fire(_cmd, socket), do: {:noreply, socket}

  defp open(socket) do
    socket
    |> assign(:open?, true)
    |> assign(:mode, :list)
    |> assign(:query, "")
    |> assign(:selected_index, 0)
    |> assign(:results, [])
  end

  defp close(socket) do
    socket
    |> assign(:open?, false)
    |> assign(:mode, :list)
    |> assign(:query, "")
    |> assign(:selected_index, 0)
    |> assign(:info_target, nil)
    |> assign(:results, [])
  end

  defp back_to_list(socket) do
    socket
    |> assign(:mode, :list)
    |> assign(:info_target, nil)
    |> assign(:query, "")
    |> assign(:selected_index, 0)
    |> assign(:results, [])
  end

  # --- Search backends -------------------------------------------------

  defp run_law_search(socket, "") do
    socket
    |> assign(:query, "")
    |> assign(:results, [])
  end

  defp run_law_search(socket, query) do
    results = LawMCP.search_law(query, [])

    socket
    |> assign(:query, query)
    |> assign(:results, results)
  end

  # Routes through Contract.Studio.search_documents/2 (Wave 4 —
  # backed by Contract.Documents.search/3). Tolerates the documents
  # table not existing yet by returning [] on DB errors.
  defp run_doc_search(socket, "") do
    socket
    |> assign(:query, "")
    |> assign(:results, [])
  end

  defp run_doc_search(socket, query) do
    socket
    |> assign(:query, query)
    |> assign(:results, search_documents(socket.assigns.current_scope, query))
  end

  @doc """
  Public for tests. Routes a query through `Contract.Studio.search_documents/2`
  with a defensive rescue so test envs without the documents migration
  see `[]` rather than a 500.
  """
  def search_documents(scope, query) do
    Contract.Studio.search_documents(scope, query)
  rescue
    Postgrex.Error -> []
    DBConnection.ConnectionError -> []
  end

  # Backwards-compat shim — pre-Wave-4 callers used search_documents_stub/2.
  @doc false
  def search_documents_stub(scope, query), do: search_documents(scope, query)

  # --- Command catalog -------------------------------------------------

  @doc """
  Returns the persona-filtered command list for the given scope.

  Filtering rules:

    * `scopes_required` is the list of perm atoms a command needs. A
      command is dropped if any required perm is missing from
      `scope.perms`.

    * Documents-group commands additionally require `scope.matter` to be
      non-nil — the palette is global but Studio-only commands hide on
      pages without a matter.
  """
  @spec available_commands(map() | nil) :: [Command.t()]
  def available_commands(scope) do
    perms = scope_perms(scope)
    matter = scope_matter(scope)

    all_commands()
    |> Enum.filter(fn cmd ->
      perms_ok?(cmd, perms) and group_ok?(cmd, matter)
    end)
  end

  defp scope_perms(%{perms: perms}) when is_list(perms), do: perms
  defp scope_perms(_), do: []

  defp scope_matter(%{matter: matter}) when not is_nil(matter), do: matter
  defp scope_matter(_), do: nil

  defp perms_ok?(%Command{scopes_required: []}, _perms), do: true

  defp perms_ok?(%Command{scopes_required: required}, perms) do
    Enum.all?(required, &(&1 in perms))
  end

  defp group_ok?(%Command{group: :documents}, nil), do: false
  defp group_ok?(_cmd, _matter), do: true

  defp all_commands do
    [
      # --- Navigation
      %Command{
        id: :nav_dashboard,
        label: "Go to dashboard",
        hint: "/dashboard",
        action: {:navigate, "/dashboard"},
        group: :navigation
      },
      %Command{
        id: :nav_landing,
        label: "Go to landing",
        hint: "/",
        action: {:navigate, "/"},
        group: :navigation
      },
      %Command{
        id: :nav_settings,
        label: "Account settings",
        hint: "/users/settings",
        action: {:navigate, "/users/settings"},
        group: :navigation
      },

      # --- Documents (Studio-only; gated by perms)
      %Command{
        id: :doc_set_type,
        label: "Set contract type…",
        hint: "current document",
        action: {:emit, :command_palette_picked, %{action_kind: "set_contract_type"}},
        group: :documents,
        scopes_required: [:type_change]
      },
      %Command{
        id: :doc_request_export,
        label: "Request export…",
        hint: "PDF / DOCX",
        action: {:emit, :command_palette_picked, %{action_kind: "request_export"}},
        group: :documents,
        scopes_required: [:export]
      },
      %Command{
        id: :doc_revoke_last,
        label: "Revoke last change",
        hint: "current document",
        action: {:emit, :command_palette_picked, %{action_kind: "revoke_change"}},
        group: :documents,
        scopes_required: [:revoke]
      },

      # --- Search
      %Command{
        id: :search_documents,
        label: "Search documents…",
        hint: "local index",
        action: {:mode, :search_documents},
        group: :search
      },
      %Command{
        id: :search_law,
        label: "Search Korean law…",
        hint: "법제처",
        action: {:mode, :search_law},
        group: :search
      },

      # --- Help
      %Command{
        id: :help_agent,
        label: "What can the agent do?",
        hint: nil,
        action: {:mode, :info, :agent},
        group: :help
      },
      %Command{
        id: :help_shortcuts,
        label: "Keyboard shortcuts",
        hint: nil,
        action: {:mode, :info, :shortcuts},
        group: :help
      }
    ]
  end

  # --- Filter / fuzzy ---------------------------------------------------

  @doc """
  Filters `commands` by `query` using a pure-Elixir subsequence matcher.

  Scoring rules:

    * empty query → return everything in catalog order.
    * a command matches iff every character of `query` appears in its
      label in order (case-insensitive).
    * score = (number of matched chars) − (label length / 100). Longer
      labels rank slightly lower to break ties in favor of tighter
      matches (e.g. "go" matches both "Go to landing" and "Go to
      dashboard" — the shorter wins on a tie).
  """
  @spec filter_commands([Command.t()], String.t()) :: [Command.t()]
  def filter_commands(commands, query) when is_binary(query) do
    q = String.downcase(String.trim(query))

    case q do
      "" ->
        commands

      _ ->
        commands
        |> Enum.map(fn cmd -> {cmd, score(cmd.label, q)} end)
        |> Enum.filter(fn {_, score} -> score != nil end)
        |> Enum.sort_by(fn {_, score} -> -score end)
        |> Enum.map(fn {cmd, _} -> cmd end)
    end
  end

  @doc false
  @spec score(String.t(), String.t()) :: float() | nil
  def score(label, query) do
    label_chars = label |> String.downcase() |> String.graphemes()
    query_chars = String.graphemes(query)

    case consume(label_chars, query_chars, 0) do
      nil -> nil
      matched -> matched - String.length(label) / 100.0
    end
  end

  defp consume(_chars, [], matched), do: matched
  defp consume([], _q, _matched), do: nil

  defp consume([c | rest_chars], [c | rest_q], matched),
    do: consume(rest_chars, rest_q, matched + 1)

  defp consume([_other | rest_chars], q, matched),
    do: consume(rest_chars, q, matched)

  # --- Selection class --------------------------------------------------

  defp selected_class(cmd, filtered, selected_index) do
    case Enum.at(filtered, selected_index) do
      %Command{id: id} when id == cmd.id -> "bg-primary/10 text-base-content"
      _ -> "hover:bg-base-200/60"
    end
  end

  # --- Help-panel copy --------------------------------------------------

  defp info_title(:agent), do: "What can the agent do?"
  defp info_title(:shortcuts), do: "Keyboard shortcuts"
  defp info_title(_), do: "Info"

  defp info_body(assigns_target) do
    case assigns_target do
      :agent -> agent_help()
      :shortcuts -> shortcuts_help()
      _ -> nil
    end
  end

  defp agent_help do
    assigns = %{}

    ~H"""
    <p>
      The Contract Studio agent grades draft clauses, drafts replacement
      language, verifies Korean-law citations via 법제처, and writes its
      reasoning into the document's change history. Every agent change is
      provenance-logged and revocable.
    </p>
    <p class="text-xs text-base-content/60">
      Run the agent from the ChatRail — the palette only ships navigation
      and search. See SPEC §11 for the StudioLive protocol the agent
      speaks.
    </p>
    """
  end

  defp shortcuts_help do
    assigns = %{}

    ~H"""
    <ul class="space-y-1">
      <li>
        <kbd class="kbd kbd-sm">⌘</kbd> <kbd class="kbd kbd-sm">K</kbd>
        — open this palette (Ctrl+K on Linux/Windows).
      </li>
      <li>
        <kbd class="kbd kbd-sm">⌘</kbd> <kbd class="kbd kbd-sm">↵</kbd>
        — commit / fire the focused action (Studio).
      </li>
      <li>
        <kbd class="kbd kbd-sm">⌘</kbd> <kbd class="kbd kbd-sm">Z</kbd>
        — revoke the last change (Studio).
      </li>
      <li>
        <kbd class="kbd kbd-sm">↑</kbd> / <kbd class="kbd kbd-sm">↓</kbd>
        — move selection inside the palette.
      </li>
      <li>
        <kbd class="kbd kbd-sm">↵</kbd>
        — fire the selected command.
      </li>
      <li>
        <kbd class="kbd kbd-sm">Esc</kbd>
        — close the palette / step back from a sub-panel.
      </li>
    </ul>
    <p class="text-xs text-base-content/60">
      The agent's StudioLive protocol is documented in SPEC §11.
    </p>
    """
  end

  # --- Law-result label -------------------------------------------------

  defp law_label(%{"title" => t}) when is_binary(t), do: t
  defp law_label(%{"law_name" => n}) when is_binary(n), do: n
  defp law_label(%{"name" => n}) when is_binary(n), do: n
  defp law_label(other), do: inspect(other)
end
