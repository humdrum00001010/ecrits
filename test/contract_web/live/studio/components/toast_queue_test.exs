defmodule ContractWeb.Live.Studio.Components.ToastQueueTest do
  # Tests assert against Korean copy (the primary i18n surface for
  # studio). Without a per-test locale pin, Gettext falls back to `:en`
  # and would return the English msgstrs from priv/gettext/en/.../studio.po.
  # async: false because Gettext locale is process-dictionary state and
  # would race the other studio component subagents during parallel runs.
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ContractWeb.Live.Studio.Components.ToastQueue

  setup do
    Gettext.put_locale(ContractWeb.Gettext, "ko")
    on_exit(fn -> Gettext.put_locale(ContractWeb.Gettext, "en") end)
    :ok
  end

  describe "render_component/2 with empty stream/list" do
    test "renders the queue container with no toast rows" do
      html =
        render_component(ToastQueue,
          id: "toast-queue",
          streams: %{toasts: []},
          toasts: []
        )

      assert html =~ ~s(id="toast-queue")
      assert html =~ ~s(data-stub="toast-queue")
      assert html =~ ~s(data-role="toast-queue")
      refute html =~ ~s(data-role="toast")
      refute html =~ ~s(data-role="toast-more")
    end
  end

  describe "level-specific rendering" do
    test ":info / :warning / :error toasts render the right border + icon + level data-attr" do
      cases = [
        {%{level: :info, title: "Hello", body: "An informational note.", id: "t-info-1"},
         [
           "border-l-success",
           "hero-information-circle-mini",
           ~s(data-toast-level="info"),
           "Hello",
           "An informational note."
         ]},
        {%{level: :warning, title: "Heads up", body: nil, id: "t-w-1"},
         ["border-l-warning", "hero-exclamation-triangle-mini", "Heads up"]},
        {%{level: :error, title: "Boom", body: "Stack: …", id: "t-e-1"},
         [
           "border-l-error",
           "hero-exclamation-circle-mini",
           ~s(data-toast-level="error"),
           "Boom",
           "Stack: …"
         ]}
      ]

      for {toast_attrs, expected_substrings} <- cases do
        toast = Map.merge(%{link: nil}, toast_attrs)

        html =
          render_component(ToastQueue,
            id: "tq",
            streams: %{toasts: []},
            toasts: [toast]
          )

        assert html =~ ~s(role="alert")

        for substring <- expected_substrings do
          assert html =~ substring,
                 "expected #{toast_attrs.level} toast HTML to contain #{substring}"
        end
      end

      # :info toast also wires the colocated auto-dismiss hook.
      info_html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: [%{id: "i", level: :info, title: "x", body: nil, link: nil}]
        )

      assert info_html =~ "phx-hook=\""
      assert info_html =~ "ToastQueue.Toast"
    end
  end

  describe "dismiss affordance" do
    test "each toast row carries a dismiss button with phx-click wired to dismiss_toast" do
      toast = %{id: "tid-1", level: :error, title: "Oops", body: nil, link: nil}

      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: [toast]
        )

      assert html =~ ~s(data-role="toast-dismiss")
      # JS.push and JS.hide both encode into the phx-click attribute; we
      # don't pin to the exact JSON shape, just that the operation chain
      # references dismiss_toast and the row id.
      assert html =~ "dismiss_toast"
      assert html =~ "tid-1"
      # Korean aria-label.
      assert html =~ ~s(aria-label="알림 닫기")
    end

    test "handle_event/3 dismiss_toast accepts the toast id without crashing the LC" do
      # LCs don't get their own pid; handle_event runs in the parent
      # LV's process. We can still drive the function directly to assert
      # it returns {:noreply, socket}.
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

      assert {:noreply, _} =
               ToastQueue.handle_event("dismiss_toast", %{"toast_id" => "x"}, socket)
    end
  end

  describe "stacking / collapse" do
    test "6+ toasts collapses to '+ N 더 보기' link by default" do
      toasts =
        for i <- 1..7 do
          %{id: "t-#{i}", level: :info, title: "T#{i}", body: nil, link: nil}
        end

      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: toasts
        )

      # The 5 most-recent are visible; 2 are hidden behind the "+ N 더 보기" link.
      assert html =~ ~s(data-role="toast-more")
      assert html =~ "2개 더 보기"
      # Spot-check that only 5 toast rows render (count unique row ids).
      assert Enum.count(1..5, fn i -> html =~ ~s(data-toast-id="t-#{i}") end) == 5
      refute html =~ ~s(data-toast-id="t-6")
      refute html =~ ~s(data-toast-id="t-7")
    end
  end

  describe "i18n / Hangul rendering" do
    test "Korean toast body renders as composed syllables (no jamo decomposition)" do
      # 안녕하세요 is in pre-composed (NFC) form. The font-stack fix in
      # commit 7fb7483 ensures jamo are NOT exposed in the DOM; we
      # assert here that the exact pre-composed UTF-8 bytes round-trip.
      toast = %{
        id: "ko-1",
        level: :info,
        title: "내보내기 준비 완료",
        body: "안녕하세요 — 다운로드 링크가 생성되었습니다.",
        link: nil
      }

      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: [toast]
        )

      assert html =~ "내보내기 준비 완료"
      assert html =~ "안녕하세요 — 다운로드 링크가 생성되었습니다."
      # No standalone jamo leaked in (a regression check against the
      # font fallback issue from fix/3). Specifically: a jamo ㅇ should
      # not appear isolated in the output.
      refute html =~ <<0xE3, 0x85, 0x87>>
    end

    test "viewport positioning: mobile centers at bottom, desktop pins bottom-right" do
      mobile =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          viewport: :mobile,
          toasts: []
        )

      assert mobile =~ ~s(data-viewport="mobile")
      assert mobile =~ "bottom-20"
      assert mobile =~ "items-center"

      desktop =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: []
        )

      assert desktop =~ ~s(data-viewport="desktop")
      assert desktop =~ "bottom-4"
      assert desktop =~ "right-4"
      assert desktop =~ "items-end"
    end
  end

  describe "link affordance" do
    test "toast with a link map renders a navigate-style anchor with the label" do
      toast = %{
        id: "t-link",
        level: :info,
        title: "Export ready",
        body: nil,
        link: %{label: "Download", navigate: "/exports/abc"}
      }

      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: [toast]
        )

      assert html =~ "Download"
      assert html =~ "/exports/abc"
    end
  end
end
