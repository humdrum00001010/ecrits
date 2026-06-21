defmodule EcritsWeb.Brand do
  @moduledoc """
  Brand bits for Ecrits — wordmark, mark, and the Korean flag glyph
  used in the language switcher.

  Used by the landing page, auth chrome, and the post-login navbar.
  """
  use Phoenix.Component

  attr :class, :any, default: nil
  attr :size, :string, default: "base", values: ~w(sm base lg xl)

  @doc """
  Renders the "Ecrits" wordmark in Inter. Text-only, no accent dot or
  glyph — owner directive 2026-05-18 "no icon here". Designed to read
  as type, not graphic — so it composes inside dense chrome (navbar,
  footer) without competing with the page.
  """
  def wordmark(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-baseline font-semibold tracking-tight chrome",
      size_class(@size),
      @class
    ]}>
      <span>Ecrits</span>
    </span>
    """
  end

  attr :class, :any, default: nil
  attr :size, :string, default: "base", values: ~w(sm base lg xl)

  @doc """
  Inline symbol used in dense chrome. It paints with `currentColor`, so it
  follows the surrounding nav color without relying on external SVG image color
  handling.
  """
  def mark(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden="true"
      class={[
        "block shrink-0 text-current",
        mark_size(@size),
        @class
      ]}
    >
      <rect
        x="4"
        y="4"
        width="16"
        height="16"
        rx="4"
        stroke="currentColor"
        stroke-width="1.8"
      />
      <path
        d="M8 9.5h8M8 14.5h8M12 4v16"
        stroke="currentColor"
        stroke-width="1.8"
        stroke-linecap="round"
      />
    </svg>
    """
  end

  attr :class, :any, default: nil

  @doc """
  Inline SVG taegukgi — used by the language switcher to indicate the Korean
  locale. Drawn as a 3:2 rectangle; small enough for inline use next to the
  "한국어" label, accessible via `role="img"`.
  """
  def flag(assigns) do
    ~H"""
    <svg
      viewBox="0 0 60 40"
      class={["inline-block", @class]}
      role="img"
      aria-label="Korean flag"
      xmlns="http://www.w3.org/2000/svg"
    >
      <rect width="60" height="40" fill="#fff" />
      <g transform="translate(30 20) rotate(-33.69)">
        <path d="M -8 0 a 8 8 0 0 1 16 0 a 4 4 0 0 1 -8 0 a 4 4 0 0 0 -8 0 z" fill="#cd2e3a" />
        <path d="M -8 0 a 4 4 0 0 1 8 0 a 4 4 0 0 0 8 0 a 8 8 0 0 1 -16 0 z" fill="#0047a0" />
      </g>
      <g
        fill="#000"
        transform="translate(30 20)"
        stroke-linecap="butt"
      >
        <!-- Geon (top-left) -->
        <g transform="rotate(-56.31) translate(15 0)">
          <rect x="-5" y="-1" width="10" height="2" />
          <rect x="-5" y="-4" width="10" height="2" />
          <rect x="-5" y="-7" width="10" height="2" />
          <rect x="-5" y="2" width="10" height="2" />
          <rect x="-5" y="5" width="10" height="2" />
        </g>
        <!-- Gam (top-right) -->
        <g transform="rotate(-123.69) translate(15 0)">
          <rect x="-5" y="-7" width="10" height="2" />
          <rect x="-5" y="-4" width="4" height="2" />
          <rect x="1" y="-4" width="4" height="2" />
          <rect x="-5" y="-1" width="10" height="2" />
          <rect x="-5" y="2" width="4" height="2" />
          <rect x="1" y="2" width="4" height="2" />
          <rect x="-5" y="5" width="10" height="2" />
        </g>
        <!-- Ri (bottom-left) -->
        <g transform="rotate(56.31) translate(15 0)">
          <rect x="-5" y="-7" width="10" height="2" />
          <rect x="-5" y="-4" width="4" height="2" />
          <rect x="1" y="-4" width="4" height="2" />
          <rect x="-5" y="-1" width="10" height="2" />
          <rect x="-5" y="2" width="10" height="2" />
          <rect x="-5" y="5" width="10" height="2" />
        </g>
        <!-- Gon (bottom-right) -->
        <g transform="rotate(123.69) translate(15 0)">
          <rect x="-5" y="-7" width="4" height="2" />
          <rect x="1" y="-7" width="4" height="2" />
          <rect x="-5" y="-4" width="4" height="2" />
          <rect x="1" y="-4" width="4" height="2" />
          <rect x="-5" y="-1" width="4" height="2" />
          <rect x="1" y="-1" width="4" height="2" />
          <rect x="-5" y="2" width="4" height="2" />
          <rect x="1" y="2" width="4" height="2" />
          <rect x="-5" y="5" width="4" height="2" />
          <rect x="1" y="5" width="4" height="2" />
        </g>
      </g>
    </svg>
    """
  end

  defp size_class("sm"), do: "text-sm"
  defp size_class("base"), do: "text-base"
  defp size_class("lg"), do: "text-lg"
  defp size_class("xl"), do: "text-xl"

  defp mark_size("sm"), do: "h-5 w-5"
  defp mark_size("base"), do: "h-[22px] w-[22px]"
  defp mark_size("lg"), do: "h-9 w-9"
  defp mark_size("xl"), do: "h-12 w-12"
end
