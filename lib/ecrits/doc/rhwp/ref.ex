defmodule Ecrits.Doc.Rhwp.Ref do
  @moduledoc """
  Opaque element references for the HWP/HWPX backend.

  Refs are encoded as strings so they survive a JSON round-trip through the MCP
  boundary. The agent treats them as opaque; only this module decodes them.

  Grammar (subset of the design's `hwp:s0/p7` form):

      hwp:/                  document root
      hwp:s<sec>             a section
      hwp:s<sec>/p<para>     a paragraph
      hwp:s<sec>/p<para>/c<off>+<len>   a character run inside a paragraph

  The decoded form is a plain map with a `:kind` discriminator, which the
  backend pattern-matches when routing `get`/`set`.
  """

  @type t :: String.t()

  @type decoded ::
          %{kind: :document}
          | %{kind: :section, sec: non_neg_integer()}
          | %{kind: :paragraph, sec: non_neg_integer(), para: non_neg_integer()}
          | %{
              kind: :char,
              sec: non_neg_integer(),
              para: non_neg_integer(),
              off: non_neg_integer(),
              len: non_neg_integer()
            }

  @scheme "hwp:"

  @spec encode(decoded()) :: t()
  def encode(%{kind: :document}), do: @scheme <> "/"
  def encode(%{kind: :section, sec: sec}), do: "#{@scheme}s#{sec}"
  def encode(%{kind: :paragraph, sec: sec, para: para}), do: "#{@scheme}s#{sec}/p#{para}"

  def encode(%{kind: :char, sec: sec, para: para, off: off, len: len}),
    do: "#{@scheme}s#{sec}/p#{para}/c#{off}+#{len}"

  @spec decode(t()) :: {:ok, decoded()} | {:error, term()}
  def decode(@scheme <> rest) when is_binary(rest), do: decode_body(rest)
  def decode(value) when is_binary(value), do: {:error, {:invalid_ref, value}}
  def decode(value), do: {:error, {:invalid_ref, value}}

  @doc "Like `decode/1` but raises on error. Useful inside backend pipelines."
  @spec decode!(t()) :: decoded()
  def decode!(ref) do
    case decode(ref) do
      {:ok, decoded} -> decoded
      {:error, reason} -> raise ArgumentError, "invalid hwp ref: #{inspect(reason)}"
    end
  end

  defp decode_body("/"), do: {:ok, %{kind: :document}}

  defp decode_body(body) do
    case String.split(body, "/") do
      ["s" <> sec] ->
        with {:ok, sec} <- int(sec), do: {:ok, %{kind: :section, sec: sec}}

      ["s" <> sec, "p" <> para] ->
        with {:ok, sec} <- int(sec),
             {:ok, para} <- int(para) do
          {:ok, %{kind: :paragraph, sec: sec, para: para}}
        end

      ["s" <> sec, "p" <> para, "c" <> run] ->
        with {:ok, sec} <- int(sec),
             {:ok, para} <- int(para),
             {:ok, off, len} <- run(run) do
          {:ok, %{kind: :char, sec: sec, para: para, off: off, len: len}}
        end

      _ ->
        {:error, {:invalid_ref, @scheme <> body}}
    end
  end

  defp run(str) do
    case String.split(str, "+") do
      [off, len] ->
        with {:ok, off} <- int(off), {:ok, len} <- int(len), do: {:ok, off, len}

      _ ->
        {:error, {:invalid_run, str}}
    end
  end

  defp int(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:invalid_int, str}}
    end
  end
end
