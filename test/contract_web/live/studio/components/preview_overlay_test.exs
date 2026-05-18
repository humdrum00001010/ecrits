defmodule ContractWeb.Live.Studio.Components.PreviewOverlayTest do
  @moduledoc """
  Tests for the mobile-only PreviewOverlay LiveComponent (Wave 3C1).

  Component-level tests use `Phoenix.LiveViewTest.render_component/2`.
  Event dispatch is tested at the LV level — for the LV/dispatch funnel
  see `studio_live_test.exs`.
  """

  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Context
  alias Contract.Studio.State
  alias ContractWeb.Live.Studio.Components.PreviewOverlay

  # --- Persona-scope fixtures (mirror Contract.PersonaFactory) ---------------

  defp lawyer_scope(user, _opts \\ []),
    do: %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke export type_change agent_run)a
    }

  defp viewer_scope(user, _opts \\ []),
    do: %Context{
      Context.for_user(user)
      | perms: ~w(read)a
    }

  defp base_state, do: %State{mode: :reviewing, last_seen_revision: 1}

  defp sample_projection do
    %{
      title: "Master Services Agreement",
      type_key: :msa,
      metadata: %{},
      nodes: %{
        "n1" => %{id: "n1", kind: :heading, content: "조항 1. 서비스 범위", attrs: %{level: 2}},
        "n2" => %{id: "n2", kind: :paragraph, content: "당사자는 다음 서비스를 제공한다."},
        "n3" => %{id: "n3", kind: :paragraph, content: "Confidentiality applies."}
      },
      node_order: ["n1", "n2", "n3"],
      fields: %{},
      marks: %{
        "m1" => %{
          id: "m1",
          intent: :risk,
          source: :agent,
          target_id: "n2",
          target_type: :node,
          text: "의무 범위가 모호함"
        },
        "m2" => %{
          id: "m2",
          intent: :assertion,
          source: :user,
          target_id: "n3",
          target_type: :node,
          text: "NDA already on file."
        }
      },
      refs: %{}
    }
  end

  # ---------------------------------------------------------------------------

  describe "render — mobile viewport" do
    setup do
      user = user_fixture()
      %{user: user, scope: lawyer_scope(user)}
    end

    test "renders the overlay shell when mounted (test 1: renders when open)", %{scope: scope} do
      html =
        render_component(PreviewOverlay,
          id: "preview-overlay",
          projection: sample_projection(),
          studio_state: base_state(),
          current_scope: scope,
          viewport: :mobile
        )

      assert html =~ ~s(data-role="preview-overlay")
      assert html =~ ~s(data-viewport="mobile")
      assert html =~ "Master Services Agreement"
      # Close button is present
      assert html =~ ~s(data-role="preview-close")
      # Body tab is selected by default
      assert html =~ ~s(data-role="preview-panel-body")
    end
  end

  describe "render — desktop viewport (hard constraint)" do
    test "test 2: does NOT render the overlay when @viewport == :desktop" do
      user = user_fixture()

      html =
        render_component(PreviewOverlay,
          id: "preview-overlay",
          projection: sample_projection(),
          studio_state: base_state(),
          current_scope: lawyer_scope(user),
          viewport: :desktop
        )

      # The desktop branch returns an inert placeholder, nothing else.
      assert html =~ ~s(data-role="preview-overlay-skipped-desktop")
      refute html =~ ~s(data-role="preview-overlay")
      refute html =~ ~s(data-role="preview-close")
      refute html =~ ~s(data-role="preview-panel-body")
    end
  end

  describe "close affordances" do
    test "test 3: close button fires the `toggle_preview` event at the LV root" do
      user = user_fixture()
      scope = lawyer_scope(user, matter: %{id: "m1", name: "Acme · NDA"})

      html =
        render_component(PreviewOverlay,
          id: "preview-overlay",
          projection: sample_projection(),
          studio_state: base_state(),
          current_scope: scope,
          viewport: :mobile
        )

      # The close button must emit `toggle_preview` to the LV root
      # (NOT phx-target=@myself) so the shell's local handler flips
      # `@preview_modal_open?`.
      assert html =~ ~r/phx-click="toggle_preview"[^>]*data-role="preview-close"/s
      # And the close button must NOT carry a phx-target attr.
      refute html =~ ~r/data-role="preview-close"[^>]*phx-target/s
    end
  end

  describe "tabs" do
    setup do
      user = user_fixture()
      %{user: user, scope: lawyer_scope(user, matter: %{id: "m1", name: "Acme"})}
    end

    test "test 4: tab buttons are present for non-viewers, default to body", %{scope: scope} do
      html =
        render_component(PreviewOverlay,
          id: "preview-overlay",
          projection: sample_projection(),
          studio_state: base_state(),
          current_scope: scope,
          viewport: :mobile
        )

      assert html =~ ~s(data-role="preview-tab-body")
      assert html =~ ~s(data-role="preview-tab-marks")
      assert html =~ ~s(data-role="preview-tab-changes")

      # body tab is the active one (aria-selected="true")
      assert html =~
               ~r/data-role="preview-tab-body"[^>]*aria-selected="true"|aria-selected="true"[^>]*data-role="preview-tab-body"/s

      # marks tab is inactive
      assert html =~
               ~r/aria-selected="false"[^>]*data-role="preview-tab-marks"|data-role="preview-tab-marks"[^>]*aria-selected="false"/s
    end

    test "initial_tab can be passed to render with :marks already active", %{scope: scope} do
      html =
        render_component(PreviewOverlay,
          id: "preview-overlay",
          projection: sample_projection(),
          studio_state: base_state(),
          current_scope: scope,
          viewport: :mobile,
          initial_tab: :marks
        )

      assert html =~ ~s(data-role="preview-panel-marks")
      refute html =~ ~s(data-role="preview-panel-body")
    end
  end

  describe "persona perms" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "viewer sees ONLY the Body tab — Marks and Changes are hidden", %{user: user} do
      scope = viewer_scope(user, matter: %{id: "m1", name: "Acme"})

      html =
        render_component(PreviewOverlay,
          id: "preview-overlay",
          projection: sample_projection(),
          studio_state: base_state(),
          current_scope: scope,
          viewport: :mobile
        )

      assert html =~ ~s(data-role="preview-tab-body")
      refute html =~ ~s(data-role="preview-tab-marks")
      refute html =~ ~s(data-role="preview-tab-changes")
    end
  end

  describe "body tab — projection rendering" do
    test "test 5a: renders Korean content in the body without jamo decomposition" do
      user = user_fixture()
      scope = lawyer_scope(user)
      projection = Map.put(sample_projection(), :title, "한국 계약")

      html =
        render_component(PreviewOverlay,
          id: "preview-overlay",
          projection: projection,
          studio_state: base_state(),
          current_scope: scope,
          viewport: :mobile
        )

      # NFC Korean content should round-trip intact (no jamo splitting).
      assert html =~ "조항 1. 서비스 범위"
      assert html =~ "당사자는 다음 서비스를 제공한다."
      # Document title with Korean characters renders in the header.
      assert html =~ "한국 계약"
      # Sanity: assert the syllable-level codepoint is present, not the
      # NFD-decomposed jamo sequence. "조" is U+C870.
      assert String.contains?(html, "조")
      # Decomposed jamo for "조" would be ㅈ (U+110C) + ㅗ (U+1169);
      # these MUST NOT appear in place of the syllable.
      refute html =~ <<0x110C::utf8, 0x1169::utf8>>
    end

    test "test 5b: empty projection shows the no-document hint" do
      user = user_fixture()
      scope = lawyer_scope(user)

      empty = Contract.Runtime.State.empty_projection()

      html =
        render_component(PreviewOverlay,
          id: "preview-overlay",
          projection: empty,
          studio_state: %State{mode: :no_document},
          current_scope: scope,
          viewport: :mobile
        )

      assert html =~ "No document selected." or html =~ "선택된 문서가 없습니다."
    end
  end

  describe "marks tab" do
    setup do
      user = user_fixture()
      %{user: user, scope: lawyer_scope(user, matter: %{id: "m1", name: "Acme"})}
    end

    test "groups marks by target_id and renders jump buttons for non-viewers", %{scope: scope} do
      html =
        render_component(PreviewOverlay,
          id: "preview-overlay",
          projection: sample_projection(),
          studio_state: base_state(),
          current_scope: scope,
          viewport: :mobile,
          initial_tab: :marks
        )

      # The mark texts render
      assert html =~ "의무 범위가 모호함"
      assert html =~ "NDA already on file."
      # Jump buttons emit `set_node_focus` with the target node id
      assert html =~ ~s(phx-click="set_node_focus")
      assert html =~ ~s(phx-value-node_id="n2")
      assert html =~ ~s(phx-value-node_id="n3")
    end
  end

  describe "i18n — studio domain" do
    test "Korean locale renders translated chrome strings" do
      user = user_fixture()
      scope = lawyer_scope(user, matter: %{id: "m1", name: "Acme"})

      original = Gettext.get_locale(ContractWeb.Gettext)
      Gettext.put_locale(ContractWeb.Gettext, "ko")

      try do
        html =
          render_component(PreviewOverlay,
            id: "preview-overlay",
            projection: sample_projection(),
            studio_state: base_state(),
            current_scope: scope,
            viewport: :mobile
          )

        # Korean tab labels
        assert html =~ "본문"
        assert html =~ "주석"
        assert html =~ "변경 사항"
        # Korean aria-label
        assert html =~ "문서 미리보기"
      after
        Gettext.put_locale(ContractWeb.Gettext, original)
      end
    end
  end
end
