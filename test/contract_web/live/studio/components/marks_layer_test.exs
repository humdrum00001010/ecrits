defmodule ContractWeb.Live.Studio.Components.MarksLayerTest do
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ContractWeb.Live.Studio.Components.MarksLayer

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp mark(id, intent, node_id, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        intent: intent,
        source: :user,
        target_type: :node,
        target_id: node_id,
        text: nil,
        confidence: :medium,
        data: %{}
      },
      overrides
    )
  end

  defp projection(marks_list) do
    marks = Map.new(marks_list, &{&1.id, &1})

    %{
      title: nil,
      type_key: nil,
      metadata: %{},
      nodes: %{},
      node_order: [],
      fields: %{},
      marks: marks,
      refs: %{}
    }
  end

  defp studio_state, do: %Contract.Studio.State{mode: :editing, last_seen_revision: 0}

  defp assigns(overrides) do
    Map.merge(
      %{
        id: "marks-layer",
        projection: projection([]),
        studio_state: studio_state(),
        viewport: :desktop
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # 1. Renders pins for each mark intent
  # ---------------------------------------------------------------------------

  describe "render/1 — pins per intent" do
    test "renders one pin per mark for each supported intent" do
      marks = [
        mark("m-ask", :ask, "node-1"),
        mark("m-flag", :flag, "node-2"),
        mark("m-explain", :explain, "node-3"),
        mark("m-label", :label, "node-4"),
        mark("m-link", :link, "node-5")
      ]

      html = render_component(MarksLayer, assigns(%{projection: projection(marks)}))

      # Count of fallback pins matches the mark list size.
      assert pin_count(html) == 5

      # Each intent appears at least once as a data-intent attribute.
      for intent <- ~w(ask flag explain label link) do
        assert html =~ ~s(data-intent="#{intent}")
      end

      # data-marks JSON carries all five marks for the hook to anchor.
      assert html =~ ~s(data-role="marks-layer")
      assert html =~ ~s(data-marks=)
      assert html =~ "m-ask"
      assert html =~ "m-flag"
      assert html =~ "node-1"
      assert html =~ "node-5"
    end

    test "data-marks attribute encodes node_id + intent for the JS hook" do
      marks = [mark("m1", :ask, "n-abc"), mark("m2", :flag, "n-xyz")]
      html = render_component(MarksLayer, assigns(%{projection: projection(marks)}))

      payload =
        html
        |> extract_data_marks!()
        |> Jason.decode!()

      assert length(payload) == 2

      ids = Enum.map(payload, & &1["node_id"]) |> Enum.sort()
      assert ids == ["n-abc", "n-xyz"]

      intents = Enum.map(payload, & &1["intent"]) |> Enum.sort()
      assert intents == ["ask", "flag"]
    end

    test "marks with non-:node target_type are skipped" do
      marks = [
        mark("m-node", :ask, "node-1"),
        # A field-targeted mark — NOT shown by the canvas layer.
        mark("m-field", :flag, "node-1", %{target_type: :field, target_id: "field-x"})
      ]

      html = render_component(MarksLayer, assigns(%{projection: projection(marks)}))

      assert pin_count(html) == 1
      assert html =~ "m-node"
      refute html =~ "m-field"
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Pin click emits set_node_focus
  # ---------------------------------------------------------------------------

  describe "pin click → set_node_focus event" do
    test "each fallback pin carries phx-click=set_node_focus + the right node_id" do
      marks = [mark("m1", :ask, "node-42")]
      html = render_component(MarksLayer, assigns(%{projection: projection(marks)}))

      # The fallback pin button wires set_node_focus through phx-click.
      assert html =~ ~s(phx-click="set_node_focus")
      assert html =~ ~s(phx-value-node_id="node-42")
      assert html =~ ~s(phx-value-mark_id="m1")
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Hidden on mobile viewport
  # ---------------------------------------------------------------------------

  describe "viewport gating" do
    test "renders an empty hidden div when viewport == :mobile (even with marks)" do
      marks = [mark("m1", :ask, "node-1"), mark("m2", :flag, "node-2")]

      html =
        render_component(MarksLayer, assigns(%{projection: projection(marks), viewport: :mobile}))

      assert html =~ ~s(data-role="marks-layer-mobile-hidden")
      # No pins, no marks payload, no JS hook attribute.
      refute html =~ ~s(data-role="marks-pin-fallback")
      refute html =~ ~s(data-role="marks-layer")
      refute html =~ "data-marks"
      refute html =~ "phx-hook"
    end

    test "renders the full layer when viewport == :desktop" do
      marks = [mark("m1", :ask, "node-1")]
      html = render_component(MarksLayer, assigns(%{projection: projection(marks)}))

      assert html =~ ~s(data-role="marks-layer")
      # Phoenix colocates the hook name as Module.Suffix; assert the
      # suffix appears (LV 1.1 namespaces by module).
      assert html =~ "phx-hook="
      assert html =~ "MarksLayer"
      refute html =~ ~s(data-role="marks-layer-mobile-hidden")
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Empty marks → empty render
  # ---------------------------------------------------------------------------

  describe "empty marks" do
    test "no marks (or missing :marks key) → empty layer container" do
      html = render_component(MarksLayer, assigns(%{projection: projection([])}))
      assert html =~ ~s(data-role="marks-layer")
      assert html =~ ~s(data-marks="[]")
      assert pin_count(html) == 0
      assert html =~ ~s(data-role="marks-layer-empty")

      bare = %{nodes: %{}, fields: %{}, refs: %{}}
      html2 = render_component(MarksLayer, assigns(%{projection: bare}))
      assert html2 =~ ~s(data-role="marks-layer")
      assert pin_count(html2) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Mark colors differ by intent
  # ---------------------------------------------------------------------------

  describe "intent palette" do
    test "ask → emerald, flag → amber, explain → dotted slate, label/link → slate" do
      ask_class = MarksLayer.pin_class(:ask)
      flag_class = MarksLayer.pin_class(:flag)
      explain_class = MarksLayer.pin_class(:explain)

      assert ask_class =~ "emerald"
      refute ask_class =~ "amber"
      assert flag_class =~ "amber"
      refute flag_class =~ "emerald"
      assert explain_class =~ "dotted"

      for cls <- [MarksLayer.pin_class(:label), MarksLayer.pin_class(:link)] do
        assert cls =~ "slate"
        refute cls =~ "emerald"
        refute cls =~ "amber"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 6. mark_list/1 helper contract (used by the hook payload)
  # ---------------------------------------------------------------------------

  describe "mark_list/1 helper" do
    test "stable sort by mark_id, atom intents stringified, non-node marks filtered" do
      proj =
        projection([
          mark("zzz", :flag, "n-1"),
          mark("aaa", :ask, "n-2"),
          mark("mmm", :explain, "n-3"),
          %{
            id: "skip",
            intent: :ask,
            source: :user,
            target_type: :field,
            target_id: "f-1",
            data: %{}
          }
        ])

      result = MarksLayer.mark_list(proj)
      ids = Enum.map(result, & &1.mark_id)
      assert ids == ["aaa", "mmm", "zzz"]

      assert Enum.all?(result, fn m -> is_binary(m.intent) end)
      refute Enum.any?(result, fn m -> m.mark_id == "skip" end)
    end

    test "returns [] when projection has no marks key" do
      assert MarksLayer.mark_list(%{}) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp pin_count(html) do
    html
    |> String.split(~s(data-role="marks-pin-fallback"))
    |> length()
    |> Kernel.-(1)
  end

  defp extract_data_marks!(html) do
    # data-marks contains JSON-encoded list; Phoenix HEEx escapes quotes
    # to &quot; so we re-decode HTML entities before parsing.
    [_, rest] = String.split(html, ~s(data-marks="), parts: 2)
    [encoded, _] = String.split(rest, ~s("), parts: 2)

    encoded
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end
end
