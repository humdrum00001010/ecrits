defmodule ContractWeb.Live.Studio.Components.Canvas.BriefingTest do
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Contract.Context
  alias Contract.Runtime.State, as: RuntimeState
  alias Contract.Studio.State, as: StudioState
  alias ContractWeb.Live.Studio.Components.Canvas.Briefing

  # ----------------------------------------------------------------------------
  # Fixtures
  # ----------------------------------------------------------------------------

  defp lawyer_scope do
    %Context{
      user: nil,
      perms: ~w(read write commit revoke export type_change agent_run)a
    }
  end

  defp viewer_scope do
    %Context{
      user: nil,
      perms: ~w(read)a
    }
  end

  defp briefing_state do
    %StudioState{
      selected_document_id: "doc-1",
      mode: :briefing,
      last_seen_revision: 3
    }
  end

  defp projection_with_nodes(nodes_list, opts \\ []) do
    nodes = Map.new(nodes_list, &{&1.id, &1})
    order = Enum.map(nodes_list, & &1.id)
    marks = Keyword.get(opts, :marks, %{})
    title = Keyword.get(opts, :title, "Service Agreement")

    RuntimeState.empty_projection()
    |> Map.merge(%{
      title: title,
      nodes: nodes,
      node_order: order,
      marks: marks
    })
  end

  defp render_briefing(overrides) do
    base =
      [
        id: "canvas",
        studio_state: briefing_state(),
        projection: RuntimeState.empty_projection(),
        current_scope: lawyer_scope()
      ]

    render_component(Briefing, Keyword.merge(base, overrides))
  end

  # ----------------------------------------------------------------------------
  # Tests
  # ----------------------------------------------------------------------------

  describe "render/1 — read-only document body" do
    test "renders header, briefing badge, status note and mono contract-body" do
      proj =
        projection_with_nodes(
          [
            %{
              id: "n1",
              kind: :paragraph,
              content: "Lessee agrees to pay rent on the 1st of each month."
            }
          ],
          title: "Lease Agreement"
        )

      html = render_briefing(projection: proj)

      # Header surfaces matter + document title + briefing badge.
      assert html =~ "Lease Agreement"
      assert html =~ ~s(data-role="briefing-badge")

      # Mono body present and node content rendered read-only.
      assert html =~ "contract-body"
      assert html =~ "aria-readonly=\"true\""
      assert html =~ "Lessee agrees to pay rent on the 1st of each month."

      # Status note (Korean) is shown.
      assert html =~ "에이전트가 질문 중입니다"

      # No edit form / textarea present.
      refute html =~ "<textarea"
      refute html =~ ~s(phx-submit="edit_document")
    end
  end

  describe "render/1 — ask-mark highlighting" do
    test "nodes with Mark{intent: :ask} get the ask-mark highlight class" do
      proj =
        projection_with_nodes(
          [
            %{id: "n1", kind: :paragraph, content: "Plain paragraph without questions."},
            %{
              id: "n2",
              kind: :paragraph,
              content: "Termination fee is undefined — clarify amount."
            }
          ],
          marks: %{
            "m1" => %{
              id: "m1",
              intent: :ask,
              source: :agent,
              target_id: "n2",
              text: "What is the termination fee?"
            }
          }
        )

      html = render_briefing(projection: proj)

      # n2 wrapped in an ask-mark button (lawyer persona has write perm).
      assert html =~ "ask-mark"
      assert html =~ ~s(data-mark-target="n2")
      # The button title surfaces the agent's question for hover preview.
      assert html =~ "What is the termination fee?"

      # n1 is NOT wrapped.
      refute html =~ ~s(data-mark-target="n1")
    end
  end

  describe "render/1 — set_node_focus affordance" do
    test "ask-mark span is a phx-click button targeting set_node_focus with node_id" do
      proj =
        projection_with_nodes(
          [%{id: "node-42", kind: :paragraph, content: "Question target."}],
          marks: %{
            "m1" => %{
              id: "m1",
              intent: :ask,
              source: :agent,
              target_id: "node-42",
              text: "Clarify."
            }
          }
        )

      html = render_briefing(projection: proj)

      # phx-click bubbles to the parent LV (no phx-target — the LV owns
      # the handler in studio_live.ex).
      assert html =~ ~s(phx-click="set_node_focus")
      assert html =~ ~s(phx-value-node_id="node-42")
      refute html =~ ~s(phx-target=)
    end

    test "multiple marks on the same node still produce a single highlight" do
      proj =
        projection_with_nodes(
          [%{id: "n1", kind: :paragraph, content: "Heavily questioned clause."}],
          marks: %{
            "m1" => %{id: "m1", intent: :ask, source: :agent, target_id: "n1", text: "Q1?"},
            "m2" => %{id: "m2", intent: :ask, source: :agent, target_id: "n1", text: "Q2?"}
          }
        )

      html = render_briefing(projection: proj)

      # Exactly one button per node; the questions are concatenated in title.
      count = html |> String.split(~s(data-role="ask-mark")) |> length() |> Kernel.-(1)
      assert count == 1
      assert html =~ "Q1?"
      assert html =~ "Q2?"
    end
  end

  describe "render/1 — viewer persona" do
    test "viewer sees the body but no jump-to-question button" do
      proj =
        projection_with_nodes(
          [
            %{id: "n1", kind: :paragraph, content: "Read-only view, marked clause."}
          ],
          marks: %{
            "m1" => %{
              id: "m1",
              intent: :ask,
              source: :agent,
              target_id: "n1",
              text: "Whose obligation?"
            }
          }
        )

      html = render_briefing(projection: proj, current_scope: viewer_scope())

      # Highlight class is still applied (it's a read-only visual cue).
      assert html =~ "ask-mark"
      # …but it is a span, not a clickable button, so no phx-click is emitted.
      refute html =~ ~s(phx-click="set_node_focus")
      assert html =~ ~s(data-role="ask-mark-readonly")
    end
  end

  describe "render/1 — empty / legacy projection (defensive)" do
    test "empty + legacy :marks-less projection still render without crashing" do
      empty = render_briefing(projection: RuntimeState.empty_projection())
      assert empty =~ ~s(data-component="canvas-briefing")
      assert empty =~ ~s(data-role="briefing-empty")
      assert empty =~ "Untitled document"

      legacy_proj = %{
        title: "Doc",
        nodes: %{"n1" => %{id: "n1", kind: :paragraph, content: "hi"}},
        node_order: ["n1"]
      }

      legacy = render_briefing(projection: legacy_proj)
      assert legacy =~ "hi"
      refute legacy =~ "ask-mark"
    end
  end

  describe "ask_marks_by_node/1 — projection helper" do
    test "groups :ask marks by target_id and drops nil targets" do
      marks = %{
        "m1" => %{id: "m1", intent: :ask, source: :agent, target_id: "n1"},
        "m2" => %{id: "m2", intent: :ask, source: :agent, target_id: "n1"},
        "m3" => %{id: "m3", intent: :ask, source: :agent, target_id: "n2"},
        "m4" => %{id: "m4", intent: :note, source: :agent, target_id: "n3"},
        "m5" => %{id: "m5", intent: :ask, source: :agent, target_id: nil}
      }

      grouped = Briefing.ask_marks_by_node(%{marks: marks})

      assert Map.keys(grouped) |> Enum.sort() == ["n1", "n2"]
      assert length(Map.fetch!(grouped, "n1")) == 2
      assert length(Map.fetch!(grouped, "n2")) == 1
    end

    test "returns empty map for malformed projection" do
      assert Briefing.ask_marks_by_node(%{}) == %{}
      assert Briefing.ask_marks_by_node(nil) == %{}
    end
  end
end
