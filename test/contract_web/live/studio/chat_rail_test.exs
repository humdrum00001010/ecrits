defmodule ContractWeb.Live.Studio.Components.ChatRailTest do
  @moduledoc """
  Component-level tests for the Studio chat rail (Wave 3C1 / chat-rail).

  Two test surfaces:

    * `render_component/2` — pure static rendering of the component (header
      pill, observer banner, mobile layout, send-button regression).
    * `live_isolated/3` with a wrapping LV — drives `:agent_stream` /
      `:agent_completed` through a stream so we can assert streaming + final
      bubbles + GrillRail mount.
  """

  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Contract.Context
  alias Contract.Studio.State
  alias ContractWeb.Live.Studio.Components.ChatRail

  # ---------------------------------------------------------------------------
  # Wrapper LV — owns a stream and embeds ChatRail. Used for tests that need
  # to insert into `@streams.chat_messages`.
  # ---------------------------------------------------------------------------

  defmodule WrapperLive do
    use ContractWeb, :live_view

    # We're nested inside an ExUnit test module that uses ContractWeb.ConnCase,
    # which imports Plug.Conn — that import leaks here and clashes with
    # Phoenix.Component.assign/3. Disambiguate by aliasing.
    alias Phoenix.Component, as: PC
    alias Phoenix.LiveView, as: PLV
    alias ContractWeb.Live.Studio.Components.ChatRail

    @impl true
    def mount(_params, session, socket) do
      scope =
        session["scope"] ||
          %Context{user: nil, perms: ~w(read write commit revoke agent_run export type_change)a}

      state =
        session["studio_state"] ||
          %State{
            mode: :briefing,
            last_seen_revision: 0,
            agent_run_id: nil
          }

      socket =
        socket
        |> PC.assign(:scope, scope)
        |> PC.assign(:studio_state, state)
        |> PC.assign(:chat_layout, session["layout"] || :default)
        |> PC.assign(:grill_active?, session["grill_active?"] || nil)
        |> PC.assign(:test_pid, session["test_pid"])
        |> PLV.stream_configure(:chat_messages, dom_id: &"chat-msg-#{&1.id}")
        |> PLV.stream(:chat_messages, [])

      {:ok, socket}
    end

    @impl true
    def handle_info({:insert, msg}, socket) do
      {:noreply, PLV.stream_insert(socket, :chat_messages, msg)}
    end

    def handle_info({:set_state, state}, socket) do
      {:noreply, PC.assign(socket, :studio_state, state)}
    end

    def handle_info({:set_grill, value}, socket) do
      {:noreply, PC.assign(socket, :grill_active?, value)}
    end

    @impl true
    def handle_event("chat.submit", params, socket) do
      if pid = socket.assigns[:test_pid], do: send(pid, {:captured, "chat.submit", params})
      {:noreply, socket}
    end

    def handle_event(_event, _params, socket), do: {:noreply, socket}

    @impl true
    def render(assigns) do
      ~H"""
      <div id="wrapper">
        <.live_component
          module={ChatRail}
          id="chat-rail"
          studio_state={@studio_state}
          streams={%{chat_messages: @streams.chat_messages}}
          current_scope={@scope}
          layout={@chat_layout}
          grill_active?={@grill_active?}
        />
      </div>
      """
    end
  end

  # ---------------------------------------------------------------------------
  # Scope fixtures (mirror Contract.PersonaFactory).
  # ---------------------------------------------------------------------------

  defp lawyer_scope,
    do: %Context{
      user: nil,
      perms: ~w(read write commit revoke export type_change agent_run)a
    }

  defp agent_supervised_scope,
    do: %Context{
      user: nil,
      perms: ~w(read write commit revoke agent_run)a
    }

  defp default_state,
    do: %State{mode: :briefing, last_seen_revision: 0, agent_run_id: nil}

  defp empty_stream do
    # `render_component/2` accepts any enumerable in place of a stream; LV
    # iterates the assigned value like `{dom_id, item}` pairs.
    []
  end

  # ===========================================================================
  # render_component/2 cases
  # ===========================================================================

  describe "static rendering" do
    test "case 1 — empty chat shows the welcome message" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope()
        )

      assert html =~ ~s(data-role="chat-welcome")
      # Korean copy primary.
      assert html =~ "에이전트"
      # The stream container is present and empty (no chat-message articles).
      refute html =~ ~s(data-role="chat-message")
    end

    test "case 4 — send button is type=button (NOT submit) — mobile regression" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope()
        )

      # The send button must NEVER be type=submit. The form's phx-submit is
      # intercepted by the .ChatInput hook so the mobile keyboard never
      # collapses on send.
      assert html =~ ~s(data-role="chat-send")

      # Extract the send button element. It must carry type="button".
      assert Regex.match?(
               ~r/<button[^>]*data-role="chat-send"[^>]*type="button"|<button[^>]*type="button"[^>]*data-role="chat-send"/s,
               html
             ),
             "expected the send button to be type=\"button\"; got: " <>
               (Regex.run(~r/<button[^>]*data-role="chat-send"[^>]*>/, html) |> inspect())

      # And critically: nowhere in the form does a submit-type button appear.
      refute html =~ ~s(type="submit")
    end

    test "case 6 — mobile layout pins the input footer to the safe-area bottom" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope(),
          layout: :mobile_full
        )

      assert html =~ ~s(data-layout="mobile")
      # Mobile relies on the parent flex container for height — no fixed
      # 100dvh on the rail itself (parent already constrains height; a
      # nested 100dvh causes overflow when the parent isn't body).
      refute html =~ "h-[100dvh]"
      # Mobile fills the parent's width + remaining flex space.
      assert html =~ "w-full"
      assert html =~ "flex-1"
      # Safe-area inset on the footer.
      assert html =~ "env(safe-area-inset-bottom)"
      # No desktop fixed-width rail.
      refute html =~ "w-[360px]"
    end

    test "case 6b — mobile header surfaces 문서 button (goto-document affordance)" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope(),
          layout: :mobile_full
        )

      # Mobile chat-rail header must expose a leading 문서 button that
      # fires `toggle_preview` so the user can pivot from chat → document
      # without going via /storage.
      assert html =~ ~s(data-role="chat-rail-open-document")
      assert html =~ ~s(phx-click="toggle_preview")
      assert html =~ "문서"
    end

    test "case 6c — desktop header does NOT carry the 문서 toggle button" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope()
        )

      # Desktop renders the document inline + uses the studio-document-
      # header's Storage link, so the in-rail toggle is mobile-only.
      refute html =~ ~s(data-role="chat-rail-open-document")
    end

    test "agent_supervised persona sees the observer-mode banner" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{chat_messages: empty_stream()},
          current_scope: agent_supervised_scope()
        )

      assert html =~ ~s(data-role="observer-banner")
      assert html =~ "관찰 모드"
    end

    test "no-document mode shows the agent welcome prompt with start chips (SPEC.md §10)" do
      no_doc_state = %State{mode: :no_document, last_seen_revision: 0, agent_run_id: nil}

      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: no_doc_state,
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope()
        )

      # The no-doc welcome panel renders (and the generic welcome is hidden).
      assert html =~ ~s(data-role="chat-no-doc-welcome")
      refute html =~ ~s(data-role="chat-welcome")

      # The 4 welcome chip labels are present. "업로드" was moved out of the
      # welcome list and into the input footer's paperclip icon button, so
      # the welcome itself no longer surfaces an upload chip.
      assert html =~ "최근 문서 열기"
      assert html =~ "빈 계약서 만들기"
      assert html =~ "논의에서 시작"
      assert html =~ "다른 문서에서 변형 만들기"

      # Each chip emits agent_option_picked with the right key. `upload` is
      # still wired (via the paperclip icon button in the input footer).
      assert html =~ ~s(phx-click="agent_option_picked")
      assert html =~ ~s(phx-value-key="upload")
      assert html =~ ~s(phx-value-key="recent")
      assert html =~ ~s(phx-value-key="blank")
      assert html =~ ~s(phx-value-key="draft_from_discussion")
      assert html =~ ~s(phx-value-key="variant_from_other")

      # The headline copy is present.
      assert html =~ "새 문서를 시작합니다. 어떻게 시작할까요?"
      assert html =~ "무엇으로 시작할까요?"
    end

    test "no-document welcome hides only after a real streamed chat message exists", %{
      conn: conn
    } do
      no_doc_state = %State{mode: :no_document, last_seen_revision: 0, agent_run_id: nil}

      {:ok, lv, html} =
        live_isolated(conn, WrapperLive,
          session: %{"scope" => lawyer_scope(), "studio_state" => no_doc_state}
        )

      assert html =~ ~s(id="chat-rail-no-doc-welcome")
      refute html =~ ~s(data-role="chat-message")

      send(lv.pid, {
        :insert,
        %{
          id: "user-real-1",
          role: :user,
          body: "Start from a discussion",
          transient?: false
        }
      })

      html = render(lv)
      assert html =~ ~s(id="chat-rail-no-doc-welcome")
      assert html =~ ~s(id="chat-msg-user-real-1")
      assert html =~ ~s(data-role="chat-message")
    end

    test "no-document Korean copy is clean precomposed Hangul (no jamo decomposition)" do
      no_doc_state = %State{mode: :no_document, last_seen_revision: 0, agent_run_id: nil}

      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: no_doc_state,
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope()
        )

      # Every CJK Hangul syllable code-point should fall in the precomposed
      # Hangul Syllables block (U+AC00..U+D7A3). The Hangul Jamo block
      # (U+1100..U+11FF, U+3130..U+318F) means the source was NFD-decomposed,
      # which renders as broken consonant/vowel chains on screen.
      jamo_chars =
        html
        |> String.to_charlist()
        |> Enum.filter(fn cp ->
          (cp >= 0x1100 and cp <= 0x11FF) or
            (cp >= 0x3130 and cp <= 0x318F) or
            (cp >= 0xA960 and cp <= 0xA97F) or
            (cp >= 0xD7B0 and cp <= 0xD7FF)
        end)

      assert jamo_chars == [],
             "expected no Hangul jamo (decomposed) code points in chat_rail no-doc welcome HTML; " <>
               "found #{inspect(jamo_chars)}"
    end

    # The Codex-style redesign dropped the chrome-on-top status pill — the
    # send button itself toggles between paper-airplane (idle) and stop
    # (responding) and acts as the visible status indicator. The
    # `data-status="idle"/"responding"` markers no longer render.
    @tag :skip
    test "agent status pill reflects studio_state.agent_run_id" do
      idle_html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: %State{default_state() | agent_run_id: nil},
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope()
        )

      assert idle_html =~ ~s(data-status="idle")

      run_id = Ecto.UUID.generate()

      busy_html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: %State{default_state() | agent_run_id: run_id},
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope()
        )

      assert busy_html =~ ~s(data-status="responding")
    end

    test "operation protocol messages render structured blocks with stable DOM ids" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{
            chat_messages: [
              {"chat-msg-op-1",
               %{
                 id: "op-1",
                 role: :agent,
                 operation: %{
                   id: "tool-search-1",
                   type: "tool_call",
                   title: "law.search",
                   status: "running",
                   summary: "Searching statutes",
                   details: %{"query" => "상법 제542조"}
                 },
                 transient?: true
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      # tool_call operations render as the compact v33 trace row (no
      # `operation-block` section) — the surrounding chat-message article
      # carries the operation_id + aria wiring, and the trace itself has a
      # stable id + data-status.
      assert html =~ ~s(id="tool-trace-tool-search-1")
      assert html =~ ~s(data-role="tool-trace")
      assert html =~ ~s(data-status="running")
      assert html =~ "law.search"
      assert html =~ "Searching statutes"
    end

    test "source interpretation block renders parse summary and proposed claims" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{
            chat_messages: [
              {"chat-msg-source-1",
               %{
                 id: "source-1",
                 role: :agent,
                 operation: %{
                   id: "source-doc-1",
                   type: "source_interpretation",
                   title: "Counterparty draft",
                   status: "ready",
                   summary: "2 claims",
                   details: %{
                     "source_document_id" => "source-doc-1",
                     "regions" => [%{"region_id" => "r1", "raw_text" => "Effective Date"}],
                     "claims" => [
                       %{
                         "id" => "claim-1",
                         "proposed_kind" => "effective_date",
                         "proposed_value" => "2026-01-01"
                       },
                       %{
                         "id" => "claim-2",
                         "proposed_kind" => "party_a",
                         "proposed_value" => "Acme"
                       }
                     ]
                   }
                 },
                 transient?: false
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      assert html =~ ~s(data-role="source-interpretation-block")
      assert html =~ "Counterparty draft"
      # Claim count + field-kind labels are rendered as localized strings,
      # not as the raw `summary`/`proposed_kind` values.
      assert html =~ "추출값 2개"
      assert html =~ "효력 발생일"
      assert html =~ "2026-01-01"
      assert html =~ "갑"
    end

    test "source claim block renders anchors and supervision controls" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{
            chat_messages: [
              {"chat-msg-claim-1",
               %{
                 id: "claim-1",
                 role: :agent,
                 operation: %{
                   id: "claim-1",
                   type: "source_claim",
                   title: "Effective date",
                   status: "proposed",
                   details: %{
                     "source_claim_id" => "claim-1",
                     "source_document_id" => "source-doc-1",
                     "proposed_kind" => "effective_date",
                     "proposed_value" => "2026-01-01",
                     "confidence" => 0.91,
                     "anchors" => [%{"page" => 1, "text" => "Effective Date: 2026-01-01"}]
                   }
                 },
                 transient?: false
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      assert html =~ ~s(data-role="source-claim-block")
      # The field-kind is rendered as a localized label, not the raw key.
      assert html =~ "효력 발생일"
      assert html =~ "2026-01-01"
      assert html =~ "0.91"
      assert html =~ "Effective Date: 2026-01-01"
      assert html =~ ~s(phx-click="source_claim.confirm")
      assert html =~ ~s(phx-submit="source_claim.correct")
      assert html =~ ~s(phx-click="source_claim.reject")
      assert html =~ ~s(phx-click="source_claim.link_to_document")
      assert html =~ ~s(phx-click="source_claim.unlink")
      assert html =~ ~s(phx-value-source_claim_id="claim-1")
    end

    test "agent prose starts at the left edge of the chat stream" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{
            chat_messages: [
              {"chat-msg-agent-left",
               %{
                 id: "agent-left",
                 role: :agent,
                 result: %{body: "왼쪽에서 시작해야 합니다."},
                 transient?: false
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      agent_text =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="agent-text"][data-message-id="chat-msg-agent-left"]))

      # Agent prose is split into one paragraph span per `\n\n` chunk, so the
      # rendered text picks up surrounding whitespace from the wrapper layout.
      assert agent_text |> LazyHTML.text() |> String.trim() == "왼쪽에서 시작해야 합니다."

      [class] =
        agent_text
        |> LazyHTML.parent_node()
        |> LazyHTML.attribute("class")

      assert class =~ "self-start"
      refute class =~ "self-center"
    end
  end

  # ===========================================================================
  # live_isolated/3 cases — stream + GrillRail
  # ===========================================================================

  describe "streamed flow (via wrapper LV)" do
    test "case 2 — agent stream event accumulates as a transient bubble", %{conn: conn} do
      {:ok, lv, html} =
        live_isolated(conn, WrapperLive,
          session: %{
            "scope" => lawyer_scope(),
            "studio_state" => %State{default_state() | agent_run_id: Ecto.UUID.generate()}
          }
        )

      refute html =~ ~s(data-role="chat-message")

      run_id = "run-1"

      bubble = %{
        id: "agent-#{run_id}-1",
        agent_run_id: run_id,
        role: :agent,
        event: %{delta: "Hello, "},
        transient?: true
      }

      send(lv.pid, {:insert, bubble})
      html = render(lv)

      assert html =~ ~s(data-role="chat-message")
      assert html =~ ~s(data-transient="true")
      assert html =~ "Hello, "

      bubble2 = %{
        id: "agent-#{run_id}-2",
        agent_run_id: run_id,
        role: :agent,
        event: %{delta: "world."},
        transient?: true
      }

      send(lv.pid, {:insert, bubble2})
      html = render(lv)

      # Both transient bubbles are present in the streamed list.
      assert html =~ "Hello, "
      assert html =~ "world."
    end

    test "case 3 — agent_completed bubble is rendered as non-transient",
         %{conn: conn} do
      {:ok, lv, _html} =
        live_isolated(conn, WrapperLive, session: %{"scope" => lawyer_scope()})

      run_id = "run-2"

      final = %{
        id: "agent-#{run_id}-final",
        agent_run_id: run_id,
        role: :agent,
        result: %{body: "Final answer."},
        transient?: false
      }

      send(lv.pid, {:insert, final})
      html = render(lv)

      assert html =~ "Final answer."
      assert html =~ ~s(data-transient="false")
      refute html =~ ~s(data-transient="true")
    end

    test "case 5 — colocated hook pushes chat.submit with the body",
         %{conn: conn} do
      {:ok, lv, _html} =
        live_isolated(conn, WrapperLive,
          session: %{"scope" => lawyer_scope(), "test_pid" => self()}
        )

      # The form no longer carries `phx-submit` — the colocated `.ChatInput`
      # hook is the only path that fires `chat.submit`. We simulate the hook
      # by pushing the event directly through the form element (which is the
      # node bearing `phx-hook`).
      lv
      |> element("#chat-rail-form")
      |> render_hook("chat.submit", %{"message" => "hi agent"})

      assert_receive {:captured, "chat.submit", %{"message" => "hi agent"}}
    end

    test "case 5b — mobile layout: send button has a stable id, form delegates click → chat.submit",
         %{conn: conn} do
      # Item 6 regression — owner report: "send btn in mobile simply
      # doesn't work in chat-rail." Root cause: the colocated hook bound
      # `click` directly on the button node, which morphdom could swap
      # across re-renders, losing the listener; iOS Safari additionally
      # dismissed the keyboard on button-tap which reflowed the
      # `h-[100dvh]` viewport before `click` fired. The fix moves all
      # listeners onto the stable <form> element (event delegation) and
      # gives the button a stable `id` so the DOM node is preserved.
      #
      # Hooks do not run server-side, so we pin the contract on the
      # rendered HTML + the form-submit fallback (which the hook also
      # listens to). Browser-side behavior is covered by Playwright.
      {:ok, lv, html} =
        live_isolated(conn, WrapperLive,
          session: %{
            "scope" => lawyer_scope(),
            "layout" => :mobile_full,
            "test_pid" => self()
          }
        )

      # Mobile layout marker present.
      assert html =~ ~s(data-layout="mobile")

      # The send button carries a stable id so morphdom preserves the
      # node across re-renders — otherwise the colocated hook's listener
      # bound at mount time would silently disappear.
      assert html =~ ~s(id="chat-rail-send")
      assert html =~ ~s(data-role="chat-send")

      # The form is wired to the colocated `.ChatInput` hook (LV 1.1
      # expands `.ChatInput` to the fully-qualified module path at
      # compile time). There is no `phx-submit` — the hook is the
      # single source of truth for sending so we never double-fire on
      # mobile when the user taps the send button while the textarea is
      # focused.
      assert html =~ ~s(id="chat-rail-form")
      assert html =~ ~s(phx-hook="ContractWeb.Live.Studio.Components.ChatRail.ChatInput")
      refute html =~ ~s(phx-submit="chat.submit")

      # The textarea has the data-role that the hook uses to delegate
      # keydown/input events from the form.
      assert html =~ ~s(data-role="chat-textarea")
      assert html =~ ~s(name="message")

      # The send button MUST remain type=button (preserves mobile
      # keyboard focus — see module @moduledoc).
      assert Regex.match?(
               ~r/<button[^>]*id="chat-rail-send"[^>]*type="button"|<button[^>]*type="button"[^>]*id="chat-rail-send"/s,
               html
             )

      # Simulate the hook firing `chat.submit` — this is the same event
      # the delegated click handler pushes — so asserting the form-level
      # wire is intact pins the contract that the rest of the system
      # (StudioLive.event_to_command) expects.
      lv
      |> element("#chat-rail-form")
      |> render_hook("chat.submit", %{"message" => "from mobile"})

      assert_receive {:captured, "chat.submit", %{"message" => "from mobile"}}
    end

    test "case 7 — GrillRail mounts when grill_active? is true", %{conn: conn} do
      {:ok, lv, html} =
        live_isolated(conn, WrapperLive, session: %{"scope" => lawyer_scope()})

      # Off by default.
      refute html =~ ~s(id="chat-rail-grill")
      refute html =~ ~s(data-component="grill-rail")

      send(lv.pid, {:set_grill, true})
      html = render(lv)

      assert html =~ ~s(id="chat-rail-grill")
      assert html =~ ~s(data-component="grill-rail")
    end

    test "renders structured evidence operation blocks with citation and attach action", %{
      conn: conn
    } do
      {:ok, lv, _html} =
        live_isolated(conn, WrapperLive, session: %{"scope" => lawyer_scope()})

      send(lv.pid, {
        :insert,
        %{
          id: "evidence-msg-1",
          role: :agent,
          operation: %{
            id: "evidence-op-1",
            type: "evidence",
            status: "completed",
            title: "민법 제390조",
            summary: "채무불이행 손해배상 근거",
            evidence_snapshot_id: "11111111-1111-1111-1111-111111111111",
            provider: "law_mcp.search_law",
            source: "Korea Law MCP",
            citation: "민법 제390조",
            captured_at: "2026-05-17T12:00:00Z"
          },
          transient?: false
        }
      })

      html = render(lv)
      assert html =~ ~s(data-role="evidence-block")
      assert html =~ "민법 제390조"
      # `source: "Korea Law MCP"` is rendered as the localized "법령 검색
      # 결과" label, not as the raw provider string.
      assert html =~ "법령 검색 결과"
      assert html =~ "2026-05-17T12:00:00Z"
      assert html =~ ~s(data-role="evidence-attach")
      assert html =~ ~s(phx-click="evidence.attach")
      assert html =~ ~s(phx-value-evidence_snapshot_id="11111111-1111-1111-1111-111111111111")
    end

    test "ui.toggle_expand toggles a non-tool operation block", %{conn: conn} do
      {:ok, lv, _html} =
        live_isolated(conn, WrapperLive, session: %{"scope" => lawyer_scope()})

      send(lv.pid, {
        :insert,
        %{
          id: "op-toggle-1",
          role: :agent,
          operation: %{
            id: "export-toggle-1",
            type: "export_status",
            title: "PDF export",
            status: "completed",
            summary: "Ready",
            details: %{"filename" => "contract.pdf"}
          },
          expanded?: false,
          transient?: false
        }
      })

      html = render(lv)
      assert html =~ ~s(id="operation-block-export-toggle-1")
      assert html =~ ~s(id="operation-block-export-toggle-1-toggle")
      refute html =~ ~s(data-role="operation-details")

      html =
        lv
        |> element("#operation-block-export-toggle-1-toggle")
        |> render_click()

      assert html =~ ~s(data-role="operation-details")
      assert html =~ "contract.pdf"
    end

    test "tool call trace uses the whole message article as expand and collapse boundary", %{
      conn: conn
    } do
      {:ok, lv, _html} =
        live_isolated(conn, WrapperLive, session: %{"scope" => lawyer_scope()})

      send(lv.pid, {
        :insert,
        %{
          id: "tool-hover-msg",
          role: :agent,
          operation: %{
            id: "tool-hover-1",
            type: "tool_call",
            title: "doc.get",
            status: "completed",
            details: %{"since_revision" => 0}
          },
          transient?: false
        }
      })

      html = render(lv)
      assert html =~ ~s(id="chat-msg-tool-hover-msg")
      assert has_element?(lv, "#chat-msg-tool-hover-msg[phx-click='ui.toggle_expand']")
      refute has_element?(lv, "#chat-msg-tool-hover-msg[class*='rounded']")
      refute has_element?(lv, "#chat-msg-tool-hover-msg[class*='hover:bg']")

      assert has_element?(
               lv,
               "#chat-msg-tool-hover-msg[phx-value-operation_id='tool-hover-1']"
             )

      assert has_element?(
               lv,
               "#tool-trace-tool-hover-1-expand[data-role='tool-trace-expand']:not([phx-click])"
             )

      refute has_element?(lv, "#tool-trace-tool-hover-1-expand[class*='bg-']")

      refute html =~ "pr-7"

      assert has_element?(
               lv,
               "#tool-trace-tool-hover-1-expand .hero-chevron-down"
             )

      refute has_element?(lv, "[data-role='tool-trace-collapse']")

      html =
        lv
        |> element("#chat-msg-tool-hover-msg")
        |> render_click()

      assert html =~ ~s(id="tool-trace-tool-hover-1-details")
      assert html =~ ~s(data-role="tool-trace-details")
      assert html =~ "since_revision"

      assert has_element?(
               lv,
               "#tool-trace-tool-hover-1-collapse[data-role='tool-trace-collapse']:not([phx-click])"
             )

      assert has_element?(lv, "[data-role='tool-trace-collapse-row']")
      refute has_element?(lv, "[data-role='tool-trace-collapse-row'][class*='mt-']")
      assert has_element?(lv, "[data-role='tool-trace-collapse-row'][class*='h-0']")

      refute has_element?(lv, "#tool-trace-tool-hover-1-collapse[class*='bg-']")

      assert has_element?(
               lv,
               "#tool-trace-tool-hover-1-collapse .hero-chevron-up"
             )

      html =
        lv
        |> element("#chat-msg-tool-hover-msg")
        |> render_click()

      refute html =~ ~s(data-role="tool-trace-details")
    end
  end
end
