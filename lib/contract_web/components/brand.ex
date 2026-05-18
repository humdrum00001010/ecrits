defmodule ContractWeb.Brand do
  @moduledoc """
  Brand bits for Contract Studio — wordmark, mark, and the Korean flag glyph
  used in the language switcher. Text-first; we don't ship a pictorial logo
  yet, the wordmark is the brand.

  Used by the landing page, auth chrome, and the post-login navbar.
  """
  use Phoenix.Component

  attr :class, :string, default: nil
  attr :size, :string, default: "base", values: ~w(sm base lg xl)

  @doc """
  Renders the "Contract Studio" wordmark in Inter with a small emerald accent
  dot. Designed to read as type, not graphic — so it composes inside dense
  chrome (navbar, footer) without competing with the page.
  """
  def wordmark(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-baseline gap-1 font-semibold tracking-tight chrome",
      size_class(@size),
      @class
    ]}>
      <span>계약기계</span>
      <span class="text-primary" aria-hidden="true">.</span>
    </span>
    """
  end

  attr :class, :string, default: nil
  attr :size, :string, default: "base", values: ~w(sm base lg xl)

  @doc """
  Just the symbol — a small emerald disc paired with the "CS" monogram.
  Used where the full wordmark is too wide (favicons, mobile navbar, dense
  list rows). Pure CSS; no raster asset.
  """
  def mark(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center justify-center rounded-full bg-primary text-primary-content font-semibold chrome leading-none",
      mark_size(@size),
      @class
    ]}>
      CS
    </span>
    """
  end

  attr :class, :string, default: nil

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

  defp mark_size("sm"), do: "h-5 w-5 text-[0.55rem]"
  defp mark_size("base"), do: "h-7 w-7 text-[0.6rem]"
  defp mark_size("lg"), do: "h-9 w-9 text-xs"
  defp mark_size("xl"), do: "h-12 w-12 text-sm"
end
