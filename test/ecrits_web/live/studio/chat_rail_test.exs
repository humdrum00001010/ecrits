defmodule EcritsWeb.Live.Studio.Components.ChatRailTest do
  @moduledoc """
  Component-level tests for the Studio chat rail (Wave 3C1 / chat-rail).

  Two test surfaces:

    * `render_component/2` — pure static rendering of the component (header
      pill, observer banner, mobile layout, send-button regression).
    * `live_isolated/3` with a wrapping LV — drives `:agent_stream` /
      `:agent_completed` through a stream so we can assert streaming + final
      bubbles + GrillRail mount.
  """

  use EcritsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ecrits.Context
  alias Ecrits.Studio.State
  alias EcritsWeb.Live.Studio.Components.ChatRail

  # ---------------------------------------------------------------------------
  # Wrapper LV — owns a stream and embeds ChatRail. Used for tests that need
  # to insert into `@streams.chat_messages`.
  # ---------------------------------------------------------------------------

  defmodule WrapperLive do
    use EcritsWeb, :live_view

    # We're nested inside an ExUnit test module that uses EcritsWeb.ConnCase,
    # which imports Plug.Conn — that import leaks here and clashes with
    # Phoenix.Component.assign/3. Disambiguate by aliasing.
    alias Phoenix.Component, as: PC
    alias Phoenix.LiveView, as: PLV
    alias EcritsWeb.Live.Studio.Components.ChatRail

    @impl true
    def mount(_params, session, socket) do
      scope =
        session["scope"] ||
          %Context{user: nil, perms: ~w(read write commit revoke agent_run export type_change)a}

      state =
        session["studio_state"] ||
          %State{
            mode: :briefing,
            last_seen_version: 0,
            agent_run_id: nil
          }

      socket =
        socket
        |> PC.assign(:scope, scope)
        |> PC.assign(:studio_state, state)
        |> PC.assign(:chat_thread, session["chat_thread"])
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

    def handle_event("chat.context_reset", params, socket) do
      if pid = socket.assigns[:test_pid],
        do: send(pid, {:captured, "chat.context_reset", params})

      {:noreply, socket}
    end

    def handle_event("chat.thread.rename", params, socket) do
      if pid = socket.assigns[:test_pid],
        do: send(pid, {:captured, "chat.thread.rename", params})

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
          chat_thread={@chat_thread}
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
  # Scope fixtures (mirror Ecrits.PersonaFactory).
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
    do: %State{mode: :briefing, last_seen_version: 0, agent_run_id: nil}

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

    test "renders compact title controls with context reset" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          chat_thread: %{title: "Discussion - Scope confirmed", message_count: 4},
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope()
        )

      assert html =~ ~s(data-role="chat-rail-controls")
      assert html =~ ~s(data-role="chat-title-favicon")
      assert html =~ ~s(aria-hidden="true")
      assert html =~ ~s(src="/images/icons/openai-blossom.svg")
      refute html =~ ~s(src="/assets/icons/openai-chatgpt-icon.png")
      assert html =~ ~s(data-role="chat-thread-title")
      assert html =~ ~s(data-role="chat-thread-title-input")
      assert html =~ ~s(id="chat-thread-title-input")
      assert html =~ ~s(name="title")
      assert html =~ ~s(value="Discussion - Scope confirmed")
      assert html =~ ~s(phx-submit="chat.thread.rename")
      assert html =~ ~s(phx-change="chat.thread.rename")
      assert html =~ ~s(phx-debounce="blur")

      assert [] =
               html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(~s([data-role="chat-thread-title-input"]))
               |> LazyHTML.attribute("disabled")

      assert html =~ ~s(data-role="chat-context-reset")
      assert html =~ ~s(phx-click="chat.context_reset")
      assert html =~ ~s(aria-label="Reset chat context")
      refute html =~ "Agent context"
      refute html =~ ~s(data-role="chat-message-count")
      refute html =~ ~s(data-role="chat-rail-navbar")
      refute html =~ ~s(data-brand="openai")

      [controls_class] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="chat-rail-controls"]))
        |> LazyHTML.attribute("class")

      assert controls_class =~ "gap-1.5"
      assert controls_class =~ "px-1.5"
      assert controls_class =~ "py-0.5"
      refute controls_class =~ "gap-2"
      refute controls_class =~ "px-2"
      refute controls_class =~ "py-1"
      refute controls_class =~ "px-3"
      refute controls_class =~ "py-2"

      [favicon_class] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="chat-title-favicon"]))
        |> LazyHTML.attribute("class")

      assert favicon_class =~ "size-4"
      assert favicon_class =~ "opacity-85"
      refute favicon_class =~ "invert"
      refute favicon_class =~ "rounded"
      refute favicon_class =~ "size-7"
      refute favicon_class =~ "size-5"
      refute favicon_class =~ "size-6"
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

    test "no-document mode omits the ChatRail welcome dialog and keeps the composer" do
      no_doc_state = %State{mode: :no_document, last_seen_version: 0, agent_run_id: nil}

      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: no_doc_state,
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope()
        )

      refute html =~ ~s(id="chat-rail-no-doc-welcome")
      refute html =~ ~s(data-role="chat-no-doc-welcome")
      refute html =~ ~s(data-role="chat-welcome")

      refute html =~ "새 문서를 시작합니다. 어떻게 시작할까요?"
      refute html =~ "무엇으로 시작할까요?"
      refute html =~ "최근 문서 열기"
      refute html =~ "빈 계약서 만들기"
      refute html =~ "논의에서 시작"
      refute html =~ "다른 문서에서 변형 만들기"

      assert html =~ ~s(data-role="chat-form")
      assert html =~ ~s(data-role="chat-textarea")
      assert html =~ ~s(data-role="chat-send")
      assert html =~ ~s(data-role="chat-upload")
      assert html =~ ~s(for="document-direct-upload-input")
      refute html =~ ~s(phx-value-key="upload")
      refute html =~ ~s(phx-value-key="recent")
      refute html =~ ~s(phx-value-key="blank")
      refute html =~ ~s(phx-value-key="draft_from_discussion")
      refute html =~ ~s(phx-value-key="variant_from_other")
    end

    test "no-document mode stays free of ChatRail welcome when chat messages exist", %{
      conn: conn
    } do
      no_doc_state = %State{mode: :no_document, last_seen_version: 0, agent_run_id: nil}

      {:ok, lv, html} =
        live_isolated(conn, WrapperLive,
          session: %{"scope" => lawyer_scope(), "studio_state" => no_doc_state}
        )

      refute html =~ ~s(id="chat-rail-no-doc-welcome")
      refute html =~ "새 문서를 시작합니다. 어떻게 시작할까요?"
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
      refute html =~ ~s(id="chat-rail-no-doc-welcome")
      refute html =~ "새 문서를 시작합니다. 어떻게 시작할까요?"
      assert html =~ ~s(id="chat-msg-user-real-1")
      assert html =~ ~s(data-role="chat-message")
    end

    test "agent status drives the composer action without a header status label" do
      idle_html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: %State{default_state() | agent_run_id: nil},
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope()
        )

      idle_fragment = LazyHTML.from_fragment(idle_html)

      assert [] =
               idle_fragment
               |> LazyHTML.query(~s([data-role="agent-status"]))
               |> LazyHTML.attribute("data-role")

      assert ["chat-send"] =
               idle_fragment
               |> LazyHTML.query(~s([data-role="chat-send"]))
               |> LazyHTML.attribute("data-role")

      refute idle_fragment
             |> LazyHTML.query(~s([data-role="chat-rail-controls"]))
             |> LazyHTML.text() =~
               "대기"

      run_id = Ecto.UUID.generate()
      queued_run_id = Ecto.UUID.generate()

      busy_html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: %State{default_state() | agent_run_id: run_id},
          agent_document_status: %{
            current_attempt: %{id: run_id, status: :running},
            queue: [%{id: queued_run_id, status: :pending}]
          },
          streams: %{chat_messages: empty_stream()},
          current_scope: lawyer_scope()
        )

      busy_fragment = LazyHTML.from_fragment(busy_html)

      assert [] =
               busy_fragment
               |> LazyHTML.query(~s([data-role="agent-status"]))
               |> LazyHTML.attribute("data-role")

      assert ["chat-stop"] =
               busy_fragment
               |> LazyHTML.query(~s([data-role="chat-stop"]))
               |> LazyHTML.attribute("data-role")

      refute busy_fragment
             |> LazyHTML.query(~s([data-role="chat-rail-controls"]))
             |> LazyHTML.text() =~
               "응답 중"

      assert %{
               key: :queued,
               current_run_id: ^run_id,
               queue_size: 1
             } =
               ChatRail.agent_status(%State{default_state() | agent_run_id: run_id}, %{
                 current_attempt: %{id: run_id, status: :running},
                 queue: [%{id: queued_run_id, status: :pending}]
               })
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

      # MDEx wraps the completed prose in a <p> inside the shared prose
      # container; data-role keeps streaming appends attached to the same
      # paragraph node.
      assert agent_text |> LazyHTML.text() |> String.trim() == "왼쪽에서 시작해야 합니다."

      paragraph =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(
          ~s(#chat-msg-agent-left [data-role="chat-md-body"] p[data-role="agent-paragraph"])
        )

      assert paragraph |> LazyHTML.text() |> String.trim() == "왼쪽에서 시작해야 합니다."

      [class] =
        agent_text
        |> LazyHTML.parent_node()
        |> LazyHTML.attribute("class")

      assert class =~ "self-start"
      refute class =~ "self-center"
    end

    test "agent prose renders limited Markdown and escapes raw HTML" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{
            chat_messages: [
              {"chat-msg-agent-markdown",
               %{
                 id: "agent-markdown",
                 role: :agent,
                 result: %{
                   body: """
                   Intro **bold** and *emphasis* with `inline()` and [docs](https://example.com/docs).

                   - first item
                   - second item

                   > quoted guidance

                   ```elixir
                   IO.puts("<safe>")
                   ```

                   <script>alert("x")</script>
                   """
                 },
                 transient?: false
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      fragment = LazyHTML.from_fragment(html)

      # MDEx (comrak GFM) emits standard semantic tags inside the shared
      # prose container.
      assert fragment |> LazyHTML.query(~s([data-role="chat-md-body"] p)) |> Enum.any?()

      assert fragment
             |> LazyHTML.query(~s([data-role="chat-md-body"] p[data-role="agent-paragraph"]))
             |> Enum.any?()

      assert fragment |> LazyHTML.query(~s([data-role="chat-md-body"] ul li)) |> Enum.any?()
      assert fragment |> LazyHTML.query(~s([data-role="chat-md-body"] blockquote)) |> Enum.any?()
      # Fenced code block: a <pre><code class="language-elixir"> with MDEx's
      # inlined syntax-highlight styles.
      assert fragment |> LazyHTML.query(~s([data-role="chat-md-body"] pre code)) |> Enum.any?()

      assert fragment |> LazyHTML.query("strong") |> LazyHTML.text() |> String.trim() == "bold"
      assert fragment |> LazyHTML.query("em") |> LazyHTML.text() |> String.trim() == "emphasis"

      # Inline code is a bare <code> (not inside <pre>).
      assert fragment
             |> LazyHTML.query(~s([data-role="chat-md-body"] p code))
             |> LazyHTML.text()
             |> String.trim() == "inline()"

      assert LazyHTML.attribute(LazyHTML.query(fragment, "a"), "href") == [
               "https://example.com/docs"
             ]

      assert LazyHTML.attribute(
               LazyHTML.query(fragment, ~s([data-role="chat-md-body"] pre code)),
               "class"
             ) == ["language-elixir"]

      assert fragment
             |> LazyHTML.query(~s([data-role="chat-md-body"] pre code))
             |> LazyHTML.text()
             |> String.trim() == "IO.puts(\"<safe>\")"

      # MDEx runs with the default `unsafe: false`, so raw HTML in the source
      # is DROPPED entirely (replaced by an HTML comment) rather than escaped —
      # the agent/user can never inject live markup.
      refute html =~ "<script>"
      refute html =~ "alert(&quot;x&quot;)"
    end

    test "agent prose repairs streamed sentence boundaries without touching code" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{
            chat_messages: [
              {"chat-msg-agent-boundary",
               %{
                 id: "agent-boundary",
                 role: :agent,
                 result: %{
                   body: """
                   확인한다.첫 장을 본다.JSONL 검증도 한다.

                   `코드.깨면안됨`

                   ```text
                   코드.깨면안됨
                   ```
                   """
                 },
                 transient?: false
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      fragment = LazyHTML.from_fragment(html)

      paragraph_text =
        fragment
        |> LazyHTML.query(~s(#chat-msg-agent-boundary [data-role="chat-md-body"] p))
        |> LazyHTML.text()

      assert paragraph_text =~ "확인한다. 첫 장을 본다. JSONL 검증도 한다."

      assert fragment
             |> LazyHTML.query(~s(#chat-msg-agent-boundary [data-role="chat-md-body"] p code))
             |> LazyHTML.text()
             |> String.trim() == "코드.깨면안됨"

      assert fragment
             |> LazyHTML.query(~s(#chat-msg-agent-boundary [data-role="chat-md-body"] pre code))
             |> LazyHTML.text()
             |> String.trim() == "코드.깨면안됨"
    end

    test "user messages render Markdown without allowing raw HTML injection" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{
            chat_messages: [
              {"chat-msg-user-markdown",
               %{
                 id: "user-markdown",
                 role: :user,
                 body: """
                 1. first
                 2. second

                 Use `<tag>` but not <b>raw html</b>.
                 """,
                 transient?: false
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      fragment = LazyHTML.from_fragment(html)

      # MDEx renders the ordered list as a standard <ol> inside the prose container.
      assert fragment |> LazyHTML.query(~s([data-role="chat-md-body"] ol li)) |> Enum.any?()

      list_text =
        fragment
        |> LazyHTML.query("ol li")
        |> LazyHTML.text()

      assert list_text =~ "first"
      assert list_text =~ "second"

      assert fragment
             |> LazyHTML.query(~s([data-role="chat-md-body"] p code))
             |> LazyHTML.text()
             |> String.trim() == "<tag>"

      # Raw inline HTML is dropped by MDEx's default safe mode, not escaped.
      refute html =~ "<b>raw html</b>"
      refute html =~ ~s(&lt;b&gt;raw html&lt;/b&gt;)
    end

    test "tool call details stay plain escaped JSON instead of Markdown" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{
            chat_messages: [
              {"chat-msg-tool-markdown-json",
               %{
                 id: "tool-markdown-json",
                 role: :agent,
                 operation: %{
                   id: "tool-markdown-json",
                   type: "tool_call",
                   title: "debug.echo",
                   status: "failed",
                   summary: "**not bold**",
                   details: %{
                     "payload" => "```json\n{\"unsafe\":\"<script>\"}\n```"
                   }
                 },
                 transient?: false
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      fragment = LazyHTML.from_fragment(html)

      assert fragment
             |> LazyHTML.query(~s([data-role="tool-trace-summary"]))
             |> LazyHTML.text()
             |> String.trim() == "**not bold**"

      assert LazyHTML.text(LazyHTML.query(fragment, ~s([data-role="tool-trace-details"] pre))) =~
               "```json"

      refute html =~ ~s([data-role="chat-md-code-block"])
      refute html =~ "<script>"
    end

    test "transient agent prose shows a loading indicator until the final message arrives" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{
            chat_messages: [
              {"chat-msg-agent-loading",
               %{
                 id: "agent-loading",
                 role: :agent,
                 body: "",
                 transient?: true
               }},
              {"chat-msg-agent-final",
               %{
                 id: "agent-final",
                 role: :agent,
                 body: "Final answer.",
                 transient?: false
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      fragment = LazyHTML.from_fragment(html)

      [loading_role] =
        fragment
        |> LazyHTML.query(~s(#chat-msg-agent-loading [data-role="agent-loading"]))
        |> LazyHTML.attribute("role")

      assert loading_role == "status"

      [aria_busy] =
        fragment
        |> LazyHTML.query(~s(#chat-msg-agent-loading [data-role="agent-text"]))
        |> LazyHTML.attribute("aria-busy")

      assert aria_busy == "true"

      assert [] =
               fragment
               |> LazyHTML.query(~s(#chat-msg-agent-final [data-role="agent-loading"]))
               |> LazyHTML.attribute("role")
    end

    test "reasoning renders through operation_block as a compact aligned row" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{
            chat_messages: [
              {"chat-msg-reasoning-compact",
               %{
                 id: "reasoning-compact",
                 role: :agent,
                 operation: %{
                   "id" => "reasoning-compact",
                   "type" => "reasoning",
                   "title" => "Thinking",
                   "status" => "running",
                   "summary" => "First internal step",
                   "details" => %{
                     "text" =>
                       "First internal step\nSecond internal step that should not expand the rail layout."
                   }
                 },
                 transient?: true
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      fragment = LazyHTML.from_fragment(html)

      [article_class] =
        fragment
        |> LazyHTML.query(~s(#chat-msg-reasoning-compact))
        |> LazyHTML.attribute("class")

      refute article_class =~ "max-w"

      assert html =~ ~s(id="tool-trace-reasoning-compact")

      assert html =~ "hero-wrench-screwdriver"
      assert html =~ "Thinking:"
      assert html =~ "First internal step"

      [text_class] =
        fragment
        |> LazyHTML.query(~s(#chat-msg-reasoning-compact [data-role="agent-reasoning-text"]))
        |> LazyHTML.attribute("class")

      assert text_class =~ "truncate"
      assert text_class =~ "whitespace-nowrap"

      # Reasoning uses the same trace structure as tool_call — no separate
      # `<details>` element with native browser disclosure.
      refute html =~ ~s(<details)
    end

    test "completed empty reasoning is not rendered as a stale thinking row" do
      # The document_live `:agent_reasoning_done` handler removes the
      # reasoning bubble entirely when `text` is empty, so the chat_rail
      # only ever sees a non-empty reasoning operation. This test pins the
      # equivalent invariant at the component level: a row carrying ONLY
      # `kind: :reasoning` with no operation must be hidden.
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{
            chat_messages: [
              {"chat-msg-reasoning-empty",
               %{
                 id: "reasoning-empty",
                 role: :agent,
                 kind: :reasoning,
                 body: "",
                 transient?: false
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      refute html =~ ~s(data-role="agent-reasoning")
      refute html =~ "생각 중"
    end

    test "legacy `kind: :thinking` row no longer renders (consolidated into the reasoning bubble)" do
      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: default_state(),
          streams: %{
            chat_messages: [
              {"chat-msg-thinking-run",
               %{
                 id: "thinking-run",
                 role: :agent,
                 kind: :thinking,
                 body: "Thinking...",
                 transient?: true
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      refute html =~ ~s(data-role="agent-thinking")
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
      assert html =~ "Hello,"

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
      assert html =~ "Hello,"
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

    test "context reset button dispatches the parent reset event", %{conn: conn} do
      {:ok, lv, html} =
        live_isolated(conn, WrapperLive,
          session: %{
            "scope" => lawyer_scope(),
            "test_pid" => self(),
            "chat_thread" => %{title: "Discussion - Scope confirmed", message_count: 3}
          }
        )

      assert html =~ ~s(data-role="chat-context-reset")

      lv
      |> element(~s([data-role="chat-context-reset"]))
      |> render_click()

      assert_receive {:captured, "chat.context_reset", %{}}
    end

    test "title input dispatches the parent rename event", %{conn: conn} do
      {:ok, lv, html} =
        live_isolated(conn, WrapperLive,
          session: %{
            "scope" => lawyer_scope(),
            "test_pid" => self(),
            "chat_thread" => %{
              id: Ecto.UUID.generate(),
              title: "Discussion - Scope confirmed",
              message_count: 3
            }
          }
        )

      assert html =~ ~s(id="chat-thread-title-form")

      lv
      |> form("#chat-thread-title-form", %{"title" => "Deal setup"})
      |> render_submit()

      assert_receive {:captured, "chat.thread.rename", %{"title" => "Deal setup"}}
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
      assert html =~ ~s(phx-hook="EcritsWeb.Live.Studio.Components.ChatRail.ChatInput")
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
      # (DocumentLive.event_to_command) expects.
      lv
      |> element("#chat-rail-form")
      |> render_hook("chat.submit", %{"message" => "from mobile"})

      assert_receive {:captured, "chat.submit", %{"message" => "from mobile"}}
    end

    test "mobile send hook sends on pointerdown without relying on form submit or click",
         %{conn: conn} do
      {:ok, _lv, html} =
        live_isolated(conn, WrapperLive,
          session: %{
            "scope" => lawyer_scope(),
            "layout" => :mobile_full,
            "test_pid" => self()
          }
        )

      source =
        File.read!(
          Path.expand("../../../../lib/ecrits_web/live/studio/components/chat_rail.ex", __DIR__)
        )

      [_, pointerdown_block] =
        Regex.run(
          ~r/this\.onFormPointerDown = \(e\) => \{(?<body>.*?)\n            \}\n\n            this\.onFormClick/s,
          source
        )

      assert pointerdown_block =~ "this.send(e)"

      refute html =~ ~s(phx-submit="chat.submit")
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

    test "non-tool operation block expand uses client-side JS toggle on the details panel",
         %{conn: conn} do
      {:ok, lv, _html} =
        live_isolated(conn, WrapperLive, session: %{"scope" => lawyer_scope()})

      send(lv.pid, {
        :insert,
        %{
          id: "op-toggle-1",
          role: :agent,
          operation: %{
            id: "op-toggle-1",
            type: "status",
            title: "Background task",
            status: "completed",
            summary: "Ready",
            details: %{"detail" => "complete"}
          },
          transient?: false
        }
      })

      html = render(lv)
      fragment = LazyHTML.from_fragment(html)

      assert html =~ ~s(id="operation-block-op-toggle-1")
      assert html =~ ~s(id="operation-block-op-toggle-1-toggle")

      # Details panel is always rendered, with the `hidden` attribute so
      # the JS toggle on the button can flip it client-side without
      # needing a server roundtrip (the row is inside a phx-update="stream"
      # container, so changing an outer assign would not re-render it).
      details =
        fragment
        |> LazyHTML.query("#operation-block-op-toggle-1-details")

      [details_hidden] = LazyHTML.attribute(details, "hidden")
      assert details_hidden == "" or details_hidden == "hidden"
      assert html =~ "complete"

      # The toggle button carries a JS-encoded phx-click — no server event.
      [phx_click] =
        fragment
        |> LazyHTML.query("#operation-block-op-toggle-1-toggle")
        |> LazyHTML.attribute("phx-click")

      assert phx_click =~ "toggle_attr"
      assert phx_click =~ ~s(hidden)
      assert phx_click =~ "#operation-block-op-toggle-1-details"
      assert phx_click =~ "aria-expanded"
    end

    test "tool call trace uses the whole message article as a client-side JS toggle target", %{
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
            name: "doc.get",
            output: %{"status" => "ok"}
          },
          transient?: false
        }
      })

      html = render(lv)
      fragment = LazyHTML.from_fragment(html)

      assert html =~ ~s(id="chat-msg-tool-hover-msg")
      refute has_element?(lv, "#chat-msg-tool-hover-msg[class*='rounded']")
      refute has_element?(lv, "#chat-msg-tool-hover-msg[class*='hover:bg']")

      # Article carries a JS-encoded phx-click — no server roundtrip.
      [article_phx_click] =
        fragment
        |> LazyHTML.query("#chat-msg-tool-hover-msg")
        |> LazyHTML.attribute("phx-click")

      assert article_phx_click =~ "toggle_attr"
      assert article_phx_click =~ ~s(tool-trace-tool-hover-1-details)
      assert article_phx_click =~ "aria-expanded"

      assert has_element?(lv, "#chat-msg-tool-hover-msg[aria-expanded='false']")

      assert has_element?(
               lv,
               "#chat-msg-tool-hover-msg[aria-controls='tool-trace-tool-hover-1-details']"
             )

      # The chevron and the 접기 sub-elements never carry their own
      # phx-click — they bubble cleanly to the article handler.
      assert has_element?(
               lv,
               "#tool-trace-tool-hover-1-expand[data-role='tool-trace-expand']:not([phx-click])"
             )

      refute has_element?(lv, "#tool-trace-tool-hover-1-expand[class*='bg-']")

      assert has_element?(
               lv,
               "#tool-trace-tool-hover-1-expand .hero-chevron-down"
             )

      # Details panel is always rendered + `hidden` so the JS toggle can
      # flip it on the client. Inspect the attribute directly.
      details =
        fragment
        |> LazyHTML.query("#tool-trace-tool-hover-1-details")

      [details_hidden] = LazyHTML.attribute(details, "hidden")
      assert details_hidden == "" or details_hidden == "hidden"
      assert html =~ ~s(data-role="tool-trace-details")
      assert html =~ "status"
      assert html =~ "doc.get"

      assert has_element?(
               lv,
               "#tool-trace-tool-hover-1-collapse[data-role='tool-trace-collapse']:not([phx-click])"
             )

      assert has_element?(lv, "[data-role='tool-trace-collapse-row']")
      refute has_element?(lv, "[data-role='tool-trace-collapse-row'][class*='mt-']")
      assert has_element?(lv, "[data-role='tool-trace-collapse-row'][class*='pt-1']")

      refute has_element?(lv, "#tool-trace-tool-hover-1-collapse[class*='bg-']")

      assert has_element?(
               lv,
               "#tool-trace-tool-hover-1-collapse .hero-chevron-up"
             )
    end

    test "failed tool call trace shows visible details affordance and renders the failure payload",
         %{conn: conn} do
      {:ok, lv, _html} =
        live_isolated(conn, WrapperLive, session: %{"scope" => lawyer_scope()})

      send(lv.pid, {
        :insert,
        %{
          id: "tool-failed-msg",
          role: :agent,
          operation: %{
            id: "tool-failed-1",
            name: "doc.get",
            error: "ecrits-doc returned 424 Failed Dependency"
          },
          transient?: false
        }
      })

      html = render(lv)
      fragment = LazyHTML.from_fragment(html)

      assert html =~ ~s(id="chat-msg-tool-failed-msg")

      [article_phx_click] =
        fragment
        |> LazyHTML.query("#chat-msg-tool-failed-msg")
        |> LazyHTML.attribute("phx-click")

      assert article_phx_click =~ "toggle_attr"
      assert article_phx_click =~ ~s(tool-trace-tool-failed-1-details)

      assert has_element?(lv, "#tool-trace-tool-failed-1[data-status='failed']")

      assert has_element?(
               lv,
               "#tool-trace-tool-failed-1-expand[data-role='tool-trace-expand'][data-visible='true']"
             )

      # Details panel is rendered + hidden so the JS toggle can flip it.
      details =
        fragment
        |> LazyHTML.query("#tool-trace-tool-failed-1-details")

      [details_hidden] = LazyHTML.attribute(details, "hidden")
      assert details_hidden == "" or details_hidden == "hidden"
      assert html =~ "ecrits-doc returned 424 Failed Dependency"
      assert html =~ "doc.get"
    end

    test "freshly stream_inserted tool_call article toggles via client-side JS (no server roundtrip)",
         %{conn: conn} do
      # Regression: tool_call rows inserted mid-conversation by the parent
      # LV via `stream_insert(:chat_messages, ...)` would refuse to expand
      # on the first click — the user had to reload the page first. Root
      # cause was that `phx-update="stream"` items don't re-render when
      # outer assigns change, so server-side expand state (`MapSet` on
      # the LiveComponent) never reached the DOM after insertion. Fix
      # moves the toggle to a `Phoenix.LiveView.JS` command on the
      # article that flips `hidden` on the details panel client-side.
      # This test pins the wiring + asserts the details panel is always
      # rendered and starts hidden.
      {:ok, lv, _html} =
        live_isolated(conn, WrapperLive, session: %{"scope" => lawyer_scope()})

      send(lv.pid, {
        :insert,
        %{
          id: "tool-fresh-msg",
          role: :agent,
          operation: %{
            id: "tool-fresh-1",
            type: "tool_call",
            title: "doc.find",
            status: "completed",
            details: %{"q" => "delivery"}
          },
          transient?: false
        }
      })

      html = render(lv)
      fragment = LazyHTML.from_fragment(html)

      [article_phx_click] =
        fragment
        |> LazyHTML.query("#chat-msg-tool-fresh-msg")
        |> LazyHTML.attribute("phx-click")

      assert article_phx_click =~ "toggle_attr"
      assert article_phx_click =~ ~s(tool-trace-tool-fresh-1-details)
      assert article_phx_click =~ "aria-expanded"

      # No phx-target needed — the click never reaches the server.
      assert LazyHTML.query(fragment, "#chat-msg-tool-fresh-msg")
             |> LazyHTML.attribute("phx-target") == []

      # Chevron must not carry phx-click — otherwise its click bubbles up
      # to the article and the JS toggle would fire twice (no-op).
      assert has_element?(
               lv,
               "#tool-trace-tool-fresh-1-expand[data-role='tool-trace-expand']:not([phx-click])"
             )

      # Details panel rendered + hidden — the JS toggle flips the
      # `hidden` attribute on the client.
      details =
        fragment
        |> LazyHTML.query("#tool-trace-tool-fresh-1-details")

      [details_hidden] = LazyHTML.attribute(details, "hidden")
      assert details_hidden == "" or details_hidden == "hidden"
      assert html =~ "delivery"
    end

    test "reasoning row renders through operation_block (same data-roles as tool_call) with JS toggle",
         %{conn: conn} do
      {:ok, lv, _html} =
        live_isolated(conn, WrapperLive, session: %{"scope" => lawyer_scope()})

      send(lv.pid, {
        :insert,
        %{
          id: "reasoning-run-1",
          role: :agent,
          operation: %{
            "id" => "reasoning-run-1",
            "type" => "reasoning",
            "title" => "Thinking",
            "status" => "completed",
            "summary" => "Reviewing the title clause",
            "details" => %{
              "text" => "Reviewing the title clause\nThen check the effective date."
            }
          },
          transient?: false
        }
      })

      html = render(lv)
      fragment = LazyHTML.from_fragment(html)

      # Same article-level JS toggle as tool_call — pure client-side.
      [article_phx_click] =
        fragment
        |> LazyHTML.query("#chat-msg-reasoning-run-1")
        |> LazyHTML.attribute("phx-click")

      assert article_phx_click =~ "toggle_attr"
      assert article_phx_click =~ ~s(tool-trace-reasoning-run-1-details)

      # No standalone `<details>` element — reasoning shares operation_block.
      refute html =~ ~s(<details data-role="agent-reasoning")

      # Streaming JS hook targets these data-roles (kept across the refactor
      # so per-delta TextNode appends don't break).
      assert html =~ ~s(data-role="agent-reasoning-text")
      assert html =~ ~s(id="tool-trace-reasoning-run-1")

      assert html =~ "Thinking:"
      assert html =~ "Reviewing the title clause"

      # Details panel is rendered + hidden — the JS toggle flips `hidden`
      # client-side on the same DOM element.
      details =
        fragment
        |> LazyHTML.query("#tool-trace-reasoning-run-1-details")

      [details_hidden] = LazyHTML.attribute(details, "hidden")
      assert details_hidden == "" or details_hidden == "hidden"
      assert html =~ ~s(data-role="agent-reasoning-details-text")
      assert html =~ "Then check the effective date."
    end

    test "transient reasoning live append targets collapsed row and expanded details content" do
      agent_run_id = "72514285-c931-4db4-abcf-e1d1c118d552"
      operation_id = "reasoning-#{agent_run_id}"
      message_dom_id = "chat-msg-reasoning-#{agent_run_id}"

      html =
        render_component(ChatRail,
          id: "chat-rail",
          studio_state: %State{default_state() | agent_run_id: agent_run_id},
          streams: %{
            chat_messages: [
              {message_dom_id,
               %{
                 id: operation_id,
                 role: :agent,
                 operation: %{
                   "id" => operation_id,
                   "type" => "reasoning",
                   "title" => "Thinking",
                   "status" => "running",
                   "summary" => "",
                   "details" => %{"text" => ""}
                 },
                 transient?: true
               }}
            ]
          },
          current_scope: lawyer_scope()
        )

      fragment = LazyHTML.from_fragment(html)

      assert LazyHTML.attribute(LazyHTML.query(fragment, "##{message_dom_id}"), "hidden") == [
               ""
             ]

      refute html =~ "생각 중"

      collapsed =
        fragment
        |> LazyHTML.query(
          ~s([data-role="agent-reasoning-text"][data-message-id="#{message_dom_id}"])
        )

      assert LazyHTML.attribute(collapsed, "data-placeholder") == ["true"]

      details_content =
        fragment
        |> LazyHTML.query(
          ~s(#tool-trace-#{operation_id}-details > [data-role="agent-reasoning-details-content"][data-message-id="#{message_dom_id}"])
        )

      assert LazyHTML.attribute(details_content, "data-message-id") == [message_dom_id]

      details_text =
        fragment
        |> LazyHTML.query(
          ~s(#tool-trace-#{operation_id}-details [data-role="agent-reasoning-details-text"][data-message-id="#{message_dom_id}"])
        )

      assert LazyHTML.attribute(details_text, "data-message-id") == [message_dom_id]

      source =
        File.read!(
          Path.expand("../../../../lib/ecrits_web/live/studio/components/chat_rail.ex", __DIR__)
        )

      [_, handler] =
        Regex.run(
          ~r/this\.onReasoningAppend = \(e\) => \{(?<body>.*?)\n            \}\n            window\.addEventListener\("phx:agent_reasoning_append"/s,
          source
        )

      assert handler =~ ~s([data-role="agent-reasoning-text"][data-message-id="${id}"])
      assert handler =~ ~s([data-role="agent-reasoning-details-content"][data-message-id="${id}"])
      assert handler =~ ~s([data-role="agent-reasoning-details-text"])
      assert handler =~ ~S|closest('[data-role="chat-message"]')|
      assert handler =~ ~S|removeAttribute("hidden")|
    end
  end
end
