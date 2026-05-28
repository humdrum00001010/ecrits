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
          agent_run_id: nil
        },

        # Derived per-mount
        projection: %{nodes: ..., fields: ..., marks: ..., refs: ...},
        breadcrumbs: [%{label, navigate, current?}],
        page_title: "Studio · <matter_name>",
        # LV streams (preferred over assign for collections, LV 1.1)
        streams: %{
          chat_messages: stream,
          changes: stream,
          toasts: stream
        },

        # Viewport (set by the .Viewport JS hook on connect)
        viewport: :desktop | :mobile,

      }

  ## Dispatch funnel

  `event_to_command/2` is the ONE place UI events become Commands. Components
  fire `phx-click="<event_name>"` and let the shell build the typed action.
  Clauses:

      "rename_document"       → :rename_document
      "set_contract_type"     → :set_contract_type
      "send_chat_message"     → :chat_message
      "open_document"         → :open_document
      "duplicate_document"    → :duplicate_document
      "command_palette_picked" → resolved to the right Command.kind

  Local-only UI events (no Command emitted):

      "open_modal", "close_modal", "viewport_change", "noop"

  ## Protocol messages (§11)

  `handle_info/2` is the LiveView protocol surface. Every message type is
  pattern-matched explicitly. See `handle_protocol_message/2`.
  """

  use ContractWeb, :live_view

  alias Contract.ChatThreads
  alias Contract.Command
  alias Contract.ContractTypes
  alias Contract.Documents
  alias Contract.Projects
  alias Contract.Studio
  alias ContractWeb.Components.Breadcrumbs
  alias ContractWeb.Components.CommandPalette
  alias ContractWeb.Live.Studio.Components

  @mobile_viewport_max_width 767

  @impl true
  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope
    project_id = project_id_from_params(scope, params)

    case Studio.open(scope, params) do
      {:ok, {studio_state, projection}} ->
        _ = Studio.subscribe(scope, studio_state.selected_document_id)
        _ = Studio.subscribe_agent(scope, studio_state.agent_run_id)
        _ = maybe_subscribe_test_operation_blocks(scope)

        _ =
          if connected?(socket) do
            register_rhwp_materializer_editor(studio_state.selected_document_id)
          end

        breadcrumbs = build_breadcrumbs(scope, studio_state, projection)

        socket =
          socket
          |> assign(:current_scope, scope)
          |> assign(:project_id, project_id)
          |> assign(:studio_state, studio_state)
          |> assign_projection(projection)
          |> assign(:current_document, current_document(scope, studio_state))
          |> assign(:chat_thread, ChatThreads.current_thread_info(scope, studio_state))
          |> assign(:agent_document_status, nil)
          |> assign(:breadcrumbs, breadcrumbs)
          |> assign(:page_title, page_title(scope))
          |> assign(:viewport, :desktop)
          |> assign(:chat_rail_hidden?, false)
          |> assign(:other_documents, list_other_documents(scope, studio_state))
          |> then(fn s ->
            assign_rhwp_snapshot_state(
              s,
              studio_state.selected_document_id,
              rhwp_snapshot_format(projection)
            )
          end)
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
          |> refresh_agent_document_status()

        {:ok, socket}

      {:error, reason} ->
        socket =
          socket
          |> put_flash(:error, "Could not load Studio: #{inspect(reason)}")
          |> assign(:project_id, nil)
          |> assign(:studio_state, %Contract.Studio.State{mode: :no_document})
          |> assign_projection(empty_projection())
          |> assign(:current_document, nil)
          |> assign(:chat_thread, nil)
          |> assign(:agent_document_status, nil)
          |> assign(:rhwp_snapshot, nil)
          |> assign(:rhwp_snapshot_candidates, [])
          |> assign(:rhwp_text_events, [])
          |> assign(:breadcrumbs, build_breadcrumbs(scope, nil, nil))
          |> assign(:page_title, "Studio")
          |> assign(:viewport, :desktop)
          |> assign(:chat_rail_hidden?, false)
          |> assign(:other_documents, list_other_documents(scope, %{selected_document_id: nil}))
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
    viewport = if w > @mobile_viewport_max_width, do: :desktop, else: :mobile
    {:noreply, assign(socket, :viewport, viewport)}
  end

  def handle_event("viewport_change", %{"w" => w}, socket) when is_binary(w) do
    case Integer.parse(w) do
      {n, _} -> handle_event("viewport_change", %{"w" => n}, socket)
      :error -> {:noreply, socket}
    end
  end

  def handle_event("filter_contract_types", %{"q" => query}, socket) when is_binary(query) do
    {:noreply,
     socket
     |> assign(:contract_type_query, query)
     |> assign(:contract_type_picker_open?, true)}
  end

  def handle_event("close_contract_type_picker", _params, socket) do
    {:noreply, assign(socket, :contract_type_picker_open?, false)}
  end

  def handle_event("toggle_chat_rail", _params, socket) do
    {:noreply, update(socket, :chat_rail_hidden?, &(!&1))}
  end

  def handle_event("cancel_agent", _params, socket) do
    studio_state = socket.assigns.studio_state

    case studio_state.agent_run_id do
      run_id when is_binary(run_id) ->
        _ = cancel_agent_run(socket.assigns.current_scope, studio_state, run_id)

        socket =
          socket
          |> remove_agent_transient_rows(run_id)
          |> assign(:studio_state, %{studio_state | agent_run_id: nil})
          |> refresh_agent_document_status()

        {:noreply, socket}

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

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # rhwp canvas mutation envelope → :edit_text Command → Session.commit → changes append.
  # envelope: %{"siteId", "documentId", "lamport", "eventId", "body" => DocumentEvent}
  def handle_event("rhwp.text.mutated", envelope, socket) do
    require Logger
    scope = socket.assigns.current_scope
    document_id = socket.assigns.studio_state.selected_document_id
    body = envelope["body"] || %{}

    op = rhwp_envelope_to_text_op(body, envelope)

    command = %Contract.Command{
      kind: :edit_text,
      document_id: document_id,
      actor_type: :user,
      actor_id: scope.user.id,
      idempotency_key: envelope["eventId"],
      payload: %{ops: [op]}
    }

    case Contract.Runtime.apply(scope, command) do
      {:ok, _change} ->
        :ok

      {:error, reason} ->
        Logger.warning("rhwp.text.mutated apply failed: #{inspect(reason)}")
    end

    {:noreply, socket}
  end

  # rhwp 스냅샷 컴팩션 — client 가 원본 형식을 보존한 HWP/HWPX bytes 를 보내고,
  # server 가 native blob + companion IR + rhwp_snapshots row 를 단일 경로로 쓴다.
  def handle_event("rhwp.snapshot.upload", %{"bytes_base64" => encoded} = params, socket)
      when is_binary(encoded) do
    document_id = socket.assigns.studio_state.selected_document_id
    requested_document_id = params["document_id"] || params[:document_id]
    request_id = params["request_id"] || params[:request_id]
    ir = if is_map(params["ir"]), do: params["ir"], else: %{}
    format = params["format"] || params[:format]
    min_revision = normalize_rhwp_min_revision(params["min_revision"] || params[:min_revision])

    with true <- is_binary(document_id),
         :ok <- verify_rhwp_snapshot_document_id(document_id, requested_document_id),
         {:ok, format} <- Contract.RhwpSnapshot.normalize_format(to_string(format || "")),
         {:ok, revision} <- Contract.Store.latest_revision(document_id),
         :ok <- verify_rhwp_min_revision(revision, min_revision),
         {:ok, bytes} <- Base.decode64(encoded),
         {:ok, snapshot} <-
           Contract.RhwpSnapshot.upload_and_commit(document_id, revision, bytes, ir, format) do
      socket = assign_rhwp_snapshot_state(socket, document_id, snapshot.format)
      _ = ack_rhwp_snapshot_committed(request_id, document_id, snapshot)

      {:reply,
       %{
         ok: true,
         revision: snapshot.revision,
         key: snapshot.r2_key,
         format: snapshot.format
       }, socket}
    else
      false ->
        _ = ack_rhwp_snapshot_failed(request_id, document_id, :no_document)
        {:reply, %{error: "no_document"}, socket}

      :error ->
        _ = ack_rhwp_snapshot_failed(request_id, document_id, :invalid_base64)
        {:reply, %{error: "invalid_base64"}, socket}

      {:error, reason} ->
        require Logger
        Logger.warning("rhwp.snapshot.upload failed: #{inspect(reason)}")
        _ = ack_rhwp_snapshot_failed(request_id, document_id, reason)
        {:reply, %{error: inspect(reason)}, socket}
    end
  end

  def handle_event(
        "rhwp.snapshot.upload",
        %{"request_id" => request_id, "error" => error} = params,
        socket
      )
      when is_binary(request_id) do
    document_id =
      params["document_id"] || params[:document_id] ||
        socket.assigns.studio_state.selected_document_id

    _ = ack_rhwp_snapshot_failed(request_id, document_id, error)
    {:reply, %{error: to_string(error)}, socket}
  end

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
        {:noreply, socket} = handle_event("set_contract_type", %{"type_key" => type_key}, socket)
        {:noreply, put_state_flag(socket, :type_picker_open?, false)}

      _ ->
        # No type_key → open the type-picker modal. Driven by a flag on
        # `studio_state` (mirroring metadata panel) so the
        # ModalHost re-renders synchronously on the next paint without
        # needing a `send_update/2` round-trip.
        {:noreply, put_state_flag(socket, :type_picker_open?, true)}
    end
  end

  # ---------------------------------------------------------------------------
  # No-document agent prompt — SPEC.md §10. ChatRail renders 5 quick-start
  # chips when `studio_state.mode == :no_document`; each chip fires
  # `agent_option_picked` with a `key`. We route to the corresponding modal
  # or to a Documents.create flow.
  # ---------------------------------------------------------------------------

  def handle_event("chat.context_reset", _params, socket) do
    if socket.assigns.studio_state.agent_run_id do
      {:noreply, put_flash(socket, :info, "에이전트 응답이 끝난 뒤 새 컨텍스트를 시작할 수 있습니다.")}
    else
      case ChatThreads.reset_context(socket.assigns.current_scope, socket.assigns.studio_state) do
        {:ok, _} ->
          {:noreply,
           socket
           |> stream(:chat_messages, [], reset: true)
           |> assign_current_chat_thread()}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not reset chat context: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("chat.thread.rename", %{"title" => title}, socket) when is_binary(title) do
    case ChatThreads.rename_context(
           socket.assigns.current_scope,
           socket.assigns.studio_state,
           title
         ) do
      {:ok, _thread} ->
        {:noreply, assign_current_chat_thread(socket)}

      {:error, :not_found} ->
        {:noreply, assign_current_chat_thread(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not rename chat context: #{inspect(reason)}")}
    end
  end

  def handle_event("chat.thread.rename", _params, socket), do: {:noreply, socket}

  def handle_event("set_contract_type", %{"type_key" => type_key}, socket)
      when is_binary(type_key) do
    current_type_key = projection_type_key(socket.assigns.projection)

    cond do
      is_nil(socket.assigns.studio_state.selected_document_id) ->
        create_blank_document(socket, type_key)

      is_nil(current_type_key) ->
        handle_contract_event("set_contract_type", %{"type_key" => type_key}, socket)

      current_type_key == type_key ->
        {:noreply, socket}

      true ->
        {:noreply, reject_contract_type_replacement(socket)}
    end
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

  def handle_event(
        "rhwp.matching_book.changed",
        %{"contract_type_key" => type_key, "matching_book" => matching_book},
        socket
      )
      when is_binary(type_key) and is_map(matching_book) do
    if type_key == projection_type_key(socket.assigns.projection) do
      case ContractTypes.upsert_matching_book(type_key, matching_book) do
        {:ok, _row} -> {:noreply, assign(socket, :rhwp_matching_book, matching_book)}
        {:error, _reason} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "rhwp.field_value.changed",
        %{"field_id" => field_id, "value" => value},
        socket
      )
      when is_binary(field_id) do
    {:noreply, persist_rhwp_field_value(socket, field_id, stringify_rhwp_field_value(value))}
  end

  def handle_event(event, params, socket) do
    handle_contract_event(event, params, socket)
  end

  defp reject_contract_type_replacement(socket) do
    socket
    |> assign(:contract_type_picker_open?, false)
    |> put_state_flag(:type_picker_open?, false)
    |> put_flash(:error, dgettext("studio", "문서 타입은 선택 후 변경할 수 없습니다."))
  end

  defp handle_contract_event(event, params, socket) do
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
  defp create_blank_document(socket, type_key \\ nil) do
    scope = socket.assigns.current_scope
    title = blank_document_title(type_key)

    action = %Command{
      kind: :create_document,
      actor_type: :user,
      actor_id: scope && scope.user && scope.user.id,
      base_revision: 0,
      idempotency_key: generate_idempotency_key(),
      payload: %{"title" => title, "type_key" => type_key}
    }

    case Contract.Runtime.apply(scope, action) do
      {:ok, %Contract.Change{document_id: document_id}} ->
        case attach_created_document(socket, document_id) do
          :ok ->
            {:noreply, push_navigate(socket, to: created_document_path(socket, document_id))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "프로젝트에 문서를 연결할 수 없습니다.")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "문서 생성에 실패했습니다.")}
    end
  end

  defp blank_document_title(type_key) when is_binary(type_key) and type_key != "" do
    ContractTypes.display_name(type_key)
  end

  defp blank_document_title(_type_key), do: "새 계약서"

  defp attach_created_document(socket, document_id) do
    case socket.assigns[:project_id] do
      project_id when is_binary(project_id) ->
        case Projects.attach_document(socket.assigns.current_scope, project_id, document_id, %{
               role: "primary"
             }) do
          {:ok, _project_document} -> :ok
          {:error, _reason} = error -> error
        end

      _ ->
        :ok
    end
  end

  defp created_document_path(socket, document_id) do
    case socket.assigns[:project_id] do
      project_id when is_binary(project_id) -> ~p"/documents/#{document_id}"
      _ -> ~p"/studio/#{document_id}"
    end
  end

  defp project_id_from_params(scope, %{"project_id" => project_id}) when is_binary(project_id) do
    case Projects.get_project(scope, project_id) do
      {:ok, _project} -> project_id
      _ -> nil
    end
  end

  defp project_id_from_params(_scope, _params), do: nil

  # ----------------------------------------------------------------------------
  # handle_info/2
  # ----------------------------------------------------------------------------

  @impl true
  def handle_info(message, socket) do
    # NOTE: do NOT add any unconditional `assign/3` here. Each unique value
    # forces LV to diff the entire studio template on every PubSub
    # message, which was throttling per-token streaming to ~7Hz in dev
    # (~140ms render per delta) even though OpenAI was sending 38 deltas/s.
    {:noreply, handle_protocol_message(message, socket)}
  end

  @impl true
  def terminate(_reason, socket) do
    unregister_rhwp_materializer_editor(socket.assigns[:studio_state])
    :ok
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
    socket = maybe_cancel_in_flight_agent(socket, action)
    scope = socket.assigns.current_scope
    state = socket.assigns.studio_state

    case Studio.command_result(scope, state, action) do
      {:ok, %Contract.Studio.State{} = new_state, result} ->
        socket
        |> assign(:studio_state, new_state)
        |> refresh_agent_document_status()
        |> then(fn socket ->
          assign(socket, :current_document, current_document(scope, socket.assigns.studio_state))
        end)
        |> apply_submit_result(action, result)
        |> then(fn socket ->
          maybe_refresh_chat_messages(socket, action, socket.assigns.studio_state)
        end)

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

    socket
    |> stream(:chat_messages, messages, reset: true)
    |> maybe_insert_agent_loading_message(state.agent_run_id)
    |> assign_current_chat_thread()
  end

  defp maybe_refresh_chat_messages(socket, _action, _state), do: socket

  # When the user submits another chat message while a previous agent run
  # is still streaming, cancel the in-flight run so only the latest message
  # gets answered. The cancel also clears agent_run_id on studio_state, so
  # the downstream dispatch starts from a clean slate.
  defp maybe_cancel_in_flight_agent(socket, %Command{kind: :chat_message}) do
    state = socket.assigns.studio_state

    case state && state.agent_run_id do
      run_id when is_binary(run_id) ->
        _ =
          Contract.Agent.Document.suspend(
            socket.assigns.current_scope,
            state.selected_document_id
          )

        socket
        |> remove_agent_transient_rows(run_id)
        |> assign(:studio_state, %{state | agent_run_id: nil})
        |> refresh_agent_document_status()

      _ ->
        socket
    end
  end

  defp maybe_cancel_in_flight_agent(socket, _action), do: socket

  defp cancel_agent_run(scope, state, run_id) do
    case Contract.Agent.Document.cancel(scope, run_id) do
      {:error, :not_found} ->
        Contract.Agent.Document.suspend(scope, state.selected_document_id)

      result ->
        result
    end
  end

  defp refresh_agent_document_status(socket) do
    status =
      fetch_agent_document_status(
        socket.assigns[:current_scope],
        socket.assigns[:studio_state]
      )

    current_run_id = agent_document_current_run_id(status)
    old_run_id = agent_document_current_run_id(socket.assigns[:agent_document_status])

    if is_binary(current_run_id) and current_run_id != old_run_id do
      _ = Studio.subscribe_agent(socket.assigns.current_scope, current_run_id)
    end

    socket
    |> assign(:agent_document_status, status)
    |> update(:studio_state, fn
      %Contract.Studio.State{} = state -> %{state | agent_run_id: current_run_id}
      state -> state
    end)
  end

  defp fetch_agent_document_status(scope, %Contract.Studio.State{} = state) do
    case Contract.Agent.Document.status(scope, state.selected_document_id) do
      {:ok, status} -> status
      {:error, _reason} -> nil
    end
  end

  defp fetch_agent_document_status(_scope, _state), do: nil

  defp agent_document_current_run_id(%{current_attempt: %{id: id}}) when is_binary(id), do: id
  defp agent_document_current_run_id(_status), do: nil

  defp assign_current_chat_thread(socket) do
    assign(
      socket,
      :chat_thread,
      ChatThreads.current_thread_info(socket.assigns.current_scope, socket.assigns.studio_state)
    )
  end

  defp apply_submit_result(socket, %Command{kind: :set_contract_type}, %Contract.Change{}) do
    reload_current_document(socket)
  end

  defp apply_submit_result(socket, _action, _result), do: socket

  defp reload_current_document(socket) do
    scope = socket.assigns.current_scope
    state = socket.assigns.studio_state

    case Studio.reload(scope, state) do
      {:ok, {%Contract.Studio.State{} = new_state, projection}} ->
        socket
        |> assign(:studio_state, new_state)
        |> assign_projection(projection)
        |> assign(:current_document, current_document(scope, new_state))

      {:error, _reason} ->
        socket
    end
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

  def event_to_command("document.open", params, assigns),
    do: build_action(assigns, :open_document, params)

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

  # Compatibility aliases for pre-dotted event producers. Product UI should use
  # the dotted clauses above.
  def event_to_command("rename_document", params, assigns) do
    build_action(assigns, :rename_document, params)
  end

  def event_to_command("set_contract_type", params, assigns) do
    build_action(assigns, :set_contract_type, params)
  end

  def event_to_command("send_chat_message", params, assigns) do
    build_action(assigns, :chat_message, params, document_required: false)
  end

  def event_to_command("update_metadata", params, assigns) do
    build_action(assigns, :update_metadata, params)
  end

  def event_to_command("open_document", params, assigns) do
    build_action(assigns, :open_document, params)
  end

  def event_to_command("duplicate_document", params, assigns) do
    build_action(assigns, :duplicate_document, params)
  end

  def event_to_command("command_palette_picked", %{"kind" => kind} = params, assigns)
      when is_binary(kind) do
    params = Map.drop(params, ["kind", "action_kind", "command_kind"])

    cond do
      removed_command_kind?(kind) ->
        {:error, {:removed_command, kind}}

      String.contains?(kind, ".") ->
        event_to_command(kind, params, assigns)

      true ->
        build_action(assigns, String.to_existing_atom(kind), params, document_required: false)
    end
  rescue
    ArgumentError -> {:error, {:unknown_palette_kind, kind}}
  end

  # Local-only UI events (no Command emitted).
  def event_to_command(local, _params, _assigns)
      when local in [
             "open_modal",
             "close_modal",
             "viewport_change"
           ] do
    :local
  end

  def event_to_command(event, _params, _assigns) do
    {:error, {:unknown_event, event}}
  end

  defp removed_command_kind?(kind) do
    kind in [
      "document.upload",
      "upload_document",
      "source_claim.confirm",
      "source_claim.correct",
      "source_claim.reject",
      "source_claim.link_to_document",
      "source_claim.unlink",
      "revoke.resolve",
      "request_export",
      "export.request",
      "conversion.create_variant",
      "create_variant"
    ]
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
    previous_document_id = socket.assigns.studio_state.selected_document_id

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
        |> assign_projection(projection)
        |> assign(:current_document, current_document(socket.assigns.current_scope, new_state))
        |> then(fn socket ->
          update_rhwp_materializer_editor(previous_document_id, new_state.selected_document_id)
          socket
        end)

      {:error, _} ->
        socket
    end
  end

  def handle_protocol_message({:rhwp_positional_index_request, request}, socket) do
    selected_document_id = socket.assigns.studio_state.selected_document_id
    request_id = rhwp_request_value(request, [:request_id, "request_id"])
    requested_document_id = rhwp_request_value(request, [:document_id, "document_id"])
    min_revision = rhwp_request_value(request, [:min_revision, "min_revision"])
    text_events = rhwp_request_value(request, [:text_events, "text_events"]) || []
    base_snapshot = rhwp_request_value(request, [:base_snapshot, "base_snapshot"])
    document_id = requested_document_id || selected_document_id

    cond do
      not is_binary(request_id) or request_id == "" ->
        socket

      not is_binary(selected_document_id) ->
        _ = ack_rhwp_snapshot_failed(request_id, document_id, :no_document)
        socket

      is_binary(document_id) and document_id != selected_document_id ->
        _ = ack_rhwp_snapshot_failed(request_id, document_id, :document_mismatch)
        socket

      true ->
        push_event(socket, "rhwp:positional_index.request", %{
          request_id: request_id,
          document_id: selected_document_id,
          min_revision: min_revision,
          text_events: text_events,
          base_snapshot: base_snapshot
        })
    end
  end

  def handle_protocol_message({:change_committed, %Contract.Change{} = change}, socket) do
    socket
    |> update(:studio_state, fn state ->
      state =
        if change.result_revision &&
             change.result_revision > (state.last_seen_revision || 0) do
          %{state | last_seen_revision: change.result_revision}
        else
          state
        end

      mark_agent_authored_nodes(state, change)
    end)
    |> stream_insert(:changes, change, at: 0)
    |> append_rhwp_text_events(change)
    |> push_rhwp_remote_text(change)
    |> recompute_grill_assigns()
  end

  def handle_protocol_message({:revision_conflict, change_id, node_id}, socket) do
    push_event(socket, "editor-revert", %{node_id: node_id, change_id: change_id})
  end

  def handle_protocol_message({:dismiss_toast, toast_id}, socket) do
    stream_delete(socket, :toasts, %{id: toast_id})
  end

  def handle_protocol_message({:marks_changed, marks}, socket) when is_map(marks) do
    socket
    |> update(:projection, fn proj -> Map.put(proj, :marks, marks) end)
    |> recompute_grill_assigns()
  end

  # Raw OpenAI stream events arrive via `:agent_stream` but we don't render
  # one bubble per event — that produced 100+ empty bubbles per turn. The
  # final assistant text appears via `:agent_completed` + ChatThreads
  # refresh; tool calls via `:tool_call_*` (MCP-side broadcasts); reasoning
  # via `:agent_reasoning_*` (classify_stream_event in Agent.Document). The raw
  # broadcast still flows so tests / future text-streaming UI can subscribe.
  def handle_protocol_message({:agent_stream, _agent_run_id, _stream_event}, socket),
    do: socket

  def handle_protocol_message({:agent_completed, agent_run_id, result}, socket) do
    body =
      case result do
        %Command{message: msg} when is_binary(msg) -> msg
        msg when is_binary(msg) -> msg
        _ -> ""
      end

    # Same DOM id as the streaming bubble so the in-place update replaces
    # the transient streaming text with the final reply rather than
    # appending a separate bubble.
    bubble = %{
      id: "agent-#{agent_run_id}-streaming",
      agent_run_id: agent_run_id,
      role: :agent,
      body: body,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      transient?: false
    }

    socket
    |> clear_agent_loading_state(agent_run_id)
    |> maybe_remove_unfinished_reasoning(agent_run_id)
    |> update(:studio_state, fn state ->
      if state.agent_run_id == agent_run_id do
        %{state | agent_run_id: nil}
      else
        state
      end
    end)
    |> refresh_agent_document_status()
    |> stream_insert(:chat_messages, bubble)
    |> recompute_grill_assigns()
    |> assign_current_chat_thread()
  end

  def handle_protocol_message({:agent_failed, agent_run_id, :cancelled}, socket) do
    socket
    |> remove_agent_transient_rows(agent_run_id)
    |> update(:studio_state, fn state ->
      if state.agent_run_id == agent_run_id do
        %{state | agent_run_id: nil}
      else
        state
      end
    end)
    |> refresh_agent_document_status()
    |> recompute_grill_assigns()
  end

  def handle_protocol_message({:agent_failed, agent_run_id, reason}, socket) do
    socket
    |> remove_agent_transient_rows(agent_run_id)
    |> update(:studio_state, fn state ->
      if state.agent_run_id == agent_run_id do
        %{state | agent_run_id: nil}
      else
        state
      end
    end)
    |> refresh_agent_document_status()
    |> stream_insert(:toasts, build_toast(:error, "Agent failed", inspect(reason)))
    |> recompute_grill_assigns()
  end

  def handle_protocol_message({:agent_text_delta, agent_run_id, piece}, socket) do
    # IMPORTANT: track "have we created the bubble for this run yet?" in
    # the LV process dict, NOT in assigns. Putting it in assigns triggers
    # a render diff on every delta (~30-40ms in dev each), throttling the
    # stream to ~15Hz even though OpenAI sends 38Hz. Process dict is per
    # LV process state with no diff cost.
    first? = not text_bubble_created?(agent_run_id)

    socket =
      if first? do
        mark_text_bubble_created(agent_run_id)
        # Fallback for runs not pre-seeded by `chat.submit`
        # (e.g. backend-initiated agent runs without a user-triggered
        # `maybe_insert_agent_loading_message`). The common path already
        # has this bubble inserted.
        stream_insert(socket, :chat_messages, agent_loading_message(agent_run_id))
      else
        socket
      end

    mark_text_stream_started(agent_run_id)

    # push_event is the per-token live path. The JS ChatInput hook listens
    # for phx:agent_text_append and appends the piece into the bubble's
    # text span. No assigns mutated here → no diff → no throttle.
    # Collapse `\n\n+` → `\n` here (same as msg_body/1 for persisted
    # messages) so paragraph-break runs don't open big visual gaps under
    # `whitespace-pre-wrap`.
    push_event(socket, "agent_text_append", %{
      message_id: "chat-msg-agent-#{agent_run_id}-streaming",
      piece: String.replace(piece, ~r/\n{2,}/, "\n")
    })
  end

  def handle_protocol_message({:agent_reasoning_delta, agent_run_id, text}, socket) do
    if not is_binary(text) or String.trim(text) == "" do
      socket
    else
      # The reasoning bubble was pre-inserted at chat.submit time
      # (`maybe_insert_agent_loading_message`) so the row is already
      # anchored above any tool_calls — we just append to its DOM here.
      # No stream_insert per delta: that would push N diffs/turn through
      # LV and throttle the per-token stream (see `agent_text_delta`).
      # The accumulated text is persisted on `:agent_reasoning_done`.
      push_event(socket, "agent_reasoning_append", %{
        message_id: "chat-msg-reasoning-#{agent_run_id}",
        piece: text
      })
    end
  end

  def handle_protocol_message({:agent_reasoning_done, agent_run_id, text}, socket) do
    mark_reasoning_stream_completed(agent_run_id)

    body = if is_binary(text) and text != "", do: text, else: ""

    if String.trim(body) == "" do
      stream_delete_by_dom_id(socket, :chat_messages, "chat-msg-reasoning-#{agent_run_id}")
    else
      _ =
        ChatThreads.append_reasoning_message(current_chat_thread_id(socket), %{
          agent_run_id: agent_run_id,
          body: body
        })

      stream_insert(
        socket,
        :chat_messages,
        reasoning_bubble(agent_run_id, body, transient?: false)
      )
    end
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
      transient?: true,
      agent_run_id: agent_run_id
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
      transient?: true,
      agent_run_id: agent_run_id
    )
  end

  def handle_protocol_message({:tool_call_completed, agent_run_id, tool_call_id, result}, socket) do
    insert_operation_chat(
      socket,
      "tool-#{agent_run_id}-#{tool_call_id}",
      %{
        id: "tool-#{agent_run_id}-#{tool_call_id}",
        type: "tool_call",
        title: tool_trace_title(result, "도구 실행"),
        status: "completed",
        summary: protocol_summary(result),
        details: normalize_operation_details(result)
      },
      agent_run_id: agent_run_id
    )
  end

  def handle_protocol_message({:tool_call_failed, agent_run_id, tool_call_id, reason}, socket) do
    insert_operation_chat(
      socket,
      "tool-#{agent_run_id}-#{tool_call_id}",
      %{
        id: "tool-#{agent_run_id}-#{tool_call_id}",
        type: "tool_call",
        title: tool_trace_title(reason, "도구 실행"),
        status: "failed",
        summary: protocol_summary(reason),
        details: normalize_operation_details(reason)
      },
      agent_run_id: agent_run_id
    )
  end

  def handle_protocol_message({:session_stale, document_id}, socket)
      when is_binary(document_id) do
    Process.send_after(self(), {:reconnect_attempt, document_id}, 500)

    # Same UI as Phoenix's standard #client-error topbar — driven via the
    # SessionStaleToggle hook in layouts.flash_group. We don't dump a
    # warning toast for this because lease-stale auto-recovers behind the
    # scenes and the toast was getting confused for a WebSocket drop.
    push_event(socket, "session-stale", %{})
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

    # Hide the topbar (counterpart to the push in :session_stale above).
    push_event(socket, "session-recovered", %{revision: revision})
  end

  def handle_protocol_message({:reconnect_attempt, document_id}, socket)
      when is_binary(document_id) do
    case Studio.reload(socket.assigns.current_scope, socket.assigns.studio_state) do
      {:ok, {new_state, projection}} ->
        socket
        |> assign(:studio_state, new_state)
        |> assign_projection(projection)

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

  def handle_protocol_message({:import_failed, import_id, reason}, socket) do
    stream_insert(
      socket,
      :toasts,
      build_toast(:error, "Import failed (#{short_id(import_id)})", inspect(reason))
    )
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
    <% standard_template = standard_template_spec(@projection) %>
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
          agent_document_status={@agent_document_status}
          streams={%{chat_messages: @streams.chat_messages}}
          current_scope={@current_scope}
          layout={:mobile_full}
          chat_thread={@chat_thread}
          grill_marks={@grill_marks}
          grill_active?={@grill_active?}
        />

        <.live_component
          module={Components.ModalHost}
          id="modal-host"
          studio_state={@studio_state}
          current_scope={@current_scope}
          projection={@projection}
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
            "h-[calc(100vh-60px)] min-h-[calc(100vh-60px)] w-full overflow-hidden pr-[var(--chat-rail-width)]",
            @chat_rail_hidden? && "!pr-0"
          ]}
        >
          <%!-- Desktop: document canvas + right chat rail. No permanent Context Reservoir. --%>
          <section class="flex h-full min-w-0 min-h-0 flex-col overflow-hidden bg-transparent">
            <header
              id="studio-document-header"
              class="flex items-center justify-between gap-2.5 min-h-[58px] px-5 border-b border-base-300 bg-base-100 max-sm:flex-wrap max-sm:min-h-0 max-sm:px-4 max-sm:py-3"
            >
              <div class="inline-flex items-center gap-1 min-w-0">
                <div class="inline-flex min-w-0 items-center">
                  <form
                    id="studio-document-title-form"
                    phx-submit="rename_document"
                    phx-change="rename_document"
                    class="relative inline-flex min-w-0 items-center h-8"
                    data-role="document-title-form"
                    phx-hook=".BlurTitleOnSubmit"
                  >
                    <% title_value =
                      document_header_title(@current_document, @projection, @studio_state) %>
                    <input
                      id="studio-document-title-input"
                      type="text"
                      name="title"
                      value={title_value}
                      size={title_input_size(title_value)}
                      aria-label={dgettext("studio", "문서 제목")}
                      placeholder={dgettext("studio", "새 계약서")}
                      autocomplete="off"
                      spellcheck="false"
                      phx-debounce="400"
                      class="relative z-10 h-7 w-[12rem] max-w-[34vw] leading-none cursor-text bg-transparent text-[13px] font-medium text-base-content px-1.5 py-0 border border-base-300 hover:z-20 hover:border-base-content/30 focus:z-20 focus:border-base-content/50 focus:bg-base-100 outline-none focus:outline-none focus:ring-0 focus:shadow-none transition-colors rounded-l-md rounded-r-none"
                    />
                  </form>
                  <script :type={Phoenix.LiveView.ColocatedHook} name=".BlurTitleOnSubmit">
                    export default {
                      mounted() {
                        this.titleInput = this.el.querySelector("input[name='title']")
                        this.onSubmit = () => {
                          setTimeout(() => this.titleInput?.blur(), 0)
                          setTimeout(() => this.titleInput?.blur(), 120)
                        }
                        this.onKeyDown = event => {
                          if (event.key === "Enter") this.onSubmit()
                        }
                        this.el.addEventListener("submit", this.onSubmit)
                        this.titleInput?.addEventListener("keydown", this.onKeyDown)
                      },
                      destroyed() {
                        this.el.removeEventListener("submit", this.onSubmit)
                        this.titleInput?.removeEventListener("keydown", this.onKeyDown)
                      }
                    }
                  </script>

                  <details
                    class="relative shrink-0"
                    data-role="document-picker"
                  >
                    <summary
                      class="relative z-0 list-none -ml-px inline-flex h-7 w-7 items-center justify-center rounded-r-md border border-base-300 bg-base-100 text-base-content/60 hover:z-30 hover:text-base-content hover:bg-base-200 cursor-pointer"
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
                      <.link
                        :if={@other_documents == []}
                        navigate={~p"/storage"}
                        role="menuitem"
                        class="block px-3 py-1.5 text-base-content/60 hover:bg-base-200"
                      >
                        {dgettext("studio", "보관함에서 문서 선택…")}
                      </.link>
                    </div>
                  </details>
                </div>

                <%= if projection_type_key(@projection) do %>
                  <span
                    id="document-type-badge"
                    data-role="document-type-badge"
                    class="inline-flex h-7 shrink-0 items-center gap-1.5 rounded-md border border-base-300 bg-base-100 px-2 text-[13px] font-medium text-base-content/70"
                    aria-label={dgettext("studio", "문서 타입")}
                    title={ContractTypes.display_name(projection_type_key(@projection))}
                  >
                    <.icon name="hero-document-text" class="size-3.5 text-base-content/45" />
                    <span data-role="document-type-summary">
                      {ContractTypes.display_name(projection_type_key(@projection))}
                    </span>
                  </span>
                <% else %>
                  <details
                    id="document-type-picker"
                    class="relative shrink-0"
                    data-role="document-type-picker"
                    phx-hook=".CloseOnOutside"
                    open={assigns[:contract_type_picker_open?] || false}
                  >
                    <summary
                      class="list-none inline-flex h-7 items-center gap-1 px-2 rounded-md text-[13px] font-medium border border-base-300 text-base-content/70 hover:bg-base-200 hover:text-base-content cursor-pointer"
                      aria-label={dgettext("studio", "문서 타입 선택")}
                      title={ContractTypes.display_name(projection_type_key(@projection))}
                    >
                      <span data-role="document-type-summary">
                        {ContractTypes.display_name(projection_type_key(@projection))}
                      </span>
                      <.icon name="hero-chevron-down" class="size-3" />
                    </summary>
                    <div
                      class="absolute left-0 top-full mt-1 z-30 w-72 max-h-80 overflow-y-auto rounded-md border border-base-300 bg-base-100 shadow-lg py-1 text-sm"
                      role="menu"
                    >
                      <.form
                        for={%{"q" => assigns[:contract_type_query] || ""}}
                        as={:search}
                        phx-change="filter_contract_types"
                        class="px-2 py-1"
                      >
                        <input
                          type="search"
                          name="q"
                          value={assigns[:contract_type_query] || ""}
                          placeholder={dgettext("studio", "표준양식 검색")}
                          autocomplete="off"
                          class="input input-sm input-bordered w-full"
                        />
                      </.form>

                      <p class="px-3 pb-1 pt-2 text-xs font-semibold uppercase tracking-wide text-base-content/40">
                        {dgettext("studio", "표준양식")}
                      </p>
                      <button
                        :for={spec <- contract_type_options(assigns[:contract_type_query] || "")}
                        type="button"
                        role="menuitem"
                        phx-click="set_contract_type"
                        phx-value-type_key={spec.key}
                        class={[
                          "flex w-full items-center justify-between gap-3 px-3 py-1.5 text-left hover:bg-base-200",
                          projection_type_key(@projection) == spec.key &&
                            "font-semibold text-base-content"
                        ]}
                      >
                        <span class="inline-flex items-center gap-2">
                          <.icon
                            name="hero-clipboard-document-list"
                            class="size-4 text-base-content/50"
                          />
                          <span>{ContractTypes.display_name(spec)}</span>
                        </span>
                        <.icon
                          :if={projection_type_key(@projection) == spec.key}
                          name="hero-check"
                          class="size-4"
                        />
                      </button>

                      <p
                        :if={contract_type_options(assigns[:contract_type_query] || "") == []}
                        class="px-3 py-2 text-sm text-base-content/50"
                      >
                        {dgettext("studio", "검색 결과가 없습니다.")}
                      </p>
                    </div>
                  </details>
                  <script :type={Phoenix.LiveView.ColocatedHook} name=".CloseOnOutside">
                    export default {
                      mounted() {
                        this.onPointerDown = event => {
                          if (!this.el.open || this.el.contains(event.target)) return
                          this.el.removeAttribute("open")
                          this.pushEvent("close_contract_type_picker", {})
                        }
                        this.onKeyDown = event => {
                          if (event.key !== "Escape" || !this.el.open) return
                          this.el.removeAttribute("open")
                          this.pushEvent("close_contract_type_picker", {})
                          this.el.querySelector("summary")?.focus()
                        }
                        document.addEventListener("pointerdown", this.onPointerDown, true)
                        document.addEventListener("keydown", this.onKeyDown, true)
                      },
                      destroyed() {
                        document.removeEventListener("pointerdown", this.onPointerDown, true)
                        document.removeEventListener("keydown", this.onKeyDown, true)
                      }
                    }
                  </script>
                <% end %>

                <div class="inline-flex items-center gap-1">
                  <div
                    class="inline-flex h-7 w-7 flex-col items-stretch overflow-hidden rounded-md border border-base-300 text-base-content/70 transition-colors"
                    role="group"
                    aria-label={dgettext("studio", "편집 항목 이동")}
                  >
                    <div
                      role="button"
                      tabindex="0"
                      data-role="rhwp-prev-edit-target"
                      aria-label={dgettext("studio", "이전 편집 항목")}
                      aria-keyshortcuts="Shift+Tab"
                      title={dgettext("studio", "이전 편집 항목 (Shift+Tab)")}
                      class="flex h-1/2 w-full items-center justify-center cursor-pointer transition-colors hover:bg-base-200 hover:text-base-content"
                    >
                      <svg
                        class="size-2.5 fill-none stroke-current"
                        viewBox="0 0 10 10"
                        aria-hidden="true"
                      >
                        <path
                          d="M2 6.5l3 -3 3 3"
                          stroke-width="1.4"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        />
                      </svg>
                    </div>
                    <div
                      role="button"
                      tabindex="0"
                      data-role="rhwp-next-edit-target"
                      aria-label={dgettext("studio", "다음 편집 항목")}
                      aria-keyshortcuts="Tab"
                      title={dgettext("studio", "다음 편집 항목 (Tab)")}
                      class="flex h-1/2 w-full items-center justify-center cursor-pointer transition-colors hover:bg-base-200 hover:text-base-content"
                    >
                      <svg
                        class="size-2.5 fill-none stroke-current"
                        viewBox="0 0 10 10"
                        aria-hidden="true"
                      >
                        <path
                          d="M2 3.5l3 3 3 -3"
                          stroke-width="1.4"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        />
                      </svg>
                    </div>
                  </div>
                  <kbd
                    aria-hidden="true"
                    class="hidden md:inline-flex items-center px-1 text-[10px] leading-none font-mono text-base-content/55 select-none"
                    title={dgettext("studio", "이전 = Shift+Tab, 다음 = Tab")}
                  >
                    Tab
                  </kbd>
                </div>
              </div>

              <div class="inline-flex items-center">
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
                    name={
                      if @chat_rail_hidden?,
                        do: "hero-arrows-pointing-in",
                        else: "hero-arrows-pointing-out"
                    }
                    class="size-4"
                  />
                </button>
              </div>
            </header>

            <article class="relative m-0 p-0 border-0 bg-transparent shadow-none text-base-content text-[15px] leading-[1.78] overflow-hidden min-h-0 flex-1 font-sans max-sm:mx-3 max-sm:py-7 max-sm:px-5">
              <div class="relative h-full min-h-0">
                <div
                  :if={is_nil(@studio_state.selected_document_id)}
                  id="canvas-empty-type-picker"
                  data-stub="canvas-empty"
                  data-role="canvas-empty-type-picker"
                  class="flex h-full min-h-0 items-center justify-center px-6 py-8"
                >
                  <div class="w-full max-w-2xl">
                    <div class="mb-3 flex items-center justify-between gap-3">
                      <h2 class="text-sm font-semibold text-base-content">
                        {dgettext("studio", "계약 유형 선택")}
                      </h2>
                      <span class="text-xs text-base-content/50">
                        {dgettext("studio", "새 문서")}
                      </span>
                    </div>
                    <div class="grid gap-2 sm:grid-cols-2">
                      <button
                        :for={spec <- contract_type_options("")}
                        type="button"
                        phx-click="set_contract_type"
                        phx-value-type_key={spec.key}
                        data-role="canvas-empty-type-option"
                        class="group flex min-h-11 items-center justify-between gap-3 rounded-md border border-base-300 bg-base-100 px-3 py-2 text-left text-sm text-base-content/80 transition-colors hover:border-base-content/30 hover:bg-base-200 hover:text-base-content"
                      >
                        <span class="min-w-0 truncate font-medium">
                          {ContractTypes.display_name(spec)}
                        </span>
                        <.icon
                          name="hero-arrow-right"
                          class="size-4 shrink-0 text-base-content/35 transition-colors group-hover:text-base-content/60"
                        />
                      </button>
                    </div>
                  </div>
                </div>
                <.live_component
                  :if={standard_template}
                  module={Components.Canvas.HwpTemplate}
                  id="standard-hwp-template-canvas"
                  spec={standard_template}
                  matching_book={@rhwp_matching_book || %{}}
                  field_values={@rhwp_field_values || %{}}
                  editable_spec_candidates={editable_spec_candidates()}
                  site_id={"user:#{@current_scope.user.id}"}
                  document_id={@studio_state.selected_document_id}
                  text_events={@rhwp_text_events}
                  snapshot={@rhwp_snapshot}
                  snapshot_candidates={@rhwp_snapshot_candidates || []}
                />
              </div>
            </article>
          </section>

          <aside
            :if={not @chat_rail_hidden?}
            id="studio-chat-rail"
            phx-hook=".RailResizer"
            class="fixed top-[60px] right-0 h-[calc(100vh-60px)] min-h-0 min-w-0 flex flex-col z-30 bg-base-100"
            style="width: var(--chat-rail-width, 380px);"
          >
            <div
              class={[
                "absolute top-0 -left-1 w-2 h-full cursor-col-resize z-40 select-none touch-none",
                "after:content-[''] after:absolute after:top-0 after:left-1/2 after:-translate-x-1/2",
                "after:w-px after:h-full after:bg-base-300 after:transition-[background,width] after:duration-150",
                "hover:after:w-0.5 hover:after:bg-base-content/30",
                "data-[dragging=true]:after:w-0.5 data-[dragging=true]:after:bg-base-content/30"
              ]}
              data-role="chat-rail-resizer"
              aria-hidden="true"
            >
            </div>
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
              agent_document_status={@agent_document_status}
              streams={%{chat_messages: @streams.chat_messages}}
              current_scope={@current_scope}
              chat_thread={@chat_thread}
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
       do: ""

  defp document_header_title(_document, _projection, _state),
    do: ""

  # ContractTypes.display_name/1 accepts a string key, a TypeSpec, or
  # nil; the projection may be the empty-projection map (type_key: nil)
  # or a struct/map decoded from the snapshot. Always normalize to
  # `string | nil` so the dropdown's "currently selected" rendering and
  # the equality check against `spec.key` stay correct after a JSON
  # roundtrip.
  defp projection_type_key(%{type_key: tk}) when is_binary(tk) and tk != "", do: tk
  defp projection_type_key(_), do: nil

  defp assign_projection(socket, projection) do
    rhwp_field_values = rhwp_field_values_for_projection(projection)

    socket
    |> assign(:projection, projection)
    |> assign(:rhwp_matching_book, rhwp_matching_book_for_projection(projection))
    |> assign(:rhwp_field_values, rhwp_field_values)
    |> assign(:rhwp_field_values_cache, rhwp_field_values)
  end

  defp rhwp_matching_book_for_projection(projection) do
    with type_key when is_binary(type_key) <- projection_type_key(projection),
         {:ok, matching_book} <- ContractTypes.get_matching_book(type_key) do
      matching_book
    else
      _ -> %{}
    end
  end

  defp persist_rhwp_field_value(socket, field_id, value) do
    field_id = String.trim(field_id)
    state = socket.assigns.studio_state
    document_id = state && state.selected_document_id

    cond do
      field_id == "" or not is_binary(document_id) ->
        socket

      true ->
        scope = socket.assigns.current_scope

        field_values =
          socket.assigns
          |> cached_rhwp_field_values(scope, document_id)
          |> Map.put(field_id, value)

        action = %Command{
          kind: :update_metadata,
          actor_type: :user,
          actor_id: scope && scope.user && scope.user.id,
          document_id: document_id,
          base_revision: nil,
          idempotency_key: generate_idempotency_key(),
          payload: %{"metadata" => %{"rhwp_field_values" => field_values}}
        }

        case Contract.Runtime.apply(scope, action) do
          {:ok, %Contract.Change{}} ->
            assign(socket, :rhwp_field_values_cache, field_values)

          {:error, _reason} ->
            socket
        end
    end
  end

  defp cached_rhwp_field_values(assigns, scope, document_id) do
    case Map.get(assigns, :rhwp_field_values_cache) do
      values when is_map(values) -> normalize_rhwp_field_values(values)
      _ -> current_rhwp_field_values(scope, document_id, Map.get(assigns, :projection))
    end
  end

  defp current_rhwp_field_values(scope, document_id, fallback_projection) do
    case Contract.Runtime.load(scope, document_id) do
      {:ok, %Contract.Runtime.State{projection: projection}} ->
        rhwp_field_values_for_projection(projection)

      _ ->
        rhwp_field_values_for_projection(fallback_projection)
    end
  end

  defp rhwp_field_values_for_projection(%{metadata: metadata}) when is_map(metadata),
    do: rhwp_field_values_from_metadata(metadata)

  defp rhwp_field_values_for_projection(%{"metadata" => metadata}) when is_map(metadata),
    do: rhwp_field_values_from_metadata(metadata)

  defp rhwp_field_values_for_projection(_projection), do: %{}

  defp rhwp_field_values_from_metadata(metadata) when is_map(metadata) do
    metadata
    |> metadata_value(:rhwp_field_values)
    |> normalize_rhwp_field_values()
  end

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp normalize_rhwp_field_values(values) when is_map(values) do
    values
    |> Enum.reduce(%{}, fn
      {field_id, value}, acc when is_binary(field_id) and not is_nil(value) ->
        Map.put(acc, field_id, stringify_rhwp_field_value(value))

      {field_id, value}, acc when is_atom(field_id) and not is_nil(value) ->
        Map.put(acc, Atom.to_string(field_id), stringify_rhwp_field_value(value))

      _, acc ->
        acc
    end)
  end

  defp normalize_rhwp_field_values(_values), do: %{}

  defp stringify_rhwp_field_value(value) when is_binary(value), do: value
  defp stringify_rhwp_field_value(nil), do: ""
  defp stringify_rhwp_field_value(value), do: to_string(value)

  defp standard_template_spec(projection) do
    with type_key when is_binary(type_key) <- projection_type_key(projection),
         {:ok, spec} <- ContractTypes.get(type_key),
         path when is_binary(path) and path != "" <- template_path(spec) do
      spec
    else
      _ -> nil
    end
  end

  defp template_path(%{template_hwp_path: path}) when is_binary(path) and path != "", do: path
  defp template_path(%{template_hwpx_path: path}) when is_binary(path) and path != "", do: path
  defp template_path(_spec), do: nil

  defp editable_spec_candidates do
    case ContractTypes.list() do
      {:ok, specs} ->
        specs
        |> Enum.map(&editable_spec_candidate/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp editable_spec_candidate(spec) do
    with template_path when is_binary(template_path) <- template_path(spec),
         spec_path when is_binary(spec_path) <- editable_spec_path(template_path),
         true <- editable_spec_file_exists?(spec_path) do
      %{
        contractTypeKey: spec.key,
        documentPath: template_path,
        specPath: spec_path
      }
    else
      _ -> nil
    end
  end

  defp editable_spec_path(template_path) when is_binary(template_path) do
    Regex.replace(~r/\.(hwp|hwpx)$/i, template_path, ".editables.json")
  end

  defp editable_spec_file_exists?("/" <> path) do
    :contract
    |> :code.priv_dir()
    |> Path.join("static/#{path}")
    |> File.exists?()
  end

  defp editable_spec_file_exists?(_path), do: false

  defp rhwp_snapshot_format(projection) do
    projection
    |> standard_template_spec()
    |> template_format()
  end

  defp template_format(%{template_hwp_path: path}) when is_binary(path) and path != "", do: "hwp"

  defp template_format(%{template_hwpx_path: path}) when is_binary(path) and path != "",
    do: "hwpx"

  defp template_format(_spec), do: nil

  @rhwp_text_command_kinds ~w(edit_text doc_write)

  # rhwp canvas replay events: changes 테이블의 text-op command payload 추출 →
  # [%{kind, sec, para, off, ...}] 리스트. 클라이언트 hook 이 mount 시 WASM
  # 에 순차 적용하여 baseline template 위에 mutation 누적 결과를 복원한다.
  defp load_rhwp_text_events(nil, _base_revision), do: []

  defp load_rhwp_text_events(document_id, base_revision) do
    case Contract.Store.changes_since(document_id, base_revision) do
      {:ok, changes} ->
        changes
        |> Enum.filter(&(&1.command_kind in @rhwp_text_command_kinds))
        |> Enum.flat_map(fn %Contract.Change{payload: payload, result_revision: revision} ->
          payload
          |> List.wrap()
          |> Enum.flat_map(&change_payload_op_to_event(&1, revision))
        end)

      _ ->
        []
    end
  end

  # Newest committed rhwp native snapshots. The first row is the preferred
  # source, while later rows let the client recover if the latest native blob
  # is no longer renderable.
  defp load_rhwp_snapshot_candidates(nil, _format), do: []

  defp load_rhwp_snapshot_candidates(document_id, format) do
    document_id
    |> Contract.RhwpSnapshot.candidates_for_document(format, limit: 5)
    |> Enum.map(&snapshot_candidate(document_id, &1))
  end

  defp snapshot_candidate(document_id, %Contract.RhwpSnapshot.Record{
         revision: rev,
         format: format,
         projection: projection
       }) do
    %{
      url: "/documents/#{document_id}/rhwp-snapshots/#{rev}.#{format}",
      revision: rev,
      lamport: snapshot_lamport(projection),
      contractTypeKey: snapshot_contract_type_key(projection),
      templatePath: snapshot_template_path(projection)
    }
  end

  defp assign_rhwp_snapshot_state(socket, document_id, format) do
    snapshot_candidates = load_rhwp_snapshot_candidates(document_id, format)
    snapshot = List.first(snapshot_candidates)
    text_base_revision = if snapshot, do: snapshot.revision, else: 0

    socket
    |> assign(:rhwp_snapshot, snapshot)
    |> assign(:rhwp_snapshot_candidates, snapshot_candidates)
    |> assign(:rhwp_text_events, load_rhwp_text_events(document_id, text_base_revision))
  end

  defp snapshot_lamport(projection) when is_map(projection) do
    projection
    |> metadata_value(:lamport_max)
    |> normalize_snapshot_lamport()
  end

  defp snapshot_lamport(_projection), do: nil

  defp normalize_snapshot_lamport(value) when is_integer(value) and value > 0, do: value

  defp normalize_snapshot_lamport(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp normalize_snapshot_lamport(_value), do: nil

  defp snapshot_contract_type_key(projection) when is_map(projection) do
    projection
    |> metadata_value(:contract_type)
    |> normalize_snapshot_string()
  end

  defp snapshot_contract_type_key(_projection), do: nil

  defp snapshot_template_path(projection) when is_map(projection) do
    projection
    |> metadata_value(:template_path)
    |> normalize_snapshot_string()
  end

  defp snapshot_template_path(_projection), do: nil

  defp normalize_snapshot_string(value) when is_binary(value) and value != "", do: value
  defp normalize_snapshot_string(_value), do: nil

  defp verify_rhwp_snapshot_document_id(_document_id, nil), do: :ok
  defp verify_rhwp_snapshot_document_id(document_id, document_id), do: :ok

  defp verify_rhwp_snapshot_document_id(_document_id, _requested_document_id),
    do: {:error, :document_mismatch}

  defp ack_rhwp_snapshot_committed(request_id, document_id, snapshot) do
    ack_rhwp_materializer(request_id, %{
      status: :committed,
      request_id: request_id,
      document_id: document_id,
      revision: snapshot.revision,
      snapshot: %{
        key: snapshot.r2_key,
        ir_key: snapshot.ir_r2_key,
        format: snapshot.format,
        content_type: snapshot.content_type
      }
    })
  end

  defp ack_rhwp_snapshot_failed(request_id, document_id, reason) do
    ack_rhwp_materializer(request_id, %{
      status: :failed,
      request_id: request_id,
      document_id: document_id,
      error: inspect(reason)
    })
  end

  defp rhwp_request_value(request, keys) when is_map(request) do
    Enum.find_value(keys, &Map.get(request, &1))
  end

  defp rhwp_request_value(_request, _keys), do: nil

  defp normalize_rhwp_min_revision(value) when is_integer(value), do: value

  defp normalize_rhwp_min_revision(value) when is_binary(value) do
    case Integer.parse(value) do
      {revision, ""} -> revision
      _ -> nil
    end
  end

  defp normalize_rhwp_min_revision(_value), do: nil

  defp verify_rhwp_min_revision(_revision, nil), do: :ok

  defp verify_rhwp_min_revision(revision, min_revision)
       when is_integer(revision) and is_integer(min_revision) and revision >= min_revision,
       do: :ok

  defp verify_rhwp_min_revision(_revision, min_revision),
    do: {:error, {:stale_revision, min_revision}}

  defp register_rhwp_materializer_editor(document_id) when is_binary(document_id) do
    call_rhwp_materializer(:register_editor, [document_id])
  end

  defp register_rhwp_materializer_editor(_document_id), do: :ok

  defp unregister_rhwp_materializer_editor(%Contract.Studio.State{
         selected_document_id: document_id
       }) do
    unregister_rhwp_materializer_editor(document_id)
  end

  defp unregister_rhwp_materializer_editor(document_id) when is_binary(document_id) do
    call_rhwp_materializer(:unregister_editor, [document_id])
  end

  defp unregister_rhwp_materializer_editor(_document_id), do: :ok

  defp update_rhwp_materializer_editor(previous_document_id, next_document_id)
       when previous_document_id == next_document_id,
       do: :ok

  defp update_rhwp_materializer_editor(previous_document_id, next_document_id) do
    _ = unregister_rhwp_materializer_editor(previous_document_id)
    register_rhwp_materializer_editor(next_document_id)
  end

  defp ack_rhwp_materializer(request_id, result)
       when is_binary(request_id) and request_id != "" do
    call_rhwp_materializer(:ack, [request_id, result])
  end

  defp ack_rhwp_materializer(_request_id, _result), do: :ok

  defp call_rhwp_materializer(function, args) do
    module = Contract.RhwpSnapshot.Materializer

    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      :ok
    end
  end

  # Two shapes reach this converter:
  #   * Fresh in-memory Change from Store.append broadcast — atom keys, atom op
  #   * Reloaded Change from Postgres JSONB — string keys, string op
  # The client only sees the post-JSON shape, so we normalize args + kind to
  # strings here. Without the atom clause, the broadcast path's push_event
  # was silently skipped and remote edits never reached the canvas live.
  defp change_payload_op_to_event(change_payload, revision \\ nil)

  defp change_payload_op_to_event(%{op: op, args: args}, revision) when is_map(args) do
    [args |> stringify_keys() |> Map.put("kind", to_string(op)) |> put_event_revision(revision)]
  end

  defp change_payload_op_to_event(%{"op" => op, "args" => args}, revision) when is_map(args) do
    [args |> Map.put("kind", op) |> put_event_revision(revision)]
  end

  defp change_payload_op_to_event(_, _revision), do: []

  defp put_event_revision(event, revision) when is_integer(revision),
    do: Map.put(event, "revision", revision)

  defp put_event_revision(event, _revision), do: event

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # envelope body(camelCase) → op map(snake_case). nil 필드는 자동 drop.
  # siteId/eventId 는 actor_id / idempotency_key 로 row 에 이미 있으므로 args 미포함.
  @rhwp_arg_keys [
    {:sec, "sectionIndex"},
    {:para, "paragraphIndex"},
    {:off, "charOffset"},
    {:len, "len"},
    {:count, "count"},
    {:text, "text"},
    {:parent_para, "parentParaIndex"},
    {:cell_path, "cellPath"},
    {:prev_len, "prevLen"},
    {:at_row, "atRow"},
    {:at_col, "atCol"},
    {:control_index, "controlIndex"}
  ]

  defp rhwp_envelope_to_text_op(body, envelope) when is_map(body) do
    args =
      Enum.reduce(@rhwp_arg_keys, %{}, fn {atom_key, str_key}, acc ->
        case Map.fetch(body, str_key) do
          {:ok, v} -> Map.put(acc, atom_key, v)
          :error -> acc
        end
      end)

    args
    |> Map.put(:kind, rhwp_event_type_to_op_kind(body["type"]))
    |> Map.put(:lamport, envelope["lamport"])
  end

  defp rhwp_event_type_to_op_kind("TextInserted"), do: :insert_text
  defp rhwp_event_type_to_op_kind("TextDeleted"), do: :delete_text
  defp rhwp_event_type_to_op_kind("ParagraphSplit"), do: :insert_paragraph
  defp rhwp_event_type_to_op_kind("ParagraphMerged"), do: :merge_paragraph
  defp rhwp_event_type_to_op_kind("TableRowInserted"), do: :table_row_insert
  defp rhwp_event_type_to_op_kind("TableRowDeleted"), do: :table_row_delete
  defp rhwp_event_type_to_op_kind("TableColumnInserted"), do: :table_column_insert
  defp rhwp_event_type_to_op_kind("TableColumnDeleted"), do: :table_column_delete
  defp rhwp_event_type_to_op_kind("TableDeleted"), do: :table_delete

  # rhwp text ops broadcast: 다른 사용자/Agent 의 text-op change 가 도착하면
  # hook 에 push_event 로 op 리스트 + idempotency_key 전달. hook 은 자기가
  # publish 한 eventId 와 비교해서 echo 면 무시한다.
  defp push_rhwp_remote_text(socket, %Contract.Change{command_kind: kind} = change)
       when kind in @rhwp_text_command_kinds do
    case change.payload |> List.wrap() |> Enum.flat_map(&change_payload_op_to_event/1) do
      [] ->
        socket

      ops ->
        push_event(socket, "rhwp:remote_text_ops", %{ops: ops, event_id: change.idempotency_key})
    end
  end

  defp push_rhwp_remote_text(socket, _change), do: socket

  defp append_rhwp_text_events(
         socket,
         %Contract.Change{command_kind: kind, result_revision: revision} = change
       )
       when kind in @rhwp_text_command_kinds do
    events =
      change.payload
      |> List.wrap()
      |> Enum.flat_map(&change_payload_op_to_event(&1, revision))

    if events == [] do
      socket
    else
      update(socket, :rhwp_text_events, fn existing ->
        List.wrap(existing) ++ events
      end)
    end
  end

  defp append_rhwp_text_events(socket, _change), do: socket

  defp contract_type_options(query) when is_binary(query) do
    normalized_query = query |> String.trim() |> String.downcase()

    {:ok, specs} = ContractTypes.list()

    specs
    |> Enum.reject(&(&1.source == :custom))
    |> Enum.filter(&contract_type_matches?(&1, normalized_query))
  end

  defp contract_type_matches?(_spec, ""), do: true

  defp contract_type_matches?(spec, query) do
    spec.key
    |> Kernel.<>(" ")
    |> Kernel.<>(ContractTypes.display_name(spec))
    |> String.downcase()
    |> String.contains?(query)
  end

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

  defp update_modal(socket, "type_picker", value),
    do: put_state_flag(socket, :type_picker_open?, value)

  defp update_modal(socket, _other, _value), do: socket

  defp put_state_flag(socket, key, value) do
    update(socket, :studio_state, fn state -> Map.put(state, key, value) end)
  end

  # Stamp `:recently_authored_agent` for every node id touched by an
  # agent-authored Change. Reads the payload ops (the per-op `:target_id`
  # / `"target_id"` keys — payload comes back as string-keyed maps once
  # it round-trips through Ecto.Repo) and intersects with node-shaped
  # `target_type`s so we don't accidentally stamp document- or field-
  # scoped op targets.
  defp mark_agent_authored_nodes(state, %Contract.Change{
         actor_type: :agent,
         payload: payload
       })
       when is_list(payload) do
    node_ids =
      payload
      |> Enum.flat_map(&extract_node_target/1)
      |> Enum.uniq()

    if node_ids == [] do
      state
    else
      Contract.Studio.State.mark_recently_authored(
        state,
        node_ids,
        System.system_time(:millisecond)
      )
    end
  end

  defp mark_agent_authored_nodes(state, _change), do: state

  @agent_node_target_types ~w(node paragraph heading list_item)

  defp extract_node_target(%{target_type: type, target_id: id})
       when is_binary(id) and (is_atom(type) or is_binary(type)) do
    if to_string(type) in @agent_node_target_types, do: [id], else: []
  end

  defp extract_node_target(%{"target_type" => type, "target_id" => id})
       when is_binary(id) and is_binary(type) do
    if type in @agent_node_target_types, do: [id], else: []
  end

  defp extract_node_target(_), do: []

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

  defp maybe_insert_agent_loading_message(socket, agent_run_id) when is_binary(agent_run_id) do
    mark_text_bubble_created(agent_run_id)
    # The reasoning bubble is pre-inserted BEFORE any tool_call broadcasts
    # can arrive, so when reasoning summaries do stream they update the
    # bubble in place at its already-anchored position (above tool calls).
    # Without this, the bubble was inserted lazily on first reasoning
    # delta — which arrives AFTER tool_call_started — and ended up
    # ordered tool → reasoning → tool → agent in the rail.
    # stream_insert preserves position on update so subsequent
    # `:agent_reasoning_done` keeps the row above tool calls.
    socket
    |> stream_insert(:chat_messages, reasoning_bubble(agent_run_id, "", transient?: true))
    |> stream_insert(:chat_messages, agent_loading_message(agent_run_id))
  end

  defp maybe_insert_agent_loading_message(socket, _agent_run_id), do: socket

  defp maybe_move_waiting_agent_loading_message(socket, agent_run_id)
       when is_binary(agent_run_id) do
    if waiting_for_agent_text?(agent_run_id) do
      bubble = agent_loading_message(agent_run_id)

      socket
      |> stream_delete(:chat_messages, bubble)
      |> stream_insert(:chat_messages, bubble)
    else
      socket
    end
  end

  defp maybe_move_waiting_agent_loading_message(socket, _agent_run_id), do: socket

  defp agent_loading_message(agent_run_id) do
    %{
      id: "agent-#{agent_run_id}-streaming",
      agent_run_id: agent_run_id,
      role: :agent,
      body: "",
      timestamp: nil,
      transient?: true
    }
  end

  # Reasoning bubbles use the same `operation` shape as tool_calls so the
  # chat-rail renders them through `operation_block`, and rehydration from
  # `ChatThreads.list_visible_messages` (after a stream(... reset: true))
  # flows through the same code path. The `data-role="agent-reasoning-*"`
  # markers inside operation_block let the streaming JS hook
  # (`phx:agent_reasoning_append`) keep appending TextNodes without going
  # through LV diffs.
  defp reasoning_bubble(agent_run_id, body, opts) do
    transient? = Keyword.get(opts, :transient?, false)

    %{
      id: "reasoning-#{agent_run_id}",
      agent_run_id: agent_run_id,
      role: :agent,
      operation: %{
        "id" => "reasoning-#{agent_run_id}",
        "type" => "reasoning",
        "title" => "Thinking",
        "status" => if(transient?, do: "running", else: "completed"),
        "summary" => reasoning_summary_line(body),
        "details" => %{"text" => body}
      },
      transient?: transient?
    }
  end

  defp reasoning_summary_line(body) when is_binary(body) do
    body
    |> String.split(~r/\r?\n/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp reasoning_summary_line(_), do: ""

  defp current_chat_thread_id(socket) do
    case socket.assigns[:chat_thread] do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp text_bubble_created?(agent_run_id),
    do: Process.get(text_bubble_created_key(agent_run_id)) == true

  defp waiting_for_agent_text?(agent_run_id),
    do:
      text_bubble_created?(agent_run_id) and
        Process.get(text_stream_started_key(agent_run_id)) != true

  defp mark_text_bubble_created(agent_run_id),
    do: Process.put(text_bubble_created_key(agent_run_id), true)

  defp mark_text_stream_started(agent_run_id),
    do: Process.put(text_stream_started_key(agent_run_id), true)

  defp clear_agent_loading_state(socket, agent_run_id) do
    _ = Process.delete(text_bubble_created_key(agent_run_id))
    _ = Process.delete(text_stream_started_key(agent_run_id))
    socket
  end

  defp maybe_remove_unfinished_reasoning(socket, agent_run_id) when is_binary(agent_run_id) do
    if reasoning_stream_completed?(agent_run_id) do
      _ = Process.delete(reasoning_stream_completed_key(agent_run_id))
      socket
    else
      stream_delete_by_dom_id(socket, :chat_messages, "chat-msg-reasoning-#{agent_run_id}")
    end
  end

  defp maybe_remove_unfinished_reasoning(socket, _agent_run_id), do: socket

  defp remove_agent_transient_rows(socket, agent_run_id) when is_binary(agent_run_id) do
    _ = Process.delete(reasoning_stream_completed_key(agent_run_id))

    socket
    |> clear_agent_loading_state(agent_run_id)
    |> stream_delete_by_dom_id(:chat_messages, "chat-msg-agent-#{agent_run_id}-streaming")
    |> stream_delete_by_dom_id(:chat_messages, "chat-msg-reasoning-#{agent_run_id}")
  end

  defp remove_agent_transient_rows(socket, _agent_run_id), do: socket

  defp text_bubble_created_key(agent_run_id), do: {:text_bubble_created, agent_run_id}
  defp text_stream_started_key(agent_run_id), do: {:text_stream_started, agent_run_id}

  defp reasoning_stream_completed_key(agent_run_id),
    do: {:reasoning_stream_completed, agent_run_id}

  defp reasoning_stream_completed?(agent_run_id),
    do: Process.get(reasoning_stream_completed_key(agent_run_id)) == true

  defp mark_reasoning_stream_completed(agent_run_id),
    do: Process.put(reasoning_stream_completed_key(agent_run_id), true)

  defp insert_operation_chat(socket, id, operation, opts) do
    socket
    |> stream_insert(:chat_messages, %{
      id: to_string(id),
      role: :agent,
      operation: stringify_operation(operation),
      transient?: Keyword.get(opts, :transient?, false),
      timestamp: DateTime.utc_now()
    })
    |> maybe_move_waiting_agent_loading_message(Keyword.get(opts, :agent_run_id))
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

  defp protocol_summary(%{summary: summary}) when is_binary(summary), do: summary
  defp protocol_summary(%{"summary" => summary}) when is_binary(summary), do: summary
  defp protocol_summary(%{body: body}) when is_binary(body), do: body
  defp protocol_summary(%{"body" => body}) when is_binary(body), do: body
  defp protocol_summary(%{error: error}), do: protocol_error_summary(error)
  defp protocol_summary(%{"error" => error}), do: protocol_error_summary(error)
  defp protocol_summary(value) when is_binary(value), do: value
  defp protocol_summary(value) when is_atom(value), do: Atom.to_string(value)
  defp protocol_summary(value), do: inspect(value)

  defp protocol_error_summary(error) when is_binary(error), do: error
  defp protocol_error_summary(error), do: inspect(error)

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

  defp build_toast(level, title, body) do
    %{
      id: "toast-" <> (Ecto.UUID.generate() |> String.replace("-", "")),
      level: level,
      title: title,
      body: body,
      inserted_at: DateTime.utc_now()
    }
  end

  defp import_summary(%{title: title}) when is_binary(title), do: title
  defp import_summary(%{id: id}) when is_binary(id), do: "Document " <> short_id(id)
  defp import_summary(_), do: "Document imported."

  defp short_id(nil), do: "?"

  defp short_id(id) when is_binary(id) do
    case String.split(id, "-", parts: 2) do
      [head | _] -> head
      _ -> String.slice(id, 0, 8)
    end
  end

  defp short_id(other), do: inspect(other)

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
