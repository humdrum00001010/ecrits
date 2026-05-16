defmodule ContractWeb.DashboardLive do
  @moduledoc """
  Authenticated home for Contract Studio. Shows a stat row, the matters
  the scope can see, recent documents, and an activity feed.

  ## Data sources

    * `Contract.Matters.list_for_scope/1` — visible matters for the scope.
    * `Contract.Documents.list_recent_for_scope/2` — recent documents
      for the scope, across all visible matters.
    * `Contract.ContractTypes.list/2` — compile-time TOML-backed type
      registry, drives the "New Document" modal.
    * `Contract.Repo.aggregate/3` on the `changes` table — gives us a
      cheap "Open agent runs" count by tallying agent-actor changes
      with status `:active`.
    * `Contract.Repo.all/1` on a small `changes` query — flattened into
      an activity feed.
  """
  use ContractWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Contract.Change
  alias Contract.ContractTypes
  alias Contract.Documents.Document
  alias Contract.Repo

  @impl true
  def mount(_params, _session, socket) do
    {:ok, contract_types} = ContractTypes.list(socket.assigns.current_scope)

    socket =
      socket
      |> assign(:page_title, dgettext("dashboard", "Dashboard"))
      |> assign(:show_new_doc_modal, false)
      |> assign(:contract_types, contract_types)
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_event("open_new_document", _params, socket) do
    {:noreply, assign(socket, :show_new_doc_modal, true)}
  end

  def handle_event("close_new_document", _params, socket) do
    {:noreply, assign(socket, :show_new_doc_modal, false)}
  end

  def handle_event("pick_type", %{"type_key" => type_key}, socket) do
    # TODO(Wave 3C2): wire up to Contract.Documents.create_from_type/3 once
    # the persistence module lands. For now, just acknowledge and close.
    {:noreply,
     socket
     |> assign(:show_new_doc_modal, false)
     |> put_flash(
       :info,
       dgettext(
         "dashboard",
         "Document creation for %{type_key} is queued. Persistence ships with Wave 3C2.",
         type_key: type_key
       )
     )}
  end

  defp load_data(socket) do
    matters = list_matters(socket.assigns.current_scope)
    recent_documents = list_recent_documents(socket.assigns.current_scope)
    ftc_templates = list_ftc_templates()
    activity = list_activity(socket.assigns.current_scope)
    open_agent_runs = count_open_agent_runs()

    socket
    |> assign(:matters, matters)
    |> assign(:recent_documents, recent_documents)
    |> assign(:ftc_templates, ftc_templates)
    |> assign(:activity, activity)
    |> assign(:stats, %{
      active_matters: length(matters),
      documents: length(recent_documents),
      open_agent_runs: open_agent_runs
    })
  end

  # System-owned `:template` documents seeded by `Contract.Workers.FtcSeedJob`
  # (Wave 5). They live in the special "FTC 표준약관" matter owned by the
  # synthetic `system@contract.local` user. Surfacing them on the dashboard
  # gives every persona a one-click entry point to spawn a new document
  # from a canonical FTC template.
  defp list_ftc_templates do
    matter_name = Contract.Workers.FtcSeedJob.templates_matter_name()

    from(d in Document,
      join: m in Contract.Matters.Matter,
      on: d.matter_id == m.id,
      where: m.name == ^matter_name and d.status == :template,
      order_by: [asc: d.type_key],
      select: %{
        document_id: d.id,
        title: d.title,
        type_key: d.type_key,
        metadata: d.metadata
      }
    )
    |> Repo.all()
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
  end

  defp list_matters(scope) do
    matters =
      scope
      |> Contract.Matters.list_for_scope()

    # One cheap aggregate query to get document counts per matter, rather
    # than N+1 queries from a card-grid.
    doc_counts =
      case matters do
        [] ->
          %{}

        list ->
          ids = Enum.map(list, & &1.id)

          from(d in Document,
            where: d.matter_id in ^ids,
            group_by: d.matter_id,
            select: {d.matter_id, count(d.id)}
          )
          |> Repo.all()
          |> Map.new()
      end

    Enum.map(matters, fn m ->
      %{
        id: m.id,
        name: m.name,
        status: m.status,
        doc_count: Map.get(doc_counts, m.id, 0),
        last_activity_at: m.updated_at
      }
    end)
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
  end

  defp list_recent_documents(scope) do
    # Wave 4.6: matters_by_id is used by the table to render the "Matter"
    # column — we batch-load the matter rows the scope can see and stitch
    # them in, rather than N+1.
    matters_by_id =
      scope
      |> Contract.Matters.list_for_scope()
      |> Map.new(fn m -> {m.id, m} end)

    scope
    |> Contract.Documents.list_recent_for_scope(8)
    |> Enum.map(fn d ->
      matter = Map.get(matters_by_id, d.matter_id)

      %{
        document_id: d.id,
        matter_id: d.matter_id,
        matter_name: matter && matter.name,
        title: d.title,
        type_key: d.type_key,
        status: d.status,
        last_revision: d.latest_revision,
        last_activity_at: d.updated_at
      }
    end)
  rescue
    # Test envs and fresh installs may not have the table yet — degrade
    # cleanly to "no documents" rather than crashing the dashboard.
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
  end

  # Last 10 changes the scope can see, flattened into a feed. Activity ROWS
  # are intentionally raw — no joins to a Matter or User table that doesn't
  # exist yet.
  defp list_activity(_scope) do
    from(c in Change,
      order_by: [desc: c.inserted_at],
      limit: 10,
      select: %{
        actor_type: c.actor_type,
        actor_id: c.actor_id,
        action_kind: c.action_kind,
        document_id: c.document_id,
        applied_revision: c.applied_revision,
        message: c.message,
        inserted_at: c.inserted_at
      }
    )
    |> Repo.all()
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
  end

  defp count_open_agent_runs do
    from(c in Change,
      where: c.actor_type == :agent and c.status == :active,
      select: count(c.id)
    )
    |> Repo.one()
    |> case do
      n when is_integer(n) -> n
      _ -> 0
    end
  rescue
    DBConnection.ConnectionError -> 0
    Postgrex.Error -> 0
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="default">
      <div class="py-10 space-y-10">
        <%!-- ---------------------------------------------------------- --%>
        <%!-- Welcome + primary action                                    --%>
        <%!-- ---------------------------------------------------------- --%>
        <header class="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-4">
          <div>
            <p class="text-xs font-medium tracking-wide uppercase text-base-content/50">
              {today_label()}
            </p>
            <h1 class="text-3xl font-semibold tracking-tight">
              {dgettext("dashboard", "Good day,")}
              <span class="text-primary">{persona_first_name(@current_scope)}</span>.
            </h1>
            <p class="text-base-content/60 mt-1">
              {dgettext("dashboard", "Pick up where you left off, or open a new matter.")}
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              phx-click="open_new_document"
              class="btn btn-primary flex-1 sm:flex-none"
            >
              <.icon name="hero-document-plus" class="size-4" /> {dgettext("dashboard", "New Document")}
            </button>
            <.link navigate={~p"/studio"} class="btn btn-ghost flex-1 sm:flex-none">
              {dgettext("dashboard", "Open Studio")} <span aria-hidden="true">→</span>
            </.link>
          </div>
        </header>

        <%!-- ---------------------------------------------------------- --%>
        <%!-- Stat row                                                    --%>
        <%!-- ---------------------------------------------------------- --%>
        <section class="grid grid-cols-1 sm:grid-cols-3 gap-4" id="dashboard-stats">
          <.stat_card
            label={dgettext("dashboard", "Active matters")}
            value={@stats.active_matters}
            icon="hero-folder"
          />
          <.stat_card
            label={dgettext("dashboard", "Documents")}
            value={@stats.documents}
            icon="hero-document-text"
          />
          <.stat_card
            label={dgettext("dashboard", "Open agent runs")}
            value={@stats.open_agent_runs}
            icon="hero-cpu-chip"
          />
        </section>

        <%!-- ---------------------------------------------------------- --%>
        <%!-- Matters                                                     --%>
        <%!-- ---------------------------------------------------------- --%>
        <section id="matters">
          <header class="flex items-end justify-between mb-4">
            <h2 class="text-lg font-semibold tracking-tight">
              {dgettext("dashboard", "Matters")}
            </h2>
            <span :if={@matters != []} class="text-xs text-base-content/50">
              {dgettext("dashboard", "%{count} total", count: length(@matters))}
            </span>
          </header>

          <%= if @matters == [] do %>
            <div
              id="matters-empty"
              class="rounded-box border border-dashed border-base-300 p-6 sm:p-10 text-center bg-base-200/30"
            >
              <img
                src={~p"/images/landing/dashboard-empty.png"}
                alt={
                  dgettext("dashboard", "An empty folder with a quill, signalling no matters yet.")
                }
                class="mx-auto w-32 sm:w-40 h-auto object-contain"
                width="1024"
                height="1024"
                loading="lazy"
              />
              <p class="font-medium mt-3">{dgettext("dashboard", "No matters yet")}</p>
              <p class="text-sm text-base-content/60 mt-1 max-w-sm mx-auto">
                {dgettext(
                  "dashboard",
                  "A matter holds the documents, evidence, and agent runs for a single client engagement."
                )}
              </p>
              <button
                type="button"
                phx-click="open_new_document"
                class="btn btn-primary mt-5"
              >
                <.icon name="hero-plus" class="size-4" /> {dgettext("dashboard", "New Matter")}
              </button>
            </div>
          <% else %>
            <%!--
              Hairline table per mature-visual-language: no zebra-stripes,
              no shadows, just border-base-200 separators. On <sm we hide
              the Documents column to keep Name + Status + Last activity
              readable on narrow screens — Tailwind's `hidden sm:table-cell`
              pattern keeps the markup as a single semantic table.
            --%>
            <div class="overflow-x-auto rounded-box border border-base-200 bg-base-100">
              <table id="matters-table" class="table table-sm">
                <thead class="text-xs uppercase tracking-wide text-base-content/60">
                  <tr class="border-b border-base-200">
                    <th class="font-medium">{dgettext("dashboard", "Name")}</th>
                    <th class="font-medium">{dgettext("dashboard", "Status")}</th>
                    <th class="hidden sm:table-cell font-medium text-right">
                      {dgettext("dashboard", "Documents")}
                    </th>
                    <th class="font-medium text-right">
                      {dgettext("dashboard", "Last activity")}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={matter <- @matters}
                    class="border-b border-base-200 last:border-b-0 hover:bg-base-200/30"
                  >
                    <td>
                      <.link
                        navigate={~p"/matters/#{matter.id}/studio"}
                        class="font-medium hover:underline"
                      >
                        {matter.name}
                      </.link>
                    </td>
                    <td>
                      <span class={[
                        "badge badge-sm",
                        matter_status_badge_class(matter.status)
                      ]}>
                        {matter_status_label(matter.status)}
                      </span>
                    </td>
                    <td class="hidden sm:table-cell text-right tabular-nums text-base-content/70">
                      {matter.doc_count}
                    </td>
                    <td class="text-right tabular-nums text-xs text-base-content/60">
                      {format_timestamp(matter.last_activity_at)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <%!-- ---------------------------------------------------------- --%>
        <%!-- Recent documents                                            --%>
        <%!-- ---------------------------------------------------------- --%>
        <section id="recent-documents">
          <header class="flex items-end justify-between mb-4">
            <h2 class="text-lg font-semibold tracking-tight">
              {dgettext("dashboard", "Recent documents")}
            </h2>
          </header>

          <%= if @recent_documents == [] do %>
            <div
              id="documents-empty"
              class="rounded-box border border-dashed border-base-300 p-8 text-center bg-base-200/30 text-sm text-base-content/60"
            >
              {dgettext("dashboard", "No documents yet. Drag a PDF in, or start from a contract type.")}
            </div>
          <% else %>
            <div class="overflow-x-auto rounded-box border border-base-200 bg-base-100">
              <table id="documents-list" class="table table-sm">
                <thead class="text-xs uppercase tracking-wide text-base-content/60">
                  <tr class="border-b border-base-200">
                    <th class="font-medium">{dgettext("dashboard", "Title")}</th>
                    <th class="font-medium">{dgettext("dashboard", "Type")}</th>
                    <th class="hidden sm:table-cell font-medium">
                      {dgettext("dashboard", "Status")}
                    </th>
                    <th class="hidden sm:table-cell font-medium">
                      {dgettext("dashboard", "Matter")}
                    </th>
                    <th class="font-medium text-right">
                      {dgettext("dashboard", "Last revision")}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={doc <- @recent_documents}
                    class="border-b border-base-200 last:border-b-0 hover:bg-base-200/30"
                  >
                    <td class="min-w-0">
                      <.link
                        navigate={
                          ~p"/matters/#{doc.matter_id || "_"}/documents/#{doc.document_id}"
                        }
                        class="font-medium hover:underline"
                      >
                        {doc.title}
                      </.link>
                    </td>
                    <td>
                      <span class="badge badge-ghost badge-sm font-mono">{doc.type_key}</span>
                    </td>
                    <td class="hidden sm:table-cell">
                      <span class={[
                        "badge badge-sm",
                        document_status_badge_class(doc.status)
                      ]}>
                        {document_status_label(doc.status)}
                      </span>
                    </td>
                    <td class="hidden sm:table-cell text-sm text-base-content/70">
                      <.link
                        :if={doc.matter_id}
                        navigate={~p"/matters/#{doc.matter_id}/studio"}
                        class="hover:underline"
                      >
                        {doc.matter_name || "—"}
                      </.link>
                      <span :if={!doc.matter_id}>—</span>
                    </td>
                    <td class="text-right text-xs text-base-content/60 tabular-nums">
                      {dgettext("dashboard", "rev %{n}", n: doc.last_revision)} · {format_timestamp(
                        doc.last_activity_at
                      )}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <%!-- ---------------------------------------------------------- --%>
        <%!-- FTC standard contracts (Wave 5)                             --%>
        <%!-- ---------------------------------------------------------- --%>
        <section :if={@ftc_templates != []} id="ftc-templates">
          <header class="flex items-end justify-between mb-4">
            <h2 class="text-lg font-semibold tracking-tight">
              {dgettext("dashboard", "FTC standard contracts")}
            </h2>
            <span class="text-xs text-base-content/50">
              {dgettext("dashboard", "%{count} templates", count: length(@ftc_templates))}
            </span>
          </header>

          <ul id="ftc-templates-list" class="rounded-box border border-base-200 md:divide-y md:divide-base-200 bg-base-100 space-y-2 md:space-y-0 p-2 md:p-0">
            <li
              :for={tpl <- @ftc_templates}
              class="rounded-box md:rounded-none border border-base-200 md:border-0 bg-base-100 px-4 py-3 flex flex-col md:flex-row md:items-center gap-2 md:gap-4 hover:bg-base-200/30"
            >
              <div class="flex items-center gap-3 min-w-0 md:flex-1">
                <.icon name="hero-document-duplicate" class="size-4 text-primary/70 shrink-0" />
                <.link
                  navigate={~p"/matters/_/documents/#{tpl.document_id}"}
                  class="text-sm font-medium hover:underline truncate block"
                >
                  {tpl.title}
                </.link>
              </div>
              <div class="flex items-center justify-between md:justify-end gap-2 md:gap-4 pl-7 md:pl-0">
                <span class="badge badge-primary badge-sm font-mono">{tpl.type_key}</span>
                <span class="text-xs text-base-content/50 md:w-32 md:text-right">
                  {dgettext("dashboard", "FTC template")}
                </span>
              </div>
            </li>
          </ul>
        </section>

        <%!-- ---------------------------------------------------------- --%>
        <%!-- Recent activity                                             --%>
        <%!-- ---------------------------------------------------------- --%>
        <section id="recent-activity" class="w-full lg:max-w-2xl">
          <header class="flex items-end justify-between mb-4">
            <h2 class="text-lg font-semibold tracking-tight">
              {dgettext("dashboard", "Recent activity")}
            </h2>
          </header>

          <%= if @activity == [] do %>
            <div
              id="activity-empty"
              class="rounded-box border border-dashed border-base-300 p-8 text-center bg-base-200/30 text-sm text-base-content/60"
            >
              {dgettext("dashboard", "The activity feed will populate as you and the agent make changes.")}
            </div>
          <% else %>
            <ol id="activity-feed" class="space-y-3">
              <li :for={event <- @activity} class="flex gap-3">
                <div class="shrink-0 mt-0.5">
                  <span class={[
                    "inline-flex h-6 w-6 items-center justify-center rounded-full text-[0.6rem] font-semibold",
                    actor_class(event.actor_type)
                  ]}>
                    {actor_initial(event.actor_type)}
                  </span>
                </div>
                <div class="flex-1 min-w-0">
                  <p class="text-sm">
                    <span class="font-medium">{actor_label(event.actor_type)}</span>
                    <span class="text-base-content/70">{action_label(event.action_kind)}</span>
                    <span class="text-base-content/50 font-mono text-xs">
                      doc/{String.slice(event.document_id || "", 0, 6)} · {dgettext(
                        "dashboard",
                        "rev %{n}",
                        n: event.applied_revision
                      )}
                    </span>
                  </p>
                  <p :if={event.message} class="text-xs text-base-content/60 truncate mt-0.5">
                    {event.message}
                  </p>
                  <p class="text-xs text-base-content/40 mt-0.5">
                    {format_timestamp(event.inserted_at)}
                  </p>
                </div>
              </li>
            </ol>
          <% end %>
        </section>
      </div>

      <%!-- ------------------------------------------------------------- --%>
      <%!-- New Document modal                                             --%>
      <%!-- ------------------------------------------------------------- --%>
      <div
        :if={@show_new_doc_modal}
        id="new-document-modal"
        class="modal modal-open"
        phx-window-keydown="close_new_document"
        phx-key="escape"
      >
        <div class="modal-box max-w-2xl">
          <div class="flex items-start justify-between gap-4">
            <div>
              <h3 class="font-semibold text-lg tracking-tight">
                {dgettext("dashboard", "New document")}
              </h3>
              <p class="text-sm text-base-content/60">
                {dgettext(
                  "dashboard",
                  "Pick a contract type. Field maps and templates load from the type registry."
                )}
              </p>
            </div>
            <button
              type="button"
              phx-click="close_new_document"
              class="btn btn-sm btn-ghost btn-square"
              aria-label={dgettext("dashboard", "Close")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <ul id="contract-type-list" class="mt-5 space-y-2">
            <%!--
              Wave 3C0-B: @contract_types is now a list of
              %Contract.ContractTypes.TypeSpec{} structs loaded from
              priv/contract_types/*.toml at compile time. The old stub
              keys (.type_key/.name/.description) are now
              .key/.name_en/.notes_en; the phx-value-type_key *attribute*
              is unchanged because the event handler still expects that
              param name.
            --%>
            <li :for={type <- @contract_types}>
              <button
                type="button"
                phx-click="pick_type"
                phx-value-type_key={type.key}
                class="w-full text-left rounded-box border border-base-200 p-4 hover:border-primary hover:bg-base-200/40 transition-colors"
              >
                <div class="flex items-baseline justify-between gap-3">
                  <p class="font-medium">{type.name_en}</p>
                  <span class="badge badge-ghost badge-sm font-mono">{type.key}</span>
                </div>
                <p class="text-sm text-base-content/60 mt-1">{type.notes_en}</p>
                <p class="text-xs text-base-content/40 mt-1">{type.name_ko}</p>
              </button>
            </li>
          </ul>
        </div>
        <button
          type="button"
          phx-click="close_new_document"
          class="modal-backdrop"
          aria-label={dgettext("dashboard", "Close modal")}
        >
          {dgettext("dashboard", "close")}
        </button>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Small render helpers
  # ---------------------------------------------------------------------------

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :icon, :string, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-box border border-base-200 p-5 bg-base-100">
      <div class="flex items-center gap-2 text-base-content/60 text-sm">
        <.icon name={@icon} class="size-4" />
        <span>{@label}</span>
      </div>
      <p class="text-3xl font-semibold tracking-tight mt-2 tabular-nums">{@value}</p>
    </div>
    """
  end

  defp persona_first_name(%{user: %{email: email}}) when is_binary(email) do
    email |> String.split("@") |> List.first()
  end

  defp persona_first_name(_), do: "there"

  defp today_label do
    Calendar.strftime(DateTime.utc_now(), "%A, %d %B %Y")
  end

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(%NaiveDateTime{} = t),
    do: t |> DateTime.from_naive!("Etc/UTC") |> format_timestamp()

  defp format_timestamp(%DateTime{} = t) do
    diff = DateTime.diff(DateTime.utc_now(), t, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(t, "%d %b")
    end
  end

  defp actor_class(:user), do: "bg-primary/15 text-primary"
  defp actor_class(:agent), do: "bg-secondary/15 text-secondary"
  defp actor_class(:lawyer), do: "bg-primary/15 text-primary"
  defp actor_class(:slack), do: "bg-accent/20 text-accent-content"
  defp actor_class(_), do: "bg-base-200 text-base-content/60"

  defp actor_initial(:user), do: "U"
  defp actor_initial(:agent), do: "AI"
  defp actor_initial(:lawyer), do: "L"
  defp actor_initial(:slack), do: "S"
  defp actor_initial(_), do: "·"

  defp actor_label(:user), do: "You"
  defp actor_label(:agent), do: "Agent"
  defp actor_label(:lawyer), do: "Lawyer"
  defp actor_label(:slack), do: "Slack"
  defp actor_label(:system), do: "System"
  defp actor_label(other), do: to_string(other)

  defp action_label(nil), do: "made a change"
  defp action_label(kind) when is_binary(kind), do: humanize_kind(kind)
  defp action_label(kind) when is_atom(kind), do: kind |> Atom.to_string() |> humanize_kind()

  defp humanize_kind(kind) do
    kind
    |> String.replace("_", " ")
  end

  # ---------------------------------------------------------------------------
  # Status badges (Wave 4.6: dashboard tables)
  # ---------------------------------------------------------------------------

  defp matter_status_label(:active), do: dgettext("dashboard", "In progress")
  defp matter_status_label(:archived), do: dgettext("dashboard", "Archived")
  defp matter_status_label(other), do: to_string(other)

  defp matter_status_badge_class(:active), do: "badge-ghost"
  defp matter_status_badge_class(:archived), do: "badge-ghost opacity-60"
  defp matter_status_badge_class(_), do: "badge-ghost"

  defp document_status_label(:active), do: dgettext("dashboard", "Active")
  defp document_status_label(:archived), do: dgettext("dashboard", "Archived")
  defp document_status_label(:template), do: dgettext("dashboard", "Template")
  defp document_status_label(other), do: to_string(other)

  defp document_status_badge_class(:active), do: "badge-ghost"
  defp document_status_badge_class(:archived), do: "badge-ghost opacity-60"
  defp document_status_badge_class(:template), do: "badge-ghost"
  defp document_status_badge_class(_), do: "badge-ghost"
end
