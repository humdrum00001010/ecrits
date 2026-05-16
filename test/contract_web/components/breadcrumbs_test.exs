defmodule ContractWeb.Components.BreadcrumbsTest do
  use ExUnit.Case, async: true

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

    test "single Dashboard crumb renders as the current page (no link)" do
      trail = [%{label: "Dashboard", navigate: nil, current?: true}]
      html = render_component(&Breadcrumbs.breadcrumbs/1, trail: trail)

      assert html =~ ~s(aria-label="Breadcrumb")
      assert html =~ ~s(aria-current="page")
      assert html =~ "Dashboard"
      refute html =~ ~s(<a href)
      refute html =~ ~s(<a data-phx-link)
    end

    test "studio trail with matter + document renders 3 crumbs, last is current" do
      trail = [
        %{label: "Dashboard", navigate: "/dashboard", current?: false},
        %{label: "Acme Acquisition", navigate: "/matters/m_1", current?: false},
        %{label: "Term Sheet v3", navigate: nil, current?: true}
      ]

      html = render_component(&Breadcrumbs.breadcrumbs/1, trail: trail)

      assert html =~ "Dashboard"
      assert html =~ "Acme Acquisition"
      assert html =~ "Term Sheet v3"
      assert html =~ ~s(href="/dashboard")
      assert html =~ ~s(href="/matters/m_1")
      # The last crumb is plain text, not a link
      assert html =~ ~s(aria-current="page")

      # And it should appear inside a span, not an <a>
      [_, after_aria] = String.split(html, ~s(aria-current="page"), parts: 2)
      refute after_aria =~ ~r/\A[^<]*<a /

      # 3 list items
      assert length(Regex.scan(~r/<li/, html)) == 3
    end

    test "long labels are visually truncated, but the full label is in title=" do
      long_label = String.duplicate("x", 80)
      trail = [%{label: long_label, navigate: nil, current?: true}]
      html = render_component(&Breadcrumbs.breadcrumbs/1, trail: trail)

      # Full label preserved as title=
      assert html =~ ~s(title="#{long_label}")
      # Display is shorter than the input
      refute html =~ ~s(>#{long_label}<)
      # Ellipsis sentinel present (rendered as the &hellip; entity in HEEx)
      assert html =~ "&hellip;" or html =~ "…"
    end

    test "labels at the threshold are NOT truncated" do
      label_40 = String.duplicate("a", 40)
      trail = [%{label: label_40, navigate: nil, current?: true}]
      html = render_component(&Breadcrumbs.breadcrumbs/1, trail: trail)

      # Display contains the full label (rendered around whitespace)
      assert html =~ label_40
      refute html =~ "&hellip;"
      refute html =~ "…"
    end

    test "trail input is not mutated by rendering (truncation is display-only)" do
      long_label = String.duplicate("y", 60)
      trail = [%{label: long_label, navigate: nil, current?: true}]
      _ = render_component(&Breadcrumbs.breadcrumbs/1, trail: trail)

      [crumb] = trail
      assert crumb.label == long_label
      assert String.length(crumb.label) == 60
    end
  end

  describe "build/2 — trail construction" do
    test "returns [] for an unauthenticated scope (nil)" do
      assert Breadcrumbs.build(nil, page: :dashboard) == []
    end

    test "returns [] for a scope without a user" do
      assert Breadcrumbs.build(%{user: nil}, page: :dashboard) == []
    end

    test "dashboard: single current Dashboard crumb" do
      assert Breadcrumbs.build(scope(), page: :dashboard) ==
               [%{label: "Dashboard", navigate: nil, current?: true}]
    end

    test "settings: three crumbs ending with the page label" do
      result = Breadcrumbs.build(scope(), page: :settings, settings_label: "Email & password")

      assert result == [
               %{label: "Dashboard", navigate: "/dashboard", current?: false},
               %{label: "Settings", navigate: "/users/settings", current?: false},
               %{label: "Email & password", navigate: nil, current?: true}
             ]
    end

    test "settings: default page label is 'Account'" do
      result = Breadcrumbs.build(scope(), page: :settings)

      assert List.last(result) == %{label: "Account", navigate: nil, current?: true}
    end

    test "studio with matter, no doc: Dashboard link + matter as current" do
      matter = %{id: "m_42", name: "Acme/NewCo merger"}

      assert Breadcrumbs.build(scope(), page: :studio, matter: matter) ==
               [
                 %{label: "Dashboard", navigate: "/dashboard", current?: false},
                 %{label: "Acme/NewCo merger", navigate: nil, current?: true}
               ]
    end

    test "studio with matter + document: 3 crumbs, doc is current" do
      matter = %{id: "m_42", name: "Acme/NewCo merger"}
      document = %{id: "d_1", title: "Term Sheet v3"}

      assert Breadcrumbs.build(scope(), page: :studio, matter: matter, document: document) ==
               [
                 %{label: "Dashboard", navigate: "/dashboard", current?: false},
                 %{label: "Acme/NewCo merger", navigate: "/workspaces/m_42", current?: false},
                 %{label: "Term Sheet v3", navigate: nil, current?: true}
               ]
    end

    test "studio without a matter falls back to a Studio current crumb" do
      assert Breadcrumbs.build(scope(), page: :studio) ==
               [
                 %{label: "Dashboard", navigate: "/dashboard", current?: false},
                 %{label: "Studio", navigate: nil, current?: true}
               ]
    end

    test "unknown :page returns []" do
      assert Breadcrumbs.build(scope(), page: :mystery) == []
    end
  end
end
