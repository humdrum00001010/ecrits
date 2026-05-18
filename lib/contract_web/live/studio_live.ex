defmodule ContractWeb.StudioLive do
  @moduledoc """
  The one big LiveView. Disposable UI process. Does NOT own document truth.

  See SPEC.md §10–§11 for the design. This module is Wave 3C1's shell
  contract — its assigns shape, dispatch funnel, and `handle_info/2` protocol
  are the seam that all 12 component subagents plug into.

  ## Assigns shape (binding contract)

  Components consume the keys listed below and nothing else. Adding a key
  here is a contract change and requires the shell coordinator to ship a
  follow-up.

      socket.assigns = %{
        # Set by on_mount
        current_scope: %Contract.Context{
          user: %Contract.Accounts.User{},
          tenant: ...,
          perms: [...]
        },

        # Set by mount
        studio_state: %Contract.Studio.State{
          selected_document_id: ...,
          selected_node_id: ...,
          last_seen_revision: ...,
          mode: :no_document | :briefing | :editing | :reviewing,
          chat_open?: true,
          document_picker_open?: false,
          metadata_panel_open?: false,
          migration_panel_open?: false,
          upload_panel_open?: false,
          agent_run_id: nil
        },

        # Derived per-mount
        projection: %{nodes: ..., fields: ..., marks: ..., refs: ...},
        breadcrumbs: [%{label, navigate, current?}],
        page_title: "Studio · <matter_name>",
        reconcile_modal_open?: false,

        # LV streams (preferred over assign for collections, LV 1.1)
        streams: %{
          chat_messages: stream,
          changes: stream,
          toasts: stream
        },

        # Viewport (set by the .Viewport JS hook on connect)
        viewport: :desktop | :mobile,
        preview_modal_open?: false,

        # Reconnect tracking
        last_pubsub_message_at: ...
      }

  ## Dispatch funnel

  `event_to_command/2` is the ONE place UI events become Commands. Components
  fire `phx-click="<event_name>"` and let the shell build the typed action.
  Clauses:

      "rename_document"       → :rename_document
      "set_contract_type"     → :set_contract_type
      "edit_document"         → :edit_document
      "send_chat_message"     → :chat_message
      "revoke_change"         → :revoke_change
      "upload_document"       → :upload_document
      "create_variant"        → :create_converted_variant
      "open_document"         → :open_document
      "duplicate_document"    → :duplicate_document
      "request_export"        → :request_export
      "command_palette_picked" → resolved to the right Command.kind

  Local-only UI events (no Command emitted):

      "toggle_preview", "open_modal", "close_modal", "set_node_focus",
      "viewport_change", "noop"

  ## Protocol messages (§11)

  `handle_info/2` is the LiveView protocol surface. Every message type is
  pattern-matched explicitly. See `handle_protocol_message/2`.
  """

  use ContractWeb, :live_view

  alias Contract.ChatThreads
  alias Contract.Command
  alias Contract.ContractTypes
  alias Contract.Documents
  alias Contract.Studio
  alias ContractWeb.Components.Breadcrumbs
  alias ContractWeb.Components.CommandPalette
  alias ContractWeb.Live.Studio.Components

  @impl true
  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope

    case Studio.open(scope, params) do
      {:ok, {studio_state, projection}} ->
        _ = Studio.subscribe(scope, studio_state.selected_document_id)
        _ = Studio.subscribe_agent(scope, studio_state.agent_run_id)
        _ = maybe_subscribe_test_operation_blocks(scope)

        breadcrumbs = build_breadcrumbs(scope, studio_state, projection)

        socket =
          socket
          |> assign(:current_scope, scope)
          |> assign(:studio_state, studio_state)
          |> assign(:projection, projection)
          |> assign(:current_document, current_document(scope, studio_state))
          |> assign(:breadcrumbs, breadcrumbs)
          |> assign(:page_title, page_title(scope))
          |> assign(:viewport, :desktop)
          |> assign(:chat_rail_hidden?, false)
          |> assign(:other_documents, list_other_documents(scope, studio_state))
          |> assign(:preview_modal_open?, false)
          |> assign(:reconcile_modal_open?, false)
          |> assign(:reconcile_request, nil)
          |> assign(:migration_plan, nil)
          |> assign(:migration_plan_id, nil)
          |> assign(:migration_plan_refined?, false)
          |> assign(:migration_target, nil)
          |> assign(:field_strategies, nil)
          |> assign(:last_pubsub_message_at, nil)
          |> allow_upload(:document_upload,
            accept: :any,
            max_entries: 1,
            max_file_size: 50_000_000
          )
          |> stream_configure(:chat_messages, dom_id: &"chat-msg-#{&1.id}")
          |> then(fn s ->
            visible = ChatThreads.list_visible_messages(scope, studio_state)

            s
            |> stream(:chat_messages, visible)
            |> maybe_dispatch_grill_seed(visible)
          end)
          |> stream_configure(:changes, dom_id: &"change-#{&1.id}")
          |> stream(:changes, [])
          |> stream_configure(:toasts, dom_id: &"toast-#{&1.id}")
          |> stream(:toasts, [])
          |> recompute_grill_assigns()

        {:ok, socket}

      {:error, reason} ->
        socket =
          socket
          |> put_flash(:error, "Could not load Studio: #{inspect(reason)}")
          |> assign(:studio_state, %Contract.Studio.State{mode: :no_document})
          |> assign(:projection, empty_projection())
          |> assign(:current_document, nil)
          |> assign(:breadcrumbs, build_breadcrumbs(scope, nil, nil))
          |> assign(:page_title, "Studio")
          |> assign(:viewport, :desktop)
          |> assign(:chat_rail_hidden?, false)
          |> assign(:other_documents, list_other_documents(scope, %{selected_document_id: nil}))
          |> assign(:preview_modal_open?, false)
          |> assign(:reconcile_modal_open?, false)
          |> assign(:reconcile_request, nil)
          |> assign(:migration_plan, nil)
          |> assign(:migration_plan_id, nil)
          |> assign(:migration_plan_refined?, false)
          |> assign(:migration_target, nil)
          |> assign(:field_strategies, nil)
          |> assign(:last_pubsub_message_at, nil)
          |> allow_upload(:document_upload,
            accept: :any,
            max_entries: 1,
            max_file_size: 50_000_000
          )
          |> stream_configure(:chat_messages, dom_id: &"chat-msg-#{&1.id}")
          |> stream(:chat_messages, [])
          |> stream_configure(:changes, dom_id: &"change-#{&1.id}")
          |> stream(:changes, [])
          |> stream_configure(:toasts, dom_id: &"toast-#{&1.id}")
          |> stream(:toasts, [])
          |> recompute_grill_assigns()

        {:ok, socket}
    end
  end

  # ----------------------------------------------------------------------------
  # handle_event/3
  # ----------------------------------------------------------------------------

  @impl true
  def handle_event("viewport_change", %{"w" => w}, socket) when is_integer(w) do
    viewport = if w >= 1024, do: :desktop, else: :mobile
    {:noreply, assign(socket, :viewport, viewport)}
  end

  def handle_event("viewport_change", %{"w" => w}, socket) when is_binary(w) do
    case Integer.parse(w) do
      {n, _} -> handle_event("viewport_change", %{"w" => n}, socket)
      :error -> {:noreply, socket}
    end
  end

  def handle_event("toggle_preview", _params, socket) do
    {:noreply, update(socket, :preview_modal_open?, &(!&1))}
  end

  def handle_event("toggle_chat_rail", _params, socket) do
    {:noreply, update(socket, :chat_rail_hidden?, &(!&1))}
  end

  def handle_event("cancel_agent", _params, socket) do
    studio_state = socket.assigns.studio_state

    case studio_state.agent_run_id do
      run_id when is_binary(run_id) ->
        _ = Contract.Agent.cancel(socket.assigns.current_scope, run_id)

        new_state = %{studio_state | agent_run_id: nil}
        {:noreply, assign(socket, :studio_state, new_state)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("open_modal", %{"modal" => modal}, socket) do
    {:noreply, update_modal(socket, modal, true)}
  end

  def handle_event("close_modal", %{"modal" => modal}, socket) do
    {:noreply, update_modal(socket, modal, false)}
  end

  def handle_event("set_node_focus", %{"node_id" => node_id}, socket) do
    {:noreply,
     update(socket, :studio_state, fn state ->
       %{state | selected_node_id: node_id}
     end)}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Cmd+K palette → "Set contract type…" — intercept when no `type_key` is
  # supplied and open the type-picker modal so the user can pick. The picker
  # buttons then re-fire `set_contract_type` with a `type_key`, which goes
  # through the normal `event_to_command/3` funnel.
  # ---------------------------------------------------------------------------

  def handle_event(
        "command_palette_picked",
        %{"kind" => kind} = params,
        socket
      )
      when kind in ["set_contract_type", "document.type.set"] do
    case Map.get(params, "type_key") do
      type_key when is_binary(type_key) and type_key != "" ->
        # User has a type_key — dispatch as a normal set_contract_type Command,
        # then close the type-picker if it was open (so picking a row in the
        # modal completes the round-trip).
        case event_to_command(
               "set_contract_type",
               Map.put(params, "type_key", type_key),
               socket.assigns
             ) do
          {:ok, %Command{} = action} ->
            socket =
              socket
              |> dispatch(action)
              |> put_state_flag(:type_picker_open?, false)

            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not set contract type: #{inspect(reason)}")}
        end

      _ ->
        # No type_key → open the type-picker modal. Driven by a flag on
        # `studio_state` (mirroring metadata/migration panels) so the
        # ModalHost re-renders synchronously on the next paint without
        # needing a `send_update/2` round-trip.
        {:noreply, put_state_flag(socket, :type_picker_open?, true)}
    end
  end

  # ---------------------------------------------------------------------------
  # Conversion wizard events (Wave 4 — Contract.Conversion)
  # ---------------------------------------------------------------------------

  def handle_event("conversion.start", params, socket),
    do: handle_event("start_type_conversion", params, socket)

  # Compatibility alias for pre-dotted callers. Product UI emits `conversion.start`.
  def handle_event("start_type_conversion", params, socket) do
    target_type_key =
      Map.get(params, "target_type_key") || Map.get(params, "type_key")

    scope = socket.assigns.current_scope
    state = socket.assigns.studio_state
    document_id = state && state.selected_document_id

    cond do
      is_nil(document_id) ->
        {:noreply, put_flash(socket, :error, "No document selected for conversion.")}

      is_nil(target_type_key) or target_type_key == "" ->
        {:noreply, put_flash(socket, :error, "Pick a target type first.")}

      true ->
        case Contract.Conversion.plan(scope, document_id, target_type_key, []) do
          {:ok, plan} ->
            # Seed `field_strategies` from the plan's default strategy
            # per field so step 3's summary ("전략이 지정된 필드 수: N")
            # is non-zero from the first paint, AND so the Create
            # variant button is enabled without the user touching every
            # dropdown. Map keys are `source_field_id`, values are the
            # strategy atom rendered as a string (matches the
            # `set_field_strategy` event payload shape). Thread the
            # values through socket assigns so they appear in the
            # ModalHost's render assigns each re-render — this is
            # more deterministic than `send_update` because the
            # parent's render IS the moment we want the component to
            # pick the values up.
            strategies =
              (plan.field_plans || [])
              |> Map.new(fn fp ->
                {fp.source_field_id, Atom.to_string(fp.strategy)}
              end)

            # Best-effort propose: when ≥ 3 fields are :ask_user this
            # parks the plan in PlanCache and enqueues a
            # ConversionPlanJob; the wizard subscribes below and shows
            # an AI-refined indicator on {:plan_refined, plan_id}.
            _ = Contract.Conversion.propose_fields(scope, plan)

            plan_topic_id = Contract.Conversion.plan_id(plan)
            _ = Phoenix.PubSub.subscribe(Contract.PubSub, "plan:" <> plan_topic_id)

            socket =
              socket
              |> assign(:migration_plan, plan)
              |> assign(:migration_plan_id, plan_topic_id)
              |> assign(:migration_plan_refined?, false)
              |> assign(:migration_target, target_type_key)
              |> assign(:field_strategies, strategies)
              |> update(:studio_state, fn st -> %{st | migration_panel_open?: true} end)

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not plan conversion: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("conversion.field_strategy.set", params, socket),
    do: handle_event("set_field_migration_strategy", params, socket)

  # Compatibility alias for pre-dotted callers. Product UI emits `conversion.field_strategy.set`.
  def handle_event("set_field_migration_strategy", params, socket) do
    case socket.assigns[:migration_plan] do
      nil ->
        {:noreply, put_flash(socket, :error, "No active conversion plan.")}

      %Contract.Conversion.Plan{} = plan ->
        field_id = Map.get(params, "source_field_id") || Map.get(params, "field_id")
        strategy = Map.get(params, "strategy")

        case Contract.Conversion.set_field_strategy(
               socket.assigns.current_scope,
               plan,
               to_string(field_id || ""),
               strategy
             ) do
          {:ok, new_plan} ->
            {:noreply, assign(socket, :migration_plan, new_plan)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Bad strategy: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("conversion.create_variant", params, socket),
    do: handle_event("create_variant", params, socket)

  # Compatibility alias for pre-dotted callers. Product UI emits `conversion.create_variant`.
  def handle_event("create_variant", _params, socket) do
    case socket.assigns[:migration_plan] do
      nil ->
        {:noreply, put_flash(socket, :error, "No active conversion plan.")}

      %Contract.Conversion.Plan{} = plan ->
        case Contract.Conversion.create_variant(socket.assigns.current_scope, plan) do
          {:ok, {%Contract.Documents.Document{} = new_doc, _change}} ->
            socket =
              socket
              |> assign(:migration_plan, nil)
              |> update(:studio_state, fn st -> %{st | migration_panel_open?: false} end)
              |> put_flash(:info, "Created variant document #{new_doc.title}.")

            {:noreply, push_navigate(socket, to: ~p"/studio/#{new_doc.id}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Variant creation failed: #{inspect(reason)}")}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # No-document agent prompt — SPEC.md §10. ChatRail renders 5 quick-start
  # chips when `studio_state.mode == :no_document`; each chip fires
  # `agent_option_picked` with a `key`. We route to the corresponding modal
  # or to a Documents.create flow.
  # ---------------------------------------------------------------------------

  def handle_event("agent_option_picked", %{"key" => "upload"}, socket) do
    {:noreply, update_modal(socket, "upload", true)}
  end

  def handle_event("agent_option_picked", %{"key" => "recent"}, socket) do
    {:noreply, update_modal(socket, "document_picker", true)}
  end

  def handle_event("agent_option_picked", %{"key" => "blank"}, socket) do
    create_blank_document(socket)
  end

  def handle_event("agent_option_picked", %{"key" => "draft_from_discussion"}, socket) do
    # Matter-Brief mode is not built yet — stub with an informational flash.
    {:noreply, put_flash(socket, :info, "논의 모드는 곧 추가됩니다.")}
  end

  def handle_event("agent_option_picked", %{"key" => "variant_from_other"}, socket) do
    socket =
      socket
      |> put_state_flag(:variant_source_picker?, true)
      |> update_modal("document_picker", true)

    {:noreply, socket}
  end

  def handle_event("agent_option_picked", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("document.upload.validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("document.upload", params, socket) do
    uploads =
      consume_uploaded_entries(socket, :document_upload, fn %{path: path}, entry ->
        dest = Path.join(System.tmp_dir!(), "studio-upload-#{entry.uuid}-#{entry.client_name}")
        File.cp!(path, dest)

        {:ok,
         %{
           path: dest,
           client_name: entry.client_name,
           client_type: entry.client_type,
           client_size: entry.client_size
         }}
      end)

    params =
      case uploads do
        [upload | _] -> Map.put(params, "upload", upload)
        [] -> params
      end

    case event_to_command("document.upload", params, socket.assigns) do
      {:ok, %Command{} = action} ->
        socket =
          socket
          |> dispatch(action)
          |> update_modal("upload", false)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not upload source: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Export-picker — `request_export` without a `format` opens the picker
  # modal; with a `format` it emits the Command and closes the picker. Routed
  # here (above the generic funnel) so the no-format case can flip the
  # `studio_state.export_picker_open?` flag — the funnel is pure and only
  # speaks `{:ok, Command} | :local | {:error, _}`.
  # ---------------------------------------------------------------------------

  def handle_event("export.request", params, socket),
    do: handle_event("request_export", params, socket)

  def handle_event("command_palette_picked", %{"kind" => kind} = params, socket)
      when kind in ["request_export", "export.request"] do
    handle_event(
      "export.request",
      Map.drop(params, ["kind", "action_kind", "command_kind"]),
      socket
    )
  end

  # Compatibility alias for pre-dotted callers. Product UI emits `export.request`.
  def handle_event("request_export", params, socket) do
    case Map.get(params, "format") do
      format when is_binary(format) and format != "" ->
        case event_to_command("export.request", params, socket.assigns) do
          {:ok, %Command{} = action} ->
            socket =
              socket
              |> dispatch(action)
              |> put_state_flag(:export_picker_open?, false)

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Export failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, put_state_flag(socket, :export_picker_open?, true)}
    end
  end

  def handle_event(event, params, socket) do
    case event_to_command(event, params, socket.assigns) do
      {:ok, %Command{} = action} ->
        {:noreply, dispatch(socket, action)}

      :local ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unknown action: #{inspect(reason)}")}
    end
  end

  # Helper: create a blank owner-scoped document through Runtime so both the
  # documents row and initial Change exist, then navigate document-first.
  defp create_blank_document(socket) do
    scope = socket.assigns.current_scope

    action = %Command{
      kind: :create_document,
      actor_type: :user,
      actor_id: scope && scope.user && scope.user.id,
      base_revision: 0,
      idempotency_key: generate_idempotency_key(),
      payload: %{"title" => "새 문서"}
    }

    case Contract.Runtime.apply(scope, action) do
      {:ok, %Contract.Change{document_id: document_id}} ->
        {:noreply, push_navigate(socket, to: ~p"/studio/#{document_id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "문서 생성에 실패했습니다.")}
    end
  end

  # ----------------------------------------------------------------------------
  # handle_info/2
  # ----------------------------------------------------------------------------

  @impl true
  def handle_info(message, socket) do
    socket = handle_protocol_message(message, socket)
    socket = assign(socket, :last_pubsub_message_at, DateTime.utc_now())
    {:noreply, socket}
  end

  # ----------------------------------------------------------------------------
  # dispatch/2
  # ----------------------------------------------------------------------------

  @doc """
  The ONE place that takes a typed Command and submits it through the
  product façade.

    1. Calls `Studio.command/2`.
    2. On success: re-assigns updated state, may flash an info toast.
    3. On `{:error, _}`: flashes the error string, leaves state untouched.

  Returns the updated socket. The caller wraps in `{:noreply, ...}`.
  """
  @spec dispatch(Phoenix.LiveView.Socket.t(), Command.t()) :: Phoenix.LiveView.Socket.t()
  def dispatch(socket, %Command{} = action) do
    scope = socket.assigns.current_scope
    state = socket.assigns.studio_state

    case Studio.command_result(scope, state, action) do
      {:ok, %Contract.Studio.State{} = new_state, result} ->
        # If a new agent run was registered, subscribe to its topic.
        if new_state.agent_run_id && new_state.agent_run_id != state.agent_run_id do
          _ = Studio.subscribe_agent(scope, new_state.agent_run_id)
        end

        socket
        |> assign(:studio_state, new_state)
        |> apply_submit_result(action, result)
        |> maybe_refresh_chat_messages(action, new_state)

      {:error, {:source_parse_failed, reason, source_document}} ->
        socket
        |> insert_source_document_failed(source_document, reason)
        |> put_flash(:error, "Could not submit action: #{inspect(reason)}")

      {:error, reason} ->
        put_flash(socket, :error, "Could not submit action: #{inspect(reason)}")
    end
  end

  defp maybe_refresh_chat_messages(
         socket,
         %Command{kind: :chat_message},
         %Contract.Studio.State{} = state
       ) do
    messages = ChatThreads.list_visible_messages(socket.assigns.current_scope, state)
    stream(socket, :chat_messages, messages, reset: true)
  end

  defp maybe_refresh_chat_messages(
         socket,
         %Command{kind: kind},
         %Contract.Studio.State{} = state
       )
       when kind in [
              :source_claim_confirm,
              :source_claim_correct,
              :source_claim_reject,
              :source_claim_link_to_document,
              :source_claim_unlink_from_document
            ] do
    messages = ChatThreads.list_visible_messages(socket.assigns.current_scope, state)

    if messages == [] do
      socket
    else
      stream(socket, :chat_messages, messages, reset: true)
    end
  end

  defp maybe_refresh_chat_messages(socket, _action, _state), do: socket

  defp apply_submit_result(
         socket,
         %Command{kind: :upload_document},
         {%Contract.SourceDocument{} = source_document, claims}
       ) do
    socket = handle_protocol_message({:source_document_parsed, source_document}, socket)

    socket =
      handle_protocol_message({:source_interpretation_ready, source_document.id, claims}, socket)

    Enum.reduce(List.wrap(claims), socket, fn claim, socket ->
      handle_protocol_message({:source_claim_updated, claim}, socket)
    end)
  end

  defp apply_submit_result(socket, %Command{kind: kind}, %Contract.SourceClaim{} = claim)
       when kind in [
              :source_claim_confirm,
              :source_claim_correct,
              :source_claim_reject,
              :source_claim_link_to_document,
              :source_claim_unlink_from_document
            ] do
    handle_protocol_message({:source_claim_updated, claim}, socket)
  end

  defp apply_submit_result(socket, _action, _result), do: socket

  defp insert_source_document_failed(socket, source_document, reason) do
    source_id = protocol_id(source_document) || System.unique_integer([:positive])

    insert_operation_chat(socket, "source-#{source_id}", %{
      id: "source-#{source_id}",
      type: "source_interpretation",
      title: protocol_title(source_document),
      status: "failed",
      summary: "Source parsing failed",
      details: Map.put(normalize_operation_details(source_document), :error, inspect(reason))
    })
  end

  # ----------------------------------------------------------------------------
  # event_to_command/3 — the dispatch funnel
  # ----------------------------------------------------------------------------

  @doc """
  Translates a UI event name + params into a typed `Contract.Command`. Returns
  `:local` for events that don't translate to a Command (UI-only). Returns
  `{:error, reason}` for unknown events.
  """
  @spec event_to_command(String.t(), map(), map()) ::
          {:ok, Command.t()} | :local | {:error, term()}
  def event_to_command(event, params, assigns)

  def event_to_command("document.rename", params, assigns),
    do: build_action(assigns, :rename_document, params)

  def event_to_command("document.edit", params, assigns),
    do: build_action(assigns, :edit_document, params)

  def event_to_command("document.open", params, assigns),
    do: build_action(assigns, :open_document, params)

  def event_to_command("document.upload", params, assigns),
    do: build_action(assigns, :upload_document, params, document_required: false)

  def event_to_command("document.duplicate", params, assigns),
    do: build_action(assigns, :duplicate_document, params)

  def event_to_command("document.create", params, assigns),
    do: build_action(assigns, :create_document, params, document_required: false)

  def event_to_command("document.type.set", params, assigns),
    do: build_action(assigns, :set_contract_type, params)

  def event_to_command("document.metadata.update", params, assigns),
    do: build_action(assigns, :update_metadata, params)

  def event_to_command("document.set_contract_type", params, assigns),
    do: build_action(assigns, :set_contract_type, params)

  def event_to_command("chat.submit", params, assigns),
    do: build_action(assigns, :chat_message, params, document_required: false)

  def event_to_command("source_claim.confirm", params, assigns),
    do: build_action(assigns, :source_claim_confirm, params, document_required: false)

  def event_to_command("source_claim.correct", params, assigns),
    do: build_action(assigns, :source_claim_correct, params, document_required: false)

  def event_to_command("source_claim.reject", params, assigns),
    do: build_action(assigns, :source_claim_reject, params, document_required: false)

  def event_to_command("source_claim.link_to_document", params, assigns),
    do: build_action(assigns, :source_claim_link_to_document, params, document_required: false)

  def event_to_command("source_claim.unlink", params, assigns),
    do:
      build_action(assigns, :source_claim_unlink_from_document, params, document_required: false)

  def event_to_command("change.revoke", params, assigns) do
    case params["change_id"] || params[:change_id] do
      change_id when is_binary(change_id) and change_id != "" ->
        build_action(assigns, :revoke_change, params)

      _ ->
        {:error, {:missing_change_id, :revoke_change}}
    end
  end

  def event_to_command("revoke.resolve", params, assigns),
    do: build_action(assigns, :resolve_revoke, params)

  def event_to_command("export.request", params, assigns),
    do: build_action(assigns, :request_export, params)

  def event_to_command("conversion.create_variant", params, assigns),
    do: build_action(assigns, :create_converted_variant, params, document_required: false)

  # Compatibility aliases for pre-dotted event producers. Product UI should use
  # the dotted clauses above.
  def event_to_command("rename_document", params, assigns) do
    build_action(assigns, :rename_document, params)
  end

  def event_to_command("set_contract_type", params, assigns) do
    build_action(assigns, :set_contract_type, params)
  end

  def event_to_command("edit_document", params, assigns) do
    build_action(assigns, :edit_document, params)
  end

  def event_to_command("send_chat_message", params, assigns) do
    build_action(assigns, :chat_message, params, document_required: false)
  end

  def event_to_command("update_metadata", params, assigns) do
    build_action(assigns, :update_metadata, params)
  end

  def event_to_command("revoke_change", params, assigns) do
    event_to_command("change.revoke", params, assigns)
  end

  def event_to_command("upload_document", params, assigns) do
    build_action(assigns, :upload_document, params, document_required: false)
  end

  # "create_variant" is intercepted by handle_event/3 directly (Wave 4 —
  # the wizard fires it with the in-flight Plan held in assigns, not as
  # an Command payload). The mapping below remains for backward compat
  # in case a caller still routes it through the funnel.
  def event_to_command("create_variant", params, assigns) do
    build_action(assigns, :create_converted_variant, params, document_required: false)
  end

  def event_to_command("open_document", params, assigns) do
    build_action(assigns, :open_document, params)
  end

  def event_to_command("duplicate_document", params, assigns) do
    build_action(assigns, :duplicate_document, params)
  end

  def event_to_command("request_export", params, assigns) do
    build_action(assigns, :request_export, params)
  end

  def event_to_command("command_palette_picked", %{"kind" => kind} = params, assigns)
      when is_binary(kind) do
    params = Map.drop(params, ["kind", "action_kind", "command_kind"])

    if String.contains?(kind, ".") do
      event_to_command(kind, params, assigns)
    else
      build_action(assigns, String.to_existing_atom(kind), params, document_required: false)
    end
  rescue
    ArgumentError -> {:error, {:unknown_palette_kind, kind}}
  end

  # Local-only UI events (no Command emitted).
  def event_to_command(local, _params, _assigns)
      when local in [
             "toggle_preview",
             "open_modal",
             "close_modal",
             "set_node_focus",
             "viewport_change"
           ] do
    :local
  end

  def event_to_command(event, _params, _assigns) do
    {:error, {:unknown_event, event}}
  end

  defp build_action(assigns, kind, params, opts \\ []) do
    document_required = Keyword.get(opts, :document_required, true)

    scope = assigns[:current_scope]
    state = assigns[:studio_state]

    actor_id = scope && scope.user && scope.user.id

    document_id =
      params["document_id"] || params[:document_id] ||
        (state && state.selected_document_id)

    if document_required and is_nil(document_id) do
      {:error, {:missing_document_id, kind}}
    else
      {:ok,
       %Command{
         kind: kind,
         actor_type: :user,
         actor_id: actor_id,
         document_id: document_id,
         chat_thread_id: params["chat_thread_id"] || params[:chat_thread_id],
         source_document_id: params["source_document_id"] || params[:source_document_id],
         source_claim_id: params["source_claim_id"] || params[:source_claim_id],
         change_id: params["change_id"] || params[:change_id],
         base_revision: state && state.last_seen_revision,
         idempotency_key: generate_idempotency_key(),
         payload: params_to_payload(params),
         message: params["message"] || params[:message]
       }}
    end
  end

  defp params_to_payload(params) when is_map(params) do
    Map.drop(params, [
      "document_id",
      :document_id,
      "chat_thread_id",
      :chat_thread_id,
      "source_document_id",
      :source_document_id,
      "source_claim_id",
      :source_claim_id,
      "change_id",
      :change_id,
      "matter_id",
      :matter_id,
      "message",
      :message
    ])
  end

  defp generate_idempotency_key do
    "ui-" <> (Ecto.UUID.generate() |> String.replace("-", ""))
  end

  # ----------------------------------------------------------------------------
  # handle_protocol_message/2 — SPEC.md §11
  # ----------------------------------------------------------------------------

  @doc """
  Pattern matches every protocol message type from SPEC.md §11 and updates
  assigns/streams. Public so tests can drive the funnel directly without
  the PubSub round-trip.
  """
  @spec handle_protocol_message(term(), Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_protocol_message({:studio_loaded, %Contract.Studio.State{} = state}, socket) do
    assign(socket, :studio_state, state)
  end

  def handle_protocol_message({:document_selected, document_id, revision}, socket)
      when is_binary(document_id) do
    case Studio.select_document(
           socket.assigns.current_scope,
           socket.assigns.studio_state,
           document_id
         ) do
      {:ok, {new_state, projection}} ->
        socket
        |> assign(:studio_state, %{
          new_state
          | last_seen_revision: revision || new_state.last_seen_revision
        })
        |> assign(:projection, projection)
        |> assign(:current_document, current_document(socket.assigns.current_scope, new_state))

      {:error, _} ->
        socket
    end
  end

  def handle_protocol_message({:change_committed, %Contract.Change{} = change}, socket) do
    socket
    |> update(:studio_state, fn state ->
      if change.result_revision &&
           change.result_revision > (state.last_seen_revision || 0) do
        %{state | last_seen_revision: change.result_revision}
      else
        state
      end
    end)
    |> stream_insert(:changes, change, at: 0)
    |> push_editor_last_change(change)
    |> recompute_grill_assigns()
  end

  def handle_protocol_message({:change_revoked, %Contract.Change{} = change}, socket) do
    socket
    |> stream_insert(:changes, change, at: 0)
    |> push_event("editor:change-revoked", %{change_id: change.id})
  end

  def handle_protocol_message({:revision_conflict, change_id, node_id}, socket) do
    push_event(socket, "editor-revert", %{node_id: node_id, change_id: change_id})
  end

  def handle_protocol_message({:revoke_requested, request}, socket) do
    socket
    |> assign(:reconcile_request, request)
    |> assign(:reconcile_modal_open?, true)
    |> stream_insert(:toasts, build_toast(:info, "Revoke requested", request_summary(request)))
  end

  def handle_protocol_message({:change_reconciled, %Contract.Change{} = change}, socket) do
    socket
    |> assign(:reconcile_request, nil)
    |> assign(:reconcile_modal_open?, false)
    |> stream_insert(:changes, change, at: 0)
  end

  def handle_protocol_message({:dismiss_toast, toast_id}, socket) do
    stream_delete(socket, :toasts, %{id: toast_id})
  end

  def handle_protocol_message({:marks_changed, marks}, socket) when is_map(marks) do
    socket
    |> update(:projection, fn proj -> Map.put(proj, :marks, marks) end)
    |> recompute_grill_assigns()
  end

  def handle_protocol_message({:agent_stream, agent_run_id, stream_event}, socket) do
    bubble = %{
      id: stream_event_id(agent_run_id, stream_event),
      agent_run_id: agent_run_id,
      role: :agent,
      event: stream_event,
      transient?: true
    }

    stream_insert(socket, :chat_messages, bubble)
  end

  def handle_protocol_message({:agent_completed, agent_run_id, result}, socket) do
    bubble = %{
      id: "agent-#{agent_run_id}-final",
      agent_run_id: agent_run_id,
      role: :agent,
      result: result,
      transient?: false
    }

    socket
    |> update(:studio_state, fn state ->
      if state.agent_run_id == agent_run_id do
        %{state | agent_run_id: nil}
      else
        state
      end
    end)
    |> stream_insert(:chat_messages, bubble)
    |> recompute_grill_assigns()
  end

  def handle_protocol_message({:agent_failed, agent_run_id, reason}, socket) do
    socket
    |> update(:studio_state, fn state ->
      if state.agent_run_id == agent_run_id do
        %{state | agent_run_id: nil}
      else
        state
      end
    end)
    |> stream_insert(:toasts, build_toast(:error, "Agent failed", inspect(reason)))
    |> recompute_grill_assigns()
  end

  def handle_protocol_message({:tool_call_started, agent_run_id, tool_call}, socket) do
    tool_id = protocol_id(tool_call) || System.unique_integer([:positive])
    tool_name = protocol_name(tool_call)

    insert_operation_chat(
      socket,
      "tool-#{agent_run_id}-#{tool_id}",
      %{
        id: "tool-#{agent_run_id}-#{tool_id}",
        type: "tool_call",
        title: tool_name,
        status: "running",
        summary: "Started",
        details: normalize_operation_details(tool_call)
      },
      transient?: true
    )
  end

  def handle_protocol_message({:tool_call_delta, agent_run_id, tool_call_id, delta}, socket) do
    insert_operation_chat(
      socket,
      "tool-#{agent_run_id}-#{tool_call_id}",
      %{
        id: "tool-#{agent_run_id}-#{tool_call_id}",
        type: "tool_call",
        title: tool_trace_title(delta, "도구 실행"),
        status: "running",
        summary: protocol_summary(delta),
        details: normalize_operation_details(delta)
      },
      transient?: true
    )
  end

  def handle_protocol_message({:tool_call_completed, agent_run_id, tool_call_id, result}, socket) do
    insert_operation_chat(socket, "tool-#{agent_run_id}-#{tool_call_id}", %{
      id: "tool-#{agent_run_id}-#{tool_call_id}",
      type: "tool_call",
      title: tool_trace_title(result, "도구 실행"),
      status: "completed",
      summary: protocol_summary(result),
      details: normalize_operation_details(result)
    })
  end

  def handle_protocol_message({:tool_call_failed, agent_run_id, tool_call_id, reason}, socket) do
    insert_operation_chat(socket, "tool-#{agent_run_id}-#{tool_call_id}", %{
      id: "tool-#{agent_run_id}-#{tool_call_id}",
      type: "tool_call",
      title: tool_trace_title(reason, "도구 실행"),
      status: "failed",
      summary: protocol_summary(reason),
      details: normalize_operation_details(reason)
    })
  end

  def handle_protocol_message({:source_document_uploaded, source_document}, socket) do
    source_id = protocol_id(source_document) || System.unique_integer([:positive])

    insert_operation_chat(socket, "source-#{source_id}", %{
      id: "source-#{source_id}",
      type: "source_interpretation",
      title: protocol_title(source_document),
      status: "uploaded",
      summary: "Source uploaded",
      details: normalize_operation_details(source_document)
    })
  end

  def handle_protocol_message({:source_document_parse_started, source_document_id}, socket) do
    insert_operation_chat(
      socket,
      "source-#{source_document_id}",
      %{
        id: "source-#{source_document_id}",
        type: "source_interpretation",
        title: "Source #{short_id(source_document_id)}",
        status: "parsing",
        summary: "Parsing source document",
        details: %{"source_document_id" => source_document_id}
      },
      transient?: true
    )
  end

  def handle_protocol_message({:source_document_parsed, source_document}, socket) do
    source_id = protocol_id(source_document) || System.unique_integer([:positive])

    insert_operation_chat(socket, "source-#{source_id}", %{
      id: "source-#{source_id}",
      type: "source_interpretation",
      title: protocol_title(source_document),
      status: "parsed",
      summary: "Source parsed",
      details: normalize_operation_details(source_document)
    })
  end

  def handle_protocol_message({:source_interpretation_ready, source_document_id, claims}, socket) do
    insert_operation_chat(socket, "source-#{source_document_id}-interpretation", %{
      id: "source-#{source_document_id}-interpretation",
      type: "source_interpretation",
      title: "Source interpretation",
      status: "ready",
      summary: "#{length(List.wrap(claims))} claims",
      details: %{"source_document_id" => source_document_id, "claims" => List.wrap(claims)}
    })
  end

  def handle_protocol_message({:source_claim_updated, claim}, socket) do
    claim_id = protocol_id(claim) || System.unique_integer([:positive])

    insert_operation_chat(socket, "source-claim-#{claim_id}", %{
      id: "source-claim-#{claim_id}",
      type: "source_claim",
      title: "Source claim #{short_id(claim_id)}",
      status: protocol_status(claim),
      summary: "Source claim updated",
      details: normalize_operation_details(claim)
    })
  end

  def handle_protocol_message({:evidence_created, evidence}, socket) do
    evidence_id = protocol_id(evidence) || System.unique_integer([:positive])

    insert_operation_chat(socket, "evidence-#{evidence_id}", %{
      id: "evidence-#{evidence_id}",
      type: "evidence",
      title: "Evidence #{short_id(evidence_id)}",
      status: "created",
      summary: protocol_summary(evidence),
      details: normalize_operation_details(evidence)
    })
  end

  def handle_protocol_message({:evidence_attached, evidence, mark}, socket) do
    evidence_id = protocol_id(evidence) || System.unique_integer([:positive])
    mark_id = protocol_id(mark) || System.unique_integer([:positive])

    insert_operation_chat(socket, "evidence-#{evidence_id}-attached-#{mark_id}", %{
      id: "evidence-#{evidence_id}-attached-#{mark_id}",
      type: "evidence",
      title: "Evidence #{short_id(evidence_id)}",
      status: "attached",
      summary: protocol_summary(evidence),
      details: %{
        "evidence" => normalize_operation_details(evidence),
        "mark" => normalize_operation_details(mark)
      }
    })
  end

  def handle_protocol_message({:export_started, export_id}, socket) do
    insert_operation_chat(socket, "export-#{export_id}", %{
      id: "export-#{export_id}",
      type: "export_status",
      title: "Export #{short_id(export_id)}",
      status: "started",
      summary: short_id(export_id),
      details: %{"export_id" => export_id}
    })
  end

  def handle_protocol_message({:session_stale, document_id}, socket)
      when is_binary(document_id) do
    Process.send_after(self(), {:reconnect_attempt, document_id}, 500)

    stream_insert(
      socket,
      :toasts,
      build_toast(:warning, "Session lost", "Reconnecting…")
    )
  end

  def handle_protocol_message({:session_recovered, document_id, revision}, socket)
      when is_binary(document_id) do
    state = socket.assigns.studio_state
    from_rev = state.last_seen_revision || 0

    socket =
      case Studio.sync(
             socket.assigns.current_scope,
             state.selected_document_id,
             from_rev
           ) do
        {:ok, changes} ->
          new_rev =
            changes
            |> Enum.map(& &1.result_revision)
            |> Enum.max(fn -> from_rev end)

          assign(socket, :studio_state, %{
            state
            | last_seen_revision: revision || new_rev
          })

        {:error, _} ->
          socket
      end

    stream_insert(
      socket,
      :toasts,
      build_toast(:info, "Session recovered", "Caught up to revision #{revision}.")
    )
  end

  def handle_protocol_message({:reconnect_attempt, document_id}, socket)
      when is_binary(document_id) do
    case Studio.reload(socket.assigns.current_scope, socket.assigns.studio_state) do
      {:ok, {new_state, projection}} ->
        socket
        |> assign(:studio_state, new_state)
        |> assign(:projection, projection)

      {:error, _} ->
        socket
    end
  end

  def handle_protocol_message({:import_completed, document}, socket) do
    stream_insert(
      socket,
      :toasts,
      build_toast(:info, "Import completed", import_summary(document))
    )
  end

  def handle_protocol_message({:evidence_attached, _evidence}, socket) do
    socket
  end

  def handle_protocol_message({:import_failed, import_id, reason}, socket) do
    stream_insert(
      socket,
      :toasts,
      build_toast(:error, "Import failed (#{short_id(import_id)})", inspect(reason))
    )
  end

  def handle_protocol_message({:export_status, status}, socket) when is_map(status) do
    level = if status.status == :failed, do: :error, else: :info
    title = if status.status == :ready, do: "Export ready", else: "Export #{status.status}"

    stream_insert(
      socket,
      :toasts,
      build_toast(level, title, export_status_summary(status))
    )
  end

  def handle_protocol_message({:export_ready, export}, socket) do
    stream_insert(socket, :toasts, build_toast(:info, "Export ready", export_summary(export)))
  end

  def handle_protocol_message({:export_failed, export_id, reason}, socket) do
    stream_insert(
      socket,
      :toasts,
      build_toast(:error, "Export failed (#{short_id(export_id)})", inspect(reason))
    )
  end

  def handle_protocol_message({:plan_refined, plan_id}, socket) when is_binary(plan_id) do
    # Wave 4.5: ConversionPlanJob has refined the cached plan. Reload it
    # from PlanCache and re-seed the field-strategy assigns so step 2's
    # dropdowns reflect the AI suggestions. The wizard renders a small
    # AI-refined indicator while `migration_plan_refined?` is true.
    if socket.assigns[:migration_plan_id] == plan_id do
      case Contract.Conversion.PlanCache.get(plan_id) do
        {:ok, %Contract.Conversion.Plan{} = refined} ->
          strategies =
            (refined.field_plans || [])
            |> Map.new(fn fp ->
              {fp.source_field_id, Atom.to_string(fp.strategy)}
            end)

          socket
          |> assign(:migration_plan, refined)
          |> assign(:migration_plan_refined?, true)
          |> assign(:field_strategies, strategies)

        {:error, :not_found} ->
          socket
      end
    else
      socket
    end
  end

  # Cmd+K palette → action commands. The palette's LiveComponent shares
  # this LV's process; on Enter / click it `send/2`s the picked event
  # back here so the parent's `handle_event/3` funnel can dispatch it
  # uniformly with the mobile chat-command-button path (which uses a
  # direct `phx-click`).
  def handle_protocol_message({"command_palette_picked", params}, socket)
      when is_map(params) do
    {:noreply, socket_after_event} = handle_event("command_palette_picked", params, socket)
    socket_after_event
  end

  def handle_protocol_message(_unknown, socket) do
    # Spec invariant 7: PubSub events are advisory. Ignore noise.
    socket
  end

  # ----------------------------------------------------------------------------
  # Render
  # ----------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @viewport == :mobile do %>
      <%!--
      Mobile: full-bleed chat surface. Owner directive 2026-05-17:
      "The chat should fill the whole screen in mobile, not being
      part of a page." We bypass Layouts.app entirely so there is no
      top navbar (h-14), no breadcrumbs, no footer, no page padding.
      The chat rail IS the page. The chat rail's own header carries
      the 문서 toggle, so no floating preview FAB.
      --%>
      <div
        id="studio-root"
        phx-hook=".Viewport"
        data-viewport="mobile"
        class="fixed inset-0 z-50 flex flex-col bg-base-100"
        style="height: 100dvh; padding-top: env(safe-area-inset-top, 0px); padding-bottom: env(safe-area-inset-bottom, 0px);"
      >
        <script :type={Phoenix.LiveView.ColocatedHook} name=".Viewport">
          export default {
            mounted() {
              this.push_viewport = () => {
                const w = window.innerWidth || document.documentElement.clientWidth
                this.pushEventTo(this.el, "viewport_change", {w: w})
              }
              this.push_viewport()
              this.handler = () => {
                if (this.t) clearTimeout(this.t)
                this.t = setTimeout(this.push_viewport, 120)
              }
              window.addEventListener("resize", this.handler)
            },
            destroyed() {
              window.removeEventListener("resize", this.handler)
              if (this.t) clearTimeout(this.t)
            }
          }
        </script>

        <.live_component
          module={Components.ChatRail}
          id="chat-rail-mobile"
          studio_state={@studio_state}
          streams={%{chat_messages: @streams.chat_messages}}
          current_scope={@current_scope}
          layout={:mobile_full}
          grill_marks={@grill_marks}
          grill_active?={@grill_active?}
        />

        <.live_component
          :if={@preview_modal_open?}
          module={Components.PreviewOverlay}
          id="preview-overlay"
          projection={@projection}
          studio_state={@studio_state}
          current_scope={@current_scope}
          viewport={@viewport}
          streams={%{changes: @streams.changes}}
        />

        <.live_component
          module={Components.ModalHost}
          id="modal-host"
          studio_state={@studio_state}
          current_scope={@current_scope}
          projection={@projection}
          reconcile_modal_open?={@reconcile_modal_open?}
          reconcile_request={@reconcile_request}
          migration_plan={@migration_plan}
          migration_plan_refined?={assigns[:migration_plan_refined?] || false}
          migration_target={assigns[:migration_target]}
          field_strategies={assigns[:field_strategies]}
          document_upload={@uploads.document_upload}
          documents={Contract.Studio.list_documents(@current_scope)}
        />

        <.live_component
          module={Components.ToastQueue}
          id="toast-queue"
          streams={%{toasts: @streams.toasts}}
          viewport={@viewport}
        />

        <CommandPalette.mount_if_live
          current_scope={@current_scope}
          current_document_id={@studio_state.selected_document_id || assigns[:current_document_id]}
        />
      </div>

      <Layouts.flash_group flash={@flash} />
    <% else %>
      <.app_shell current_scope={@current_scope}>
        <main
          id="studio-root"
          phx-hook=".Viewport"
          data-viewport="desktop"
          class={[
            "studio-live min-h-[calc(100vh-60px)] w-full",
            @chat_rail_hidden? && "!pr-0"
          ]}
        >
            <%!-- Desktop: document canvas + right chat rail. No permanent Context Reservoir. --%>
            <section class="studio-document flex min-w-0 flex-col">
              <header
                id="studio-document-header"
                class="studio-document__bar justify-between"
              >
                <div class="inline-flex items-center gap-1 min-w-0">
                <form
                  phx-submit="rename_document"
                  phx-change="rename_document"
                  class="inline-flex items-center h-8"
                  data-role="document-title-form"
                >
                  <% title_value = document_header_title(@current_document, @projection, @studio_state) %>
                  <input
                    type="text"
                    name="title"
                    value={title_value}
                    size={title_input_size(title_value)}
                    aria-label={dgettext("studio", "문서 제목")}
                    placeholder={dgettext("studio", "제목을 입력하세요")}
                    autocomplete="off"
                    spellcheck="false"
                    phx-debounce="400"
                    class="h-8 leading-none cursor-text bg-transparent text-sm font-medium text-base-content px-2 py-0 rounded-md border border-base-300 hover:border-base-content/30 focus:border-base-content/50 focus:bg-base-100 outline-none focus:outline-none focus:ring-0 focus:shadow-none transition-colors"
                    style="min-width: 0; width: auto;"
                  />
                </form>

                <%!-- Contract-type field — READ-ONLY display.            --%>
                <%!-- 2026-05-18 owner directive: the type is decided at  --%>
                <%!-- creation (Storage's 새 문서 dropdown) and immutable --%>
                <%!-- afterwards. The header just surfaces what was       --%>
                <%!-- chosen; no in-place editing, no clearing.            --%>
                <span
                  class="inline-flex h-7 items-center px-2 rounded-md text-xs font-medium border border-base-300 text-base-content/70"
                  data-role="document-type-summary"
                  aria-label={dgettext("studio", "문서 타입")}
                  title={ContractTypes.display_name(projection_type_key(@projection))}
                >
                  {ContractTypes.display_name(projection_type_key(@projection))}
                </span>

                <details :if={@other_documents != []} class="relative shrink-0" data-role="document-picker">
                  <summary
                    class="list-none inline-flex h-7 w-7 items-center justify-center rounded-md cursor-pointer text-base-content/60 hover:text-base-content hover:bg-base-200"
                    aria-label={dgettext("studio", "다른 문서로 이동")}
                  >
                    <.icon name="hero-chevron-down" class="size-4" />
                  </summary>
                  <div
                    class="absolute left-0 top-full mt-1 z-30 w-64 max-h-72 overflow-y-auto rounded-md border border-base-300 bg-base-100 shadow-lg py-1 text-sm"
                    role="menu"
                  >
                    <.link
                      :for={d <- @other_documents}
                      navigate={~p"/studio/#{d.id}"}
                      role="menuitem"
                      class="block px-3 py-1.5 truncate text-base-content hover:bg-base-200"
                      title={d.title}
                    >
                      {d.title}
                    </.link>
                  </div>
                </details>
                </div>

                <div class="inline-flex items-center">
                <details class="relative shrink-0" data-role="export-picker">
                  <summary
                    class="list-none inline-flex h-8 items-center gap-1 px-2 rounded-md cursor-pointer text-base-content/70 hover:text-base-content hover:bg-base-200 text-sm transition-colors"
                    aria-label={dgettext("studio", "내보내기")}
                  >
                    <.icon name="hero-arrow-down-tray" class="size-4" />
                    <span>{dgettext("studio", "내보내기")}</span>
                  </summary>
                  <div
                    class="absolute right-0 top-full mt-1 z-30 w-44 rounded-md border border-base-300 bg-base-100 shadow-lg py-1 text-sm"
                    role="menu"
                  >
                    <button
                      :for={fmt <- ["pdf", "docx", "hwpx", "markdown"]}
                      type="button"
                      role="menuitem"
                      phx-click="export.request"
                      phx-value-format={fmt}
                      class="flex w-full items-center justify-between px-3 py-1.5 text-base-content hover:bg-base-200"
                    >
                      <span class="font-medium">{export_format_label(fmt)}</span>
                      <span class="text-xs uppercase tracking-wide text-base-content/40">{fmt}</span>
                    </button>
                  </div>
                </details>

                <button
                  type="button"
                  phx-click="toggle_chat_rail"
                  class="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-base-content/60 hover:text-base-content hover:bg-base-200 transition-colors"
                  aria-label={
                    if @chat_rail_hidden?,
                      do: dgettext("studio", "에이전트 패널 펼치기"),
                      else: dgettext("studio", "전체화면")
                  }
                  aria-pressed={to_string(@chat_rail_hidden?)}
                  data-role="toggle-chat-rail"
                >
                  <.icon
                    name={if @chat_rail_hidden?, do: "hero-arrows-pointing-in", else: "hero-arrows-pointing-out"}
                    class="size-4"
                  />
                </button>
                </div>
              </header>

              <article class="contract-projection cs-document-text relative min-h-0 flex-1">
                <div class="relative h-full min-h-0">
                  <.live_component
                    :if={@studio_state.mode == :reviewing}
                    module={Components.Canvas.Review}
                    id="canvas"
                    studio_state={@studio_state}
                    projection={@projection}
                    current_scope={@current_scope}
                    changes_stream={@streams.changes}
                  />
                  <.live_component
                    :if={@studio_state.mode != :reviewing}
                    module={canvas_module(@studio_state.mode)}
                    id="canvas"
                    studio_state={@studio_state}
                    projection={@projection}
                    current_scope={@current_scope}
                    document_upload={@uploads.document_upload}
                  />
                  <.live_component
                    module={Components.MarksLayer}
                    id="marks-layer"
                    projection={@projection}
                    studio_state={@studio_state}
                    viewport={@viewport}
                  />
                </div>
              </article>
            </section>

            <aside
              :if={not @chat_rail_hidden?}
              id="studio-chat-rail"
              phx-hook=".RailResizer"
              class="studio-rail fixed top-[60px] right-0 h-[calc(100vh-60px)] min-h-0 flex flex-col z-30"
              style="width: var(--chat-rail-width, 380px);"
            >
              <div
                class="chat-rail-resizer"
                data-role="chat-rail-resizer"
                aria-hidden="true"
              ></div>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".RailResizer">
                export default {
                  mounted() {
                    const aside = this.el
                    const handle = aside.querySelector('[data-role="chat-rail-resizer"]')
                    if (!handle) return

                    const root = document.documentElement
                    const storageKey = "cs:chat-rail-width"
                    const MIN = 280
                    const MAX = 720

                    const stored = localStorage.getItem(storageKey)
                    if (stored) {
                      const w = parseInt(stored, 10)
                      if (!isNaN(w) && w >= MIN && w <= MAX) {
                        root.style.setProperty("--chat-rail-width", w + "px")
                      }
                    }

                    let startX = 0
                    let startWidth = 0
                    let dragging = false

                    const onMove = (e) => {
                      if (!dragging) return
                      const x = e.touches ? e.touches[0].clientX : e.clientX
                      const next = Math.min(MAX, Math.max(MIN, startWidth + (startX - x)))
                      root.style.setProperty("--chat-rail-width", next + "px")
                    }

                    const onUp = () => {
                      if (!dragging) return
                      dragging = false
                      handle.removeAttribute("data-dragging")
                      document.body.removeAttribute("data-chat-rail-dragging")
                      const current = parseInt(getComputedStyle(root).getPropertyValue("--chat-rail-width"), 10)
                      if (!isNaN(current)) localStorage.setItem(storageKey, String(current))
                      window.removeEventListener("mousemove", onMove)
                      window.removeEventListener("mouseup", onUp)
                      window.removeEventListener("touchmove", onMove)
                      window.removeEventListener("touchend", onUp)
                    }

                    const onDown = (e) => {
                      e.preventDefault()
                      dragging = true
                      startX = e.touches ? e.touches[0].clientX : e.clientX
                      startWidth = aside.getBoundingClientRect().width
                      handle.setAttribute("data-dragging", "true")
                      document.body.setAttribute("data-chat-rail-dragging", "true")
                      window.addEventListener("mousemove", onMove)
                      window.addEventListener("mouseup", onUp)
                      window.addEventListener("touchmove", onMove, { passive: false })
                      window.addEventListener("touchend", onUp)
                    }

                    handle.addEventListener("mousedown", onDown)
                    handle.addEventListener("touchstart", onDown, { passive: false })
                    this._onDown = onDown
                    this._handle = handle
                  },
                  destroyed() {
                    if (this._handle && this._onDown) {
                      this._handle.removeEventListener("mousedown", this._onDown)
                      this._handle.removeEventListener("touchstart", this._onDown)
                    }
                  }
                }
              </script>
              <.live_component
                module={Components.ChatRail}
                id="chat-rail"
                studio_state={@studio_state}
                streams={%{chat_messages: @streams.chat_messages}}
                current_scope={@current_scope}
                grill_marks={@grill_marks}
                grill_active?={@grill_active?}
              />
            </aside>

            <.live_component
              module={Components.ModalHost}
              id="modal-host"
              studio_state={@studio_state}
              current_scope={@current_scope}
              projection={@projection}
              reconcile_modal_open?={@reconcile_modal_open?}
              reconcile_request={@reconcile_request}
              migration_plan={@migration_plan}
              migration_plan_refined?={assigns[:migration_plan_refined?] || false}
              migration_target={assigns[:migration_target]}
              field_strategies={assigns[:field_strategies]}
              document_upload={@uploads.document_upload}
              documents={Contract.Studio.list_documents(@current_scope)}
            />

            <.live_component
              module={Components.ToastQueue}
              id="toast-queue"
              streams={%{toasts: @streams.toasts}}
              viewport={@viewport}
            />
        </main>
      </.app_shell>
      <CommandPalette.mount_if_live
        current_scope={@current_scope}
        current_document_id={@studio_state.selected_document_id || assigns[:current_document_id]}
      />
      <Layouts.flash_group flash={@flash} />
    <% end %>
    """
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp current_document(scope, %Contract.Studio.State{selected_document_id: document_id})
       when is_binary(document_id) do
    case Documents.get(scope, document_id) do
      {:ok, document} -> document
      _ -> nil
    end
  end

  defp current_document(_scope, _state), do: nil

  defp list_other_documents(scope, %{selected_document_id: current_id}) do
    scope
    |> Contract.Documents.list_all_for_scope(limit: 30)
    |> Enum.reject(&(&1.status in [:template, :archived]))
    |> Enum.reject(&(&1.id == current_id))
    |> Enum.map(fn d -> %{id: d.id, title: d.title} end)
  rescue
    _ -> []
  end

  defp list_other_documents(_scope, _state), do: []

  defp export_format_label("pdf"), do: dgettext("studio", "PDF로 내려받기")
  defp export_format_label("docx"), do: dgettext("studio", "DOCX로 내려받기")
  defp export_format_label("hwpx"), do: dgettext("studio", "HWPX로 내려받기")
  defp export_format_label("markdown"), do: dgettext("studio", "Markdown으로 내려받기")
  defp export_format_label("lawyer_packet"), do: dgettext("studio", "변호사 패킷")
  defp export_format_label(other), do: to_string(other)

  # Estimate input `size=` for the editable title. The HTML `size` attribute
  # measures in average-glyph widths (effectively ASCII "0"). CJK glyphs
  # render roughly 2× wider, so a raw `String.length/1` count clips Korean
  # titles. Count CJK codepoints as 2, others as 1, then pad +2 for the
  # input's inner padding/caret breathing room.
  defp title_input_size(nil), do: 4

  defp title_input_size(s) when is_binary(s) do
    weighted =
      s
      |> String.graphemes()
      |> Enum.reduce(0, fn g, acc ->
        acc + if wide_glyph?(g), do: 2, else: 1
      end)

    max(weighted + 2, 4)
  end

  defp title_input_size(_), do: 4

  # Conservative CJK / fullwidth heuristic — anything outside U+0000..U+02AF
  # counts as wide. Covers Hangul, Han, Kana, fullwidth punctuation.
  defp wide_glyph?(<<cp::utf8>>) when cp > 0x02AF, do: true
  defp wide_glyph?(_), do: false

  defp document_header_title(%{title: title}, _projection, _state)
       when is_binary(title) and title != "",
       do: title

  defp document_header_title(_document, %{title: title}, _state)
       when is_binary(title) and title != "",
       do: title

  defp document_header_title(_document, _projection, %{selected_document_id: id})
       when is_binary(id),
       do: "Document " <> String.slice(id, 0, 8)

  defp document_header_title(_document, _projection, _state),
    do: dgettext("studio", "No document selected")

  # ContractTypes.display_name/1 accepts a string key, a TypeSpec, or
  # nil; the projection may be the empty-projection map (type_key: nil)
  # or a struct/map decoded from the snapshot. Always normalize to
  # `string | nil` so the dropdown's "currently selected" rendering and
  # the equality check against `spec.key` stay correct after a JSON
  # roundtrip.
  defp projection_type_key(%{type_key: tk}) when is_binary(tk) and tk != "", do: tk
  defp projection_type_key(_), do: nil

  defp document_status_label(%{status: status}) when is_binary(status) do
    case status do
      "draft" -> dgettext("studio", "초안")
      "review" -> dgettext("studio", "검토 중")
      "archived" -> dgettext("studio", "보관됨")
      _ -> status
    end
  end

  defp document_status_label(_), do: dgettext("studio", "초안")

  defp document_status_dot_modifier(%{status: "review"}), do: "status-dot--review"
  defp document_status_dot_modifier(%{status: "archived"}), do: "status-dot--archived"
  defp document_status_dot_modifier(_), do: "status-dot--draft"

  defp canvas_module(:briefing), do: Components.Canvas.Briefing
  defp canvas_module(:editing), do: Components.Canvas.Editor
  defp canvas_module(:reviewing), do: Components.Canvas.Review
  defp canvas_module(:no_document), do: Components.Canvas.Empty
  defp canvas_module(_), do: Components.Canvas.Empty

  defp page_title(_), do: "Studio"

  @doc false
  def test_operation_topic(user_id) when is_binary(user_id),
    do: "test:studio:operation_blocks:" <> user_id

  defp maybe_subscribe_test_operation_blocks(%Contract.Context{user: %{id: user_id}})
       when is_binary(user_id) do
    if Application.get_env(:contract, :test_auth, false) do
      Phoenix.PubSub.subscribe(Contract.PubSub, test_operation_topic(user_id))
    else
      :ok
    end
  end

  defp maybe_subscribe_test_operation_blocks(_scope), do: :ok

  defp build_breadcrumbs(scope, state, projection) do
    document = breadcrumb_document(scope, state, projection)
    Breadcrumbs.build(scope, page: :studio, matter: nil, document: document)
  end

  defp breadcrumb_document(_scope, _state, %{title: title}) when is_binary(title) and title != "",
    do: %{title: title}

  defp breadcrumb_document(scope, %{selected_document_id: document_id}, _projection)
       when is_binary(document_id) do
    case Contract.Documents.get(scope, document_id) do
      {:ok, %{title: title}} when is_binary(title) and title != "" -> %{title: title}
      _ -> nil
    end
  end

  defp breadcrumb_document(_scope, _state, _projection), do: nil

  defp empty_projection, do: Contract.Runtime.State.empty_projection()

  defp update_modal(socket, "document_picker", value),
    do: put_state_flag(socket, :document_picker_open?, value)

  defp update_modal(socket, "metadata", value),
    do: put_state_flag(socket, :metadata_panel_open?, value)

  defp update_modal(socket, "migration", value),
    do: put_state_flag(socket, :migration_panel_open?, value)

  defp update_modal(socket, "upload", value),
    do: put_state_flag(socket, :upload_panel_open?, value)

  defp update_modal(socket, "type_picker", value),
    do: put_state_flag(socket, :type_picker_open?, value)

  defp update_modal(socket, "export", value),
    do: put_state_flag(socket, :export_picker_open?, value)

  defp update_modal(socket, "reconcile", value),
    do: assign(socket, :reconcile_modal_open?, value)

  defp update_modal(socket, _other, _value), do: socket

  defp put_state_flag(socket, key, value) do
    update(socket, :studio_state, fn state -> Map.put(state, key, value) end)
  end

  # Push the last-committed change-id to the editor hook so Cmd+Z can
  # fire `revoke_change` with the right payload regardless of which DOM
  # node currently has focus. Skip revokes themselves and reconciled
  # changes so Cmd+Z never tries to revoke a revoke.
  defp push_editor_last_change(
         socket,
         %Contract.Change{command_kind: kind, status: status} = change
       )
       when kind in ["revoke_change", "resolve_revoke"]
       when status == :revoked do
    _ = change
    socket
  end

  defp push_editor_last_change(socket, %Contract.Change{} = change) do
    node_id =
      case change.affected_refs do
        refs when is_list(refs) ->
          Enum.find_value(refs, fn
            %{node_id: id} when is_binary(id) -> id
            %{"node_id" => id} when is_binary(id) -> id
            _ -> nil
          end)

        _ ->
          nil
      end

    push_event(socket, "editor:last-change", %{
      change_id: change.id,
      command_kind: change.command_kind,
      node_id: node_id
    })
  end

  defp recompute_grill_assigns(socket) do
    marks = (socket.assigns[:projection] || %{})[:marks] || %{}
    current_agent_run = socket.assigns[:studio_state] && socket.assigns.studio_state.agent_run_id

    grill_marks =
      if current_agent_run do
        marks
        |> Map.values()
        |> Enum.filter(fn m ->
          m[:intent] == :ask and
            get_in(m, [:data, "agent_run_id"]) == current_agent_run
        end)
      else
        []
      end

    socket
    |> assign(:grill_marks, grill_marks)
    |> assign(:grill_active?, grill_marks != [])
  end

  defp insert_operation_chat(socket, id, operation, opts \\ []) do
    stream_insert(socket, :chat_messages, %{
      id: to_string(id),
      role: :agent,
      operation: stringify_operation(operation),
      transient?: Keyword.get(opts, :transient?, false),
      timestamp: DateTime.utc_now()
    })
  end

  defp stringify_operation(operation) when is_map(operation) do
    operation
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_operation_value(value)} end)
    |> Map.new()
  end

  defp stringify_operation_value(%Decimal{} = value), do: Decimal.to_string(value)
  defp stringify_operation_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_operation_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_operation_value(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify_operation_value(%Time{} = value), do: Time.to_iso8601(value)

  defp stringify_operation_value(%_{} = value) do
    value
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> stringify_operation()
  end

  defp stringify_operation_value(value) when is_map(value), do: stringify_operation(value)

  defp stringify_operation_value(value) when is_list(value),
    do: Enum.map(value, &stringify_operation_value/1)

  defp stringify_operation_value(value), do: value

  defp normalize_operation_details(%_{} = value),
    do: value |> Map.from_struct() |> Map.drop([:__meta__])

  defp normalize_operation_details(value) when is_map(value), do: value
  defp normalize_operation_details(value), do: %{"value" => protocol_summary(value)}

  defp protocol_id(%{id: id}), do: id
  defp protocol_id(%{"id" => id}), do: id
  defp protocol_id(_), do: nil

  defp protocol_name(%{tool_name: name}) when is_binary(name), do: name
  defp protocol_name(%{name: name}) when is_binary(name), do: name
  defp protocol_name(%{"tool_name" => name}) when is_binary(name), do: name
  defp protocol_name(%{"name" => name}) when is_binary(name), do: name
  defp protocol_name(other), do: short_id(protocol_id(other))

  defp protocol_title(%{title: title}) when is_binary(title), do: title
  defp protocol_title(%{"title" => title}) when is_binary(title), do: title
  defp protocol_title(other), do: "source " <> short_id(protocol_id(other))

  defp protocol_summary(%{summary: summary}) when is_binary(summary), do: summary
  defp protocol_summary(%{"summary" => summary}) when is_binary(summary), do: summary
  defp protocol_summary(%{body: body}) when is_binary(body), do: body
  defp protocol_summary(%{"body" => body}) when is_binary(body), do: body
  defp protocol_summary(value) when is_binary(value), do: value
  defp protocol_summary(value) when is_atom(value), do: Atom.to_string(value)
  defp protocol_summary(value), do: inspect(value)

  defp tool_trace_title(result, fallback) do
    case protocol_raw_name(result) do
      "contract_ir.patch.apply" -> "답변을 수정 범위에 연결함"
      name when is_binary(name) and name != "" -> name
      _ -> fallback
    end
  end

  defp protocol_raw_name(%{raw_name: name}) when is_binary(name), do: name
  defp protocol_raw_name(%{"raw_name" => name}) when is_binary(name), do: name
  defp protocol_raw_name(%{tool_name: name}) when is_binary(name), do: name
  defp protocol_raw_name(%{"tool_name" => name}) when is_binary(name), do: name
  defp protocol_raw_name(%{name: name}) when is_binary(name), do: name
  defp protocol_raw_name(%{"name" => name}) when is_binary(name), do: name
  defp protocol_raw_name(_), do: nil

  defp protocol_status(%{status: status}), do: protocol_summary(status)
  defp protocol_status(%{"status" => status}), do: protocol_summary(status)
  defp protocol_status(_), do: "updated"

  defp build_toast(level, title, body) do
    %{
      id: "toast-" <> (Ecto.UUID.generate() |> String.replace("-", "")),
      level: level,
      title: title,
      body: body,
      inserted_at: DateTime.utc_now()
    }
  end

  defp request_summary(%{id: id}), do: "Request #{short_id(id)}"
  defp request_summary(_), do: "Pending revoke."

  defp import_summary(%{title: title}) when is_binary(title), do: title
  defp import_summary(%{id: id}) when is_binary(id), do: "Document " <> short_id(id)
  defp import_summary(_), do: "Document imported."

  defp export_status_summary(%{download_url: url}) when is_binary(url), do: url

  defp export_status_summary(%{id: id, progress: progress}) when is_binary(id),
    do: "Export #{short_id(id)} · #{progress}%"

  defp export_status_summary(_), do: "Export status updated."

  defp export_summary(%{download_url: url}) when is_binary(url), do: url
  defp export_summary(%{id: id}) when is_binary(id), do: "Export " <> short_id(id)
  defp export_summary(_), do: "Export ready."

  defp short_id(nil), do: "?"

  defp short_id(id) when is_binary(id) do
    case String.split(id, "-", parts: 2) do
      [head | _] -> head
      _ -> String.slice(id, 0, 8)
    end
  end

  defp short_id(other), do: inspect(other)

  defp stream_event_id(agent_run_id, %{id: id}) when not is_nil(id),
    do: "agent-#{agent_run_id}-#{id}"

  defp stream_event_id(agent_run_id, _event),
    do: "agent-#{agent_run_id}-" <> Integer.to_string(System.unique_integer([:positive]))

  # ---------------------------------------------------------------------------
  # Auto-grill seed on cold document open. When the user lands on a document
  # that (a) has body content, (b) has an empty chat thread, and (c) is not
  # already mid-agent-run, dispatch a hidden `:chat_message` Command carrying
  # `payload["grill_seed"] => true`. The Command's user-side row is persisted
  # with role `"system"` so the visible rail stays empty until the agent's
  # first turn lands.
  # ---------------------------------------------------------------------------
  @grill_seed_message "GRILL_SEED: 사용자에게 인사하고, 이 계약 문서를 한 단락으로 요약한 뒤, 프로젝트 맥락을 묻는 1-3개의 한국어 질문을 한 메시지에 담아 시작하세요."

  defp maybe_dispatch_grill_seed(socket, visible_messages) do
    if should_dispatch_grill_seed?(socket, visible_messages) do
      dispatch_grill_seed(socket)
    else
      socket
    end
  end

  defp should_dispatch_grill_seed?(socket, visible_messages) do
    state = socket.assigns[:studio_state]
    projection = socket.assigns[:projection]

    not is_nil(state) and is_binary(state.selected_document_id) and
      is_nil(state.agent_run_id) and
      visible_messages == [] and
      has_summarizable_body?(projection)
  end

  defp has_summarizable_body?(%{nodes: nodes}) when is_map(nodes) and map_size(nodes) > 0 do
    Enum.any?(nodes, fn {_id, node} -> summarizable_node?(node) end)
  end

  defp has_summarizable_body?(_), do: false

  @summarizable_kinds ~w(paragraph heading list_item section)

  defp summarizable_node?(%{} = node) do
    kind = node[:kind] || node["kind"]

    to_string(kind) in @summarizable_kinds and
      String.trim(to_string(node[:content] || node["content"] || "")) != ""
  end

  defp summarizable_node?(_), do: false

  defp dispatch_grill_seed(socket) do
    state = socket.assigns.studio_state
    projection = socket.assigns.projection

    action = %Command{
      kind: :chat_message,
      actor_type: :system,
      actor_id: nil,
      document_id: state.selected_document_id,
      base_revision: state.last_seen_revision,
      idempotency_key: "grill-seed:" <> state.selected_document_id,
      payload: %{
        "grill_seed" => true,
        "grill_seed_nodes" => grill_seed_nodes_payload(projection)
      },
      message: @grill_seed_message
    }

    dispatch(socket, action)
  end

  defp grill_seed_nodes_payload(%{nodes: nodes, node_order: order})
       when is_map(nodes) and is_list(order) and order != [] do
    order
    |> Enum.map(&Map.get(nodes, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&summarizable_node?/1)
    |> Enum.take(25)
    |> Enum.map(
      &%{
        "kind" => to_string(&1[:kind] || &1["kind"]),
        "content" => &1[:content] || &1["content"] || ""
      }
    )
  end

  defp grill_seed_nodes_payload(%{nodes: nodes}) when is_map(nodes) do
    nodes
    |> Map.values()
    |> Enum.filter(&summarizable_node?/1)
    |> Enum.take(25)
    |> Enum.map(
      &%{
        "kind" => to_string(&1[:kind] || &1["kind"]),
        "content" => &1[:content] || &1["content"] || ""
      }
    )
  end

  defp grill_seed_nodes_payload(_), do: []
end
