defmodule ContractWeb.Components.BreadcrumbsTest do
  use ExUnit.Case, async: true

  @moduletag :legacy_saas

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ContractWeb.Components.Breadcrumbs

  # A minimal scope stub. We don't depend on Contract.Context here because
  # `build/2` only pattern-matches on `:user` — keeping the test tight and
  # independent of the auth module.
  defp scope(user \\ %{id: 1, email: "u@example.com"}) do
    %{user: user}
  end

  describe "breadcrumbs/1 rendering" do
    test "empty trail renders nothing" do
      html = render_component(&Breadcrumbs.breadcrumbs/1, trail: [])

      assert html == "" or not (html =~ "<nav")
      refute html =~ "aria-current"
    end

    test "single Storage crumb renders as the current page (no link)" do
      trail = [%{label: "Storage", navigate: nil, current?: true}]
      html = render_component(&Breadcrumbs.breadcrumbs/1, trail: trail)

      assert html =~ ~s(aria-label="Breadcrumb")
      assert html =~ ~s(aria-current="page")
      assert html =~ "Storage"
      refute html =~ ~s(<a href)
      refute html =~ ~s(<a data-phx-link)
    end

    test "studio trail with document section renders 3 crumbs, last is current" do
      trail = [
        %{label: "Storage", navigate: "/storage", current?: false},
        %{label: "Documents", navigate: "/storage", current?: false},
        %{label: "Term Sheet v3", navigate: nil, current?: true}
      ]

      html = render_component(&Breadcrumbs.breadcrumbs/1, trail: trail)

      assert html =~ "Storage"
      assert html =~ "Documents"
      assert html =~ "Term Sheet v3"
      assert html =~ ~s(href="/storage")
      assert html =~ ~s(href="/storage")
      # The last crumb is plain text, not a link
      assert html =~ ~s(aria-current="page")

      # And it should appear inside a span, not an <a>
      [_, after_aria] = String.split(html, ~s(aria-current="page"), parts: 2)
      refute after_aria =~ ~r/\A[^<]*<a /

      # 3 list items
      assert length(Regex.scan(~r/<li/, html)) == 3
    end

    test "long labels truncate visually but preserve full label in title=, threshold label intact" do
      long_label = String.duplicate("x", 80)
      long_trail = [%{label: long_label, navigate: nil, current?: true}]
      long_html = render_component(&Breadcrumbs.breadcrumbs/1, trail: long_trail)

      # Full label preserved as title=; display is shorter; ellipsis sentinel present.
      assert long_html =~ ~s(title="#{long_label}")
      refute long_html =~ ~s(>#{long_label}<)
      assert long_html =~ "&hellip;" or long_html =~ "…"

      # Input map not mutated (truncation is display-only).
      [crumb] = long_trail
      assert crumb.label == long_label

      # Labels at the threshold are NOT truncated.
      label_40 = String.duplicate("a", 40)

      short_html =
        render_component(&Breadcrumbs.breadcrumbs/1,
          trail: [%{label: label_40, navigate: nil, current?: true}]
        )

      assert short_html =~ label_40
      refute short_html =~ "&hellip;"
      refute short_html =~ "…"
    end
  end

  describe "build/2 — trail construction" do
    test "returns [] for unauthenticated / user-less / unknown-page scopes" do
      assert Breadcrumbs.build(nil, page: :storage) == []
      assert Breadcrumbs.build(%{user: nil}, page: :storage) == []
      assert Breadcrumbs.build(scope(), page: :mystery) == []
    end

    test "storage: single current Storage crumb" do
      assert Breadcrumbs.build(scope(), page: :storage) ==
               [%{label: "Storage", navigate: nil, current?: true}]
    end

    test "settings: 3 crumbs with custom page label, default label = 'Account'" do
      custom = Breadcrumbs.build(scope(), page: :settings, settings_label: "Email & password")

      assert custom == [
               %{label: "Storage", navigate: "/storage", current?: false},
               %{label: "Settings", navigate: "/users/settings", current?: false},
               %{label: "Email & password", navigate: nil, current?: true}
             ]

      assert List.last(Breadcrumbs.build(scope(), page: :settings)) ==
               %{label: "Account", navigate: nil, current?: true}
    end

    # Document-pivot (SPEC.md 2026-05-15): Matter is internal context.
    # Studio trail collapses to 2 crumbs — Storage > (Document.title | Studio).
    test "studio: matter is always dropped; trail is Storage > (Document | Studio)" do
      matter = %{id: "m_42", name: "Acme/NewCo merger"}
      document = %{id: "d_1", title: "Term Sheet v3"}

      storage_crumb = %{label: "Storage", navigate: "/storage", current?: false}

      # With matter + document → document name wins.
      assert Breadcrumbs.build(scope(), page: :studio, matter: matter, document: document) ==
               [storage_crumb, %{label: "Term Sheet v3", navigate: nil, current?: true}]

      # With matter only → "Studio" fallback.
      assert Breadcrumbs.build(scope(), page: :studio, matter: matter) ==
               [storage_crumb, %{label: "Studio", navigate: nil, current?: true}]

      # No matter, no document → "Studio" fallback.
      assert Breadcrumbs.build(scope(), page: :studio) ==
               [storage_crumb, %{label: "Studio", navigate: nil, current?: true}]

      # Document only (no matter) → document name.
      assert Breadcrumbs.build(scope(),
               page: :studio,
               document: %{id: "d_1", title: "Untitled draft"}
             ) ==
               [storage_crumb, %{label: "Untitled draft", navigate: nil, current?: true}]
    end
  end
end
