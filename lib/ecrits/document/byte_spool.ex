defmodule Ecrits.Document.ByteSpool do
  @moduledoc """
  Decode the byte payload variants carried by document events.

  Browser-exported binaries arrive through the LiveView `:octet` upload lane
  (see `WorkspaceLive.handle_octet_progress/3`) and reach these decoders as a
  plain `"bytes"` binary after the owning LiveView claims the stash entry.
  `bytes_base64` remains supported for LiveView event payloads that inline
  small binaries.
  """

  @spec decode(map()) :: {:ok, binary()} | {:error, term()}
  def decode(%{"bytes_base64" => encoded}) when is_binary(encoded), do: decode_base64(encoded)
  def decode(%{bytes_base64: encoded}) when is_binary(encoded), do: decode_base64(encoded)

  def decode(%{"bytes" => bytes}) when is_binary(bytes), do: {:ok, bytes}
  def decode(%{bytes: bytes}) when is_binary(bytes), do: {:ok, bytes}
  def decode(_params), do: {:error, :missing_bytes}

  defp decode_base64(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64}
    end
  end
end
