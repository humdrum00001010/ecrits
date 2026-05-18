defmodule ContractWeb.Live.Studio.Components.Canvas.EditorTest do
  @moduledoc """
  Wave 3C1 — Canvas.Editor component spec. Tests cover:

    1. All node kinds render (paragraph, heading, list, list_item, table fallback).
    2. `:write` perm gates `contenteditable`.
    3. The colocated `.Editable` hook is wired for debounced `edit_document`.
    4. Cmd+Z exposes `change.revoke` via the hook (assertion is on hook
       wiring + `data-can-revoke="true"`).
    5. `:revoke` perm gates Cmd+Z (viewer = no revoke).
    6. Revision-conflict assigns surface a `revision-conflict-toast`.
    7. Korean (Hangul) content survives round-trip cleanly — no jamo
       breakage from rendering.
  """

  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Context
  alias Contract.Studio.State
  alias ContractWeb.Live.Studio.Components.Canvas.Editor

  # --- Persona-perm fixtures (mirror Contract.PersonaFactory) ---------

  defp lawyer_scope(user) do
    %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke export type_change agent_run)a
    }
  end

  defp paralegal_scope(user) do
    %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke type_change agent_run)a
    }
  end

  defp viewer_scope(user),
    do: %Context{Context.for_user(user) | perms: ~w(read)a}

  defp admin_scope(user) do
    %Context{
      Context.for_user(user)
      | perms:
          ~w(read write commit revoke export type_change agent_run tenant_admin matter_admin)a
    }
  end

  # --- Projection fixtures --------------------------------------------

  defp sample_projection() do
    %{
      title: "Sample Contract",
      type_key: :nda,
      metadata: %{},
      nodes: %{
        "h1" => %{id: "h1", kind: :heading, content: "보안 유지 계약서", attrs: %{level: 1}},
        "p1" => %{id: "p1", kind: :paragraph, content: "본 계약은 비밀 정보 보호를 목적으로 한다."},
        "p2" => %{id: "p2", kind: :paragraph, content: "양 당사자는 신의 성실 원칙을 따른다."},
        "l1" => %{id: "l1", kind: :list, children: ["li1", "li2"], attrs: %{ordered: true}},
        "li1" => %{id: "li1", kind: :list_item, content: "정의"},
        "li2" => %{id: "li2", kind: :list_item, content: "비밀 정보의 범위"},
        "t1" => %{
          id: "t1",
          kind: :table,
          attrs: %{rows: [["갑", "을"], ["회사 A", "회사 B"]]}
        }
      },
      node_order: ["h1", "p1", "p2", "l1", "t1"],
      fields: %{},
      marks: %{},
      refs: %{}
    }
  end

  defp empty_state(),
    do: %State{mode: :editing, last_seen_revision: 7, selected_node_id: nil}

  # Reads the colocated `.Editable` hook source directly from the
  # component module. LV 1.1 extracts the script and registers it via
  # `Phoenix.LiveView.ColocatedHook`, so it does NOT appear in the
  # `render_component/2` HTML — we read the source file instead.
  @editor_source File.read!(
                   Path.join([
                     File.cwd!(),
                     "lib/contract_web/live/studio/components/canvas/editor.ex"
                   ])
                 )

  defp editor_hook_source(), do: @editor_source

  defp render(scope, projection, opts \\ []) do
    render_component(
      Editor,
      Keyword.merge(
        [
          id: "canvas-editor",
          studio_state: empty_state(),
          projection: projection,
          current_scope: scope
        ],
        opts
      )
    )
  end

  # --- Tests ----------------------------------------------------------

  describe "render_component/2 — node kinds" do
    setup do
      %{user: user_fixture()}
    end

    test "renders every node kind from the projection (h1, p, ol, li, table)",
         %{user: user} do
      html = render(lawyer_scope(user), sample_projection())

      # heading
      assert html =~ "<h1"
      assert html =~ ~s(id="node-h1")
      assert html =~ "보안 유지 계약서"

      # paragraphs
      assert html =~ ~s(id="node-p1")
      assert html =~ "본 계약은 비밀 정보 보호를 목적으로 한다."
      assert html =~ ~s(id="node-p2")

      # ordered list + items
      assert html =~ "<ol"
      assert html =~ ~s(id="node-l1")
      assert html =~ ~s(id="node-li1")
      assert html =~ ~s(id="node-li2")
      assert html =~ "정의"
      assert html =~ "비밀 정보의 범위"

      # table (read-only fallback)
      assert html =~ ~s(id="node-t1")
      assert html =~ ~s(data-readonly="true")
      assert html =~ "회사 A"
    end

    test "renders an empty-state when node_order is empty", %{user: user} do
      empty = %{
        title: nil,
        type_key: nil,
        metadata: %{},
        nodes: %{},
        node_order: [],
        fields: %{},
        marks: %{},
        refs: %{}
      }

      html = render(lawyer_scope(user), empty)
      assert html =~ "이 문서에는 아직 내용이 없습니다."
    end
  end

  describe "persona-perm gating" do
    setup do
      %{user: user_fixture()}
    end

    test "perm-gating: write → contenteditable + can-write; viewer hides both; paralegal also can-revoke",
         %{user: user} do
      lawyer = render(lawyer_scope(user), sample_projection())
      # Editable nodes carry contenteditable + data-can-write=true.
      assert lawyer =~ ~r/<h1[^>]+contenteditable="true"/
      assert lawyer =~ ~r/<p[^>]+contenteditable="true"/
      assert lawyer =~ ~r/<li[^>]+contenteditable="true"/
      assert lawyer =~ ~s(data-can-write="true")

      viewer = render(viewer_scope(user), sample_projection())
      refute viewer =~ ~s(contenteditable="true")
      assert viewer =~ ~s(data-can-write="false")
      # Marks-anchor DOM ids stay even when read-only.
      assert viewer =~ ~s(id="node-p1")

      paralegal = render(paralegal_scope(user), sample_projection())
      assert paralegal =~ ~s(contenteditable="true")
      assert paralegal =~ ~s(data-can-revoke="true")
    end
  end

  describe "Editable hook wiring (debounce + Cmd shortcuts)" do
    setup do
      %{user: user_fixture()}
    end

    test "Editable hook: debounced commit + Cmd+Z revoke (gated by data-can-revoke) + set_node_focus",
         %{user: user} do
      html = render(lawyer_scope(user), sample_projection())

      # LV 1.1 expands the colocated `.Editable` hook to its FQ name.
      assert html =~ "phx-hook=\"ContractWeb.Live.Studio.Components.Canvas.Editor.Editable\""
      assert html =~ ~s(data-can-write="true")

      # Click → set_node_focus with node_id.
      assert html =~ ~s(phx-click="set_node_focus")
      assert html =~ ~s(phx-value-node_id="p1")
      assert html =~ ~s(phx-value-node_id="h1")

      # Hook source must wire debounced edit_document + Cmd+Z revoke (with the
      # data-can-revoke gate). Admin persona has both write + revoke.
      admin_html = render(admin_scope(user), sample_projection())
      assert admin_html =~ ~s(data-can-revoke="true")

      hook_src = editor_hook_source()
      assert hook_src =~ ~s(pushEvent("edit_document")
      assert hook_src =~ "this.debounceMs = 300"
      assert hook_src =~ "node_id"
      assert hook_src =~ ~s(pushEvent("change.revoke")
      assert hook_src =~ "metaKey || e.ctrlKey"
      assert hook_src =~ ~s(this.el.dataset.canRevoke !== "true")
    end
  end

  describe "revision-conflict surfacing" do
    test "conflict_node_id assign → renders the revert toast for that node" do
      user = user_fixture()
      no_conflict = render(lawyer_scope(user), sample_projection())
      refute no_conflict =~ ~s(data-role="revision-conflict-toast")

      conflict =
        render(lawyer_scope(user), sample_projection(), conflict_node_id: "p1")

      assert conflict =~ ~s(data-role="revision-conflict-toast")
      assert conflict =~ ~s(data-conflict-node-id="p1")
      assert conflict =~ "다른 사용자의 변경이 먼저 적용되었습니다."
    end
  end

  describe "Korean text content" do
    setup do
      %{user: user_fixture()}
    end

    test "renders precomposed Hangul cleanly without jamo decomposition",
         %{user: user} do
      projection = %{
        title: nil,
        type_key: nil,
        metadata: %{},
        nodes: %{
          "p1" => %{
            id: "p1",
            kind: :paragraph,
            content: "갑은 을에게 비밀 정보를 제공한다."
          }
        },
        node_order: ["p1"],
        fields: %{},
        marks: %{},
        refs: %{}
      }

      html = render(lawyer_scope(user), projection)
      assert html =~ "갑은 을에게 비밀 정보를 제공한다."

      # No NFD-decomposed jamo: composed Hangul syllables stay in the
      # Hangul Syllables block (U+AC00–U+D7A3). Spot-check '갑' (U+AC11)
      # is present and the conjoining jamo for the same syllable is NOT.
      assert html =~ "갑"
      # Conjoining initial ㄱ (U+1100) + medial ㅏ (U+1161) + final ㅂ (U+11B8)
      # would replace '갑' if Elixir/HEEx decomposed it. Confirm they do not
      # appear as a standalone sequence.
      refute html =~ <<0x1100::utf8, 0x1161::utf8, 0x11B8::utf8>>
    end
  end
end
