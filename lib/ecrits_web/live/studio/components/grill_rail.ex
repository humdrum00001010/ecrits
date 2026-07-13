defmodule EcritsWeb.Live.Studio.Components.GrillRail do
  @moduledoc """
  Sub-LiveComponent of `ChatRail`. Renders unanswered `Mark{intent: :ask}`
  records emitted by an agent grill turn as inline question prompts, each
  with its own answer input. Answered ask-marks collapse to a single-line
  summary.

  ## Assigns

    * `:id` — DOM id.
    * `:state` — `%Ecrits.Studio.ChatRailState{}` containing the mark records,
      permissions, current agent run, and layout. The parent
      `ChatRail` has filtered to the current `agent_run_id`. The component
      treats both `%Ecrits.MarkInput{}` structs and plain maps the same
      way; it pulls out `:id`, `:text`, `:data`, `:intent`. Marks with
      `intent: :ask` and no `data["answer"]` render as **prompts**; those
      with an answer collapse to a Q→A summary line.
      The component reads the state's permissions
      `:perms` to gate the answer flow:
        - `:agent_supervised` (perms include `:agent_run` but not `:write`
          — for the purposes of this rail we use the looser "no `:write`"
          rule) sees questions **read-only**.
        - `:viewer` (perms == `[:read]`) sees **nothing**: the component
          returns an empty fragment.
        - All other personas (`:lawyer`, `:paralegal`, `:admin`) get the
          full submit input.
      The current agent run disables submit until the run exists.
      The state's layout is `:default` or `:mobile_full`. The mobile variant uses
      tighter padding and stacks the rationale below the question text.

  ## Event contract

  The submit button is `type="button"` (per Wave 3C1's binding rule —
  components never construct `Action`s directly) and fires
  `phx-click="chat.submit"` to the parent `DocumentLive`. The values:

      %{
        "grill_response" => %{"mark_id" => mark_id, "answer" => answer},
        "message" => answer
      }

  `DocumentLive.event_to_action/3` routes `"chat.submit"` into an
  `%Command{kind: :chat_message}` with the `grill_response` lifted into
  `payload`.

  Because the answer textarea lives inside this LiveComponent, we keep
  per-mark draft state in the component's `assigns[:drafts]` map keyed by
  mark id, and `handle_event("draft_changed", ...)` updates that map on
  `phx-change`. The actual `chat.submit` event escapes the
  component (no `phx-target={@myself}`) so the parent LV can build the
  Action.
  """

  use EcritsWeb, :live_component

  alias Ecrits.Context
  alias Ecrits.MarkInput
  alias Ecrits.Studio.ChatRailState

  # ---- Attribute contract ------------------------------------------------

  attr :id, :string, required: true
  attr :state, :map, required: true

  # ---- Lifecycle ---------------------------------------------------------

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :drafts, %{})}
  end

  @impl true
  def update(%{state: %ChatRailState{}} = assigns, socket) do
    drafts = socket.assigns[:drafts] || %{}

    # Drop drafts whose marks have since been answered or removed so the
    # map can't grow unboundedly across a long grill session.
    incoming_ids =
      assigns.state.grill_marks
      |> List.wrap()
      |> Enum.map(&mark_id/1)
      |> MapSet.new()

    drafts =
      drafts
      |> Enum.filter(fn {id, _} -> MapSet.member?(incoming_ids, id) end)
      |> Enum.into(%{})

    socket =
      socket
      |> assign(assigns)
      |> assign(:drafts, drafts)

    {:ok, socket}
  end

  # ---- Local events (draft updates) --------------------------------------

  @impl true
  def handle_event("draft_changed", %{"mark_id" => mark_id, "answer" => answer}, socket) do
    {:noreply, update(socket, :drafts, &Map.put(&1, mark_id, answer))}
  end

  def handle_event("draft_changed", %{"mark_id" => mark_id} = params, socket) do
    answer = params["value"] || ""
    {:noreply, update(socket, :drafts, &Map.put(&1, mark_id, answer))}
  end

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # ---- Render ------------------------------------------------------------

  @impl true
  def render(%{state: %ChatRailState{}} = assigns) do
    perm_mode = perm_mode(assigns.state.permissions)

    assigns =
      assigns
      |> assign(:perm_mode, perm_mode)
      |> assign(:partitioned, partition_marks(assigns.state.grill_marks))

    ~H"""
    <div
      id={@id}
      data-component="grill-rail"
      data-perm-mode={@perm_mode}
      class={[
        "flex flex-col",
        ChatRailState.mobile?(@state) && "px-2 py-2 gap-2",
        not ChatRailState.mobile?(@state) && "px-3 py-3 gap-3",
        empty?(@partitioned) && "hidden",
        @perm_mode == :hidden && "hidden"
      ]}
    >
      <%= if @perm_mode != :hidden and not empty?(@partitioned) do %>
        <h3 class="text-xs font-medium tracking-wide uppercase text-base-content/60">
          {dgettext("studio", "Agent questions")}
        </h3>

        <ul class="flex flex-col gap-2" role="list">
          <li
            :for={mark <- @partitioned.unanswered}
            id={"grill-mark-#{mark_id(mark)}"}
            data-role="grill-ask"
            data-mark-id={mark_id(mark)}
            class="rounded-md border border-base-200 bg-base-100 p-3"
          >
            <p class="font-medium text-sm text-base-content leading-snug">
              {mark_text(mark)}
            </p>

            <p
              :if={rationale(mark)}
              class="mt-1 text-xs text-base-content/70 leading-relaxed"
              data-role="grill-rationale"
            >
              <span class="font-semibold mr-1">
                {dgettext("studio", "Why ask:")}
              </span>{rationale(
                mark
              )}
            </p>

            <%= if @perm_mode == :answer do %>
              <.form
                for={%{}}
                as={:grill_response}
                phx-change="draft_changed"
                phx-target={@myself}
                phx-submit="noop"
                class="mt-2"
              >
                <input type="hidden" name="mark_id" value={mark_id(mark)} />
                <.input
                  type="textarea"
                  id={"grill-mark-#{mark_id(mark)}-answer"}
                  name="answer"
                  value={draft_for(@drafts, mark_id(mark))}
                  label={dgettext("studio", "Your answer")}
                  rows="2"
                  class="w-full textarea textarea-sm"
                  data-role="grill-answer-input"
                  placeholder={dgettext("studio", "Type your answer…")}
                />
              </.form>

              <div class="mt-2 flex justify-end">
                <button
                  type="button"
                  data-role="grill-submit"
                  data-mark-id={mark_id(mark)}
                  phx-click="chat.submit"
                  phx-value-mark_id={mark_id(mark)}
                  phx-value-message={draft_for(@drafts, mark_id(mark))}
                  phx-value-grill_response={
                    Jason.encode!(%{
                      "mark_id" => mark_id(mark),
                      "answer" => draft_for(@drafts, mark_id(mark))
                    })
                  }
                  disabled={
                    String.trim(draft_for(@drafts, mark_id(mark))) == "" or
                      is_nil(@state.agent_run_id)
                  }
                  class="btn btn-sm btn-primary"
                >
                  {dgettext("studio", "Submit")}
                </button>
              </div>
            <% end %>

            <%= if @perm_mode == :readonly do %>
              <p
                class="mt-2 text-xs italic text-base-content/60"
                data-role="grill-readonly-note"
              >
                {dgettext("studio", "Awaiting an answer from a writer.")}
              </p>
            <% end %>
          </li>

          <li
            :for={mark <- @partitioned.answered}
            id={"grill-mark-#{mark_id(mark)}-answered"}
            data-role="grill-answered"
            data-mark-id={mark_id(mark)}
            class="text-xs text-base-content/70 leading-snug border-l-2 border-base-200 pl-2"
          >
            <span class="font-semibold">Q:</span> {mark_text(mark)}
            <span class="mx-1 text-base-content/40">→</span>
            <span class="font-semibold">A:</span> {answer_text(mark)}
          </li>
        </ul>
      <% end %>
    </div>
    """
  end

  # ---- Helpers -----------------------------------------------------------

  @doc """
  Splits the incoming list into `%{unanswered: [...], answered: [...]}`.

  Only marks whose `:intent` is `:ask` are kept (the parent rail may be
  loose about its filtering, so we double-check). A mark is "answered"
  iff its `data` map carries an `"answer"` (or `:answer`) string.
  """
  @spec partition_marks(list()) :: %{unanswered: list(), answered: list()}
  def partition_marks(marks) when is_list(marks) do
    marks
    |> Enum.filter(&ask_intent?/1)
    |> Enum.split_with(&(&1 |> answer_text() |> empty_string?()))
    |> case do
      {unanswered, answered} -> %{unanswered: unanswered, answered: answered}
    end
  end

  def partition_marks(_), do: %{unanswered: [], answered: []}

  @doc """
  Resolves the persona-level render mode from a `%Ecrits.Context{}`.

  The brief's persona table:

    * `:lawyer` / `:paralegal` / `:admin` — perms include `:type_change`.
      → `:answer` (full input + submit).
    * `:agent_supervised` — perms include `:agent_run` but **not**
      `:type_change`. → `:readonly` (questions visible, no submit).
    * `:viewer` — perms `== [:read]`. → `:hidden` (empty render).
    * Anything else (no scope, no perms) → `:hidden`.
  """
  @spec perm_mode(Context.t() | map() | nil) :: :hidden | :readonly | :answer
  def perm_mode(perms) when is_list(perms), do: perm_mode_for_perms(perms)
  def perm_mode(%Context{perms: perms}) when is_list(perms), do: perm_mode_for_perms(perms)
  def perm_mode(%{perms: perms}) when is_list(perms), do: perm_mode_for_perms(perms)
  def perm_mode(_), do: :hidden

  defp perm_mode_for_perms(perms) do
    cond do
      perms == [] or perms == [:read] -> :hidden
      :type_change in perms -> :answer
      :write in perms -> :readonly
      :agent_run in perms -> :readonly
      true -> :hidden
    end
  end

  # ---- Mark accessor helpers (accept structs and maps) -------------------

  @doc false
  # `%MarkInput{}` is an embedded schema with `@primary_key false` — it carries
  # no `:id` field, so its identity is always derived from its contents.
  def mark_id(%MarkInput{} = m), do: derive_id(m)

  def mark_id(%{id: id}) when not is_nil(id), do: to_string(id)
  def mark_id(%{"id" => id}) when not is_nil(id), do: to_string(id)
  def mark_id(other), do: derive_id(other)

  @doc false
  def mark_text(%MarkInput{text: t}) when is_binary(t), do: t
  def mark_text(%{text: t}) when is_binary(t), do: t
  def mark_text(%{"text" => t}) when is_binary(t), do: t
  def mark_text(_), do: ""

  defp rationale(%MarkInput{data: %{} = data}), do: data["rationale"] || data[:rationale]
  defp rationale(%{data: %{} = data}), do: data["rationale"] || data[:rationale]
  defp rationale(%{"data" => %{} = data}), do: data["rationale"] || data[:rationale]
  defp rationale(_), do: nil

  defp answer_text(%MarkInput{data: %{} = data}), do: data["answer"] || data[:answer] || ""
  defp answer_text(%{data: %{} = data}), do: data["answer"] || data[:answer] || ""
  defp answer_text(%{"data" => %{} = data}), do: data["answer"] || data[:answer] || ""
  defp answer_text(_), do: ""

  defp ask_intent?(%MarkInput{intent: :ask}), do: true
  defp ask_intent?(%{intent: :ask}), do: true
  defp ask_intent?(%{"intent" => "ask"}), do: true
  defp ask_intent?(%{"intent" => :ask}), do: true
  defp ask_intent?(_), do: false

  defp draft_for(drafts, mark_id) when is_map(drafts) do
    Map.get(drafts, mark_id, "")
  end

  defp draft_for(_, _), do: ""

  defp empty_string?(""), do: true
  defp empty_string?(s) when is_binary(s), do: String.trim(s) == ""
  defp empty_string?(_), do: false

  defp empty?(%{unanswered: [], answered: []}), do: true
  defp empty?(_), do: false

  defp derive_id(thing), do: "mark-" <> Integer.to_string(:erlang.phash2(thing))
end
