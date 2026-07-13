defmodule EcritsWeb.Live.Studio.Components.GrillRailTest do
  @moduledoc """
  Wave 3C1 `grill-rail` component tests.

  Strategy: all cases hit `render_component/2` directly and assert
  against the produced HTML. The `chat.submit` event binding is
  verified by inspecting the rendered `phx-click` / `phx-value-*`
  attributes; the matching `event_to_action/3` clause in `DocumentLive`
  is already covered by `test/ecrits_web/live/document_live_test.exs`.
  """
  use EcritsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ecrits.Context
  alias Ecrits.Studio.ChatRailState
  alias Ecrits.Studio.State
  alias EcritsWeb.Live.Studio.Components.GrillRail

  # ---- Fixtures --------------------------------------------------------

  defp lawyer_scope,
    do: %Context{
      user: %{id: "u-lawyer"},
      perms: ~w(read write commit revoke export type_change agent_run)a
    }

  defp agent_supervised_scope,
    do: %Context{
      user: %{id: "u-agent-sup"},
      perms: ~w(read write commit revoke agent_run)a
    }

  defp viewer_scope, do: %Context{user: %{id: "u-viewer"}, perms: [:read]}

  defp studio_state(opts \\ []) do
    %State{
      mode: :reviewing,
      last_seen_version: 12,
      agent_run_id: Keyword.get(opts, :agent_run_id, "run-abc")
    }
  end

  defp ask_mark(id, text, opts \\ []) do
    %{
      id: id,
      intent: :ask,
      source: :agent,
      text: text,
      target_type: :document,
      target_id: "doc-1",
      data:
        opts
        |> Keyword.take([:rationale, :answer])
        |> Enum.into(%{}, fn {k, v} -> {Atom.to_string(k), v} end)
    }
  end

  defp base_assigns(extra) when is_map(extra) do
    attrs =
      Map.merge(
        %{
          grill_marks: [],
          current_scope: lawyer_scope(),
          studio_state: studio_state()
        },
        extra
      )

    %{id: "grill-rail", state: ChatRailState.new(attrs)}
  end

  # ---- 1. Renders 3 ask-marks as 3 input panels ------------------------

  describe "render_component/2 — unanswered ask-marks" do
    test "renders three ask-marks as three input panels with a submit each" do
      marks = [
        ask_mark("m1", "What is the governing law?"),
        ask_mark("m2", "Are there auto-renew clauses?", rationale: "변호사 검토 필요"),
        ask_mark("m3", "Confirm tenant indemnity scope.")
      ]

      html = render_component(GrillRail, base_assigns(%{grill_marks: marks}))

      assert html =~ ~s(data-component="grill-rail")
      assert html =~ ~s(data-perm-mode="answer")

      # All three question texts present.
      assert html =~ "What is the governing law?"
      assert html =~ "Are there auto-renew clauses?"
      assert html =~ "Confirm tenant indemnity scope."

      # Rationale shows when present, hides when absent.
      assert html =~ ~s(data-role="grill-rationale")
      assert html =~ "변호사 검토 필요"

      # Three input panels, each with an answer textarea.
      assert html =~ ~s(id="grill-mark-m1")
      assert html =~ ~s(id="grill-mark-m2")
      assert html =~ ~s(id="grill-mark-m3")

      assert count_substr(html, ~s(data-role="grill-answer-input")) == 3
      assert count_substr(html, ~s(<textarea)) == 3

      # Three submit buttons.
      assert count_substr(html, ~s(data-role="grill-submit")) == 3
    end

    test "rationale paragraph omitted when mark has no rationale" do
      marks = [ask_mark("m1", "Question with no rationale.")]
      html = render_component(GrillRail, base_assigns(%{grill_marks: marks}))

      refute html =~ ~s(data-role="grill-rationale")
    end
  end

  # ---- 2. Submit button is type=button ---------------------------------

  # Wave 3C1 binding ecrits: the submit button is `phx-click="chat.submit"`
  # with NO `phx-target` (event bubbles to parent LV), `type="button"` (form
  # never auto-submits), and the grill_response payload is JSON-encoded in a
  # `phx-value-*` attribute that round-trips through `DocumentLive.event_to_action`.
  describe "submit-button binding" do
    test "submit button is type=button, bubbles chat.submit with grill_response payload" do
      marks = [ask_mark("ask-123", "Why?")]
      html = render_component(GrillRail, base_assigns(%{grill_marks: marks}))

      assert html =~ ~r/<button[^>]+type="button"[^>]+data-role="grill-submit"/
      refute html =~ ~r/<button[^>]+type="submit"[^>]+data-role="grill-submit"/
      assert html =~ ~s(phx-submit="noop")
      assert html =~ ~s(phx-click="chat.submit")
      assert html =~ ~s(phx-value-mark_id="ask-123")
      assert html =~ ~s(phx-value-grill_response=)
      assert html =~ "&quot;mark_id&quot;:&quot;ask-123&quot;"
      assert html =~ ~s(phx-change="draft_changed")

      # Submit button must not carry its own phx-target — bubbles to parent LV.
      submit_button =
        Regex.run(~r{<button[^>]+data-role="grill-submit"[^>]*>}, html)
        |> List.first()

      refute submit_button =~ "phx-target"
    end
  end

  # ---- 4. :viewer renders empty ----------------------------------------

  describe ":viewer persona" do
    test "viewer scope yields an empty (hidden) render" do
      marks = [ask_mark("m1", "Should this show?")]

      html =
        render_component(
          GrillRail,
          base_assigns(%{grill_marks: marks, current_scope: viewer_scope()})
        )

      # The wrapper is rendered but the inside is empty (no <h3>, no <ul>).
      assert html =~ ~s(data-perm-mode="hidden")
      refute html =~ "Should this show?"
      refute html =~ ~s(data-role="grill-ask")
      refute html =~ ~s(data-role="grill-submit")
      refute html =~ ~s(<ul)
    end
  end

  # ---- 5. :agent_supervised renders read-only --------------------------

  describe ":agent_supervised persona" do
    test "agent_supervised sees the question but no submit button or textarea" do
      marks = [ask_mark("m1", "Confirm the deposit amount?")]

      html =
        render_component(
          GrillRail,
          base_assigns(%{
            grill_marks: marks,
            current_scope: agent_supervised_scope()
          })
        )

      assert html =~ ~s(data-perm-mode="readonly")
      # Question text still visible.
      assert html =~ "Confirm the deposit amount?"
      assert html =~ ~s(data-role="grill-ask")

      # Read-only note shown.
      assert html =~ ~s(data-role="grill-readonly-note")

      # No textarea, no submit button.
      refute html =~ ~s(data-role="grill-answer-input")
      refute html =~ ~s(data-role="grill-submit")
      refute html =~ ~s(<textarea)
      refute html =~ ~s(phx-click="chat.submit")
    end
  end

  # ---- 6. Answered marks collapse to Q→A summary ----------------------

  describe "answered ask-marks" do
    test "answered marks render as a one-line Q→A summary, not an input panel" do
      marks = [
        ask_mark("m1", "Open question still"),
        ask_mark("m2", "Closed question", answer: "Yes, confirmed.")
      ]

      html = render_component(GrillRail, base_assigns(%{grill_marks: marks}))

      # The unanswered one renders as an input panel.
      assert html =~ ~s(id="grill-mark-m1")
      assert html =~ ~s(data-role="grill-answer-input")

      # The answered one renders as a summary, NOT as an input panel.
      assert html =~ ~s(id="grill-mark-m2-answered")
      assert html =~ ~s(data-role="grill-answered")
      assert html =~ "Closed question"
      assert html =~ "Yes, confirmed."
      # Critically: no second textarea for m2.
      assert count_substr(html, ~s(data-role="grill-answer-input")) == 1
    end
  end

  # ---- 7. Empty input list yields a hidden wrapper ---------------------

  # ---- 8. perm_mode/1 unit table ---------------------------------------

  describe "perm_mode/1" do
    test "maps persona perm sets to {:answer | :readonly | :hidden}" do
      assert GrillRail.perm_mode(%Context{
               perms: ~w(read write commit revoke export type_change agent_run)a
             }) == :answer

      assert GrillRail.perm_mode(%Context{
               perms: ~w(read write commit revoke type_change agent_run)a
             }) == :answer

      # agent_supervised has no :type_change → readonly.
      assert GrillRail.perm_mode(%Context{
               perms: ~w(read write commit revoke agent_run)a
             }) == :readonly

      # viewer / nil / empty perms → hidden.
      assert GrillRail.perm_mode(%Context{perms: [:read]}) == :hidden
      assert GrillRail.perm_mode(nil) == :hidden
      assert GrillRail.perm_mode(%Context{perms: []}) == :hidden
    end
  end

  # ---- Helpers --------------------------------------------------------

  defp count_substr(haystack, needle), do: count_substr(haystack, needle, 0)

  defp count_substr(haystack, needle, n) do
    case :binary.match(haystack, needle) do
      :nomatch ->
        n

      {pos, len} ->
        <<_::binary-size(^pos), _::binary-size(^len), rest::binary>> = haystack
        count_substr(rest, needle, n + 1)
    end
  end
end
