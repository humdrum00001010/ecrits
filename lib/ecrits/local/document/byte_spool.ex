defmodule Ecrits.Local.Document.ByteSpool do
  @moduledoc """
  Short-lived byte handoff for browser-exported local documents.

  Browser editors upload raw bytes to a server-owned tmp file and then send only
  the returned token through LiveView/doc-tool events. The base64 path remains
  supported as a compatibility fallback, but new clients should use tokens so
  large document bytes do not appear in event params or logs.
  """

  @dir_name "ecrits-local-document-bytes"
  @token_bytes 24
  @token_regex ~r/\A[A-Za-z0-9_-]{16,128}\z/

  @spec reserve() :: {:ok, String.t(), String.t()} | {:error, term()}
  def reserve do
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    with :ok <- File.mkdir_p(dir()) do
      {:ok, token, token_path(token)}
    end
  end

  @spec decode(map()) :: {:ok, binary()} | {:error, term()}
  def decode(%{"bytes_token" => token}) when is_binary(token), do: consume_token(token)
  def decode(%{bytes_token: token}) when is_binary(token), do: consume_token(token)
  def decode(%{"bytes_path" => path}) when is_binary(path), do: consume_path(path)
  def decode(%{bytes_path: path}) when is_binary(path), do: consume_path(path)

  def decode(%{"bytes_base64" => encoded}) when is_binary(encoded), do: decode_base64(encoded)
  def decode(%{bytes_base64: encoded}) when is_binary(encoded), do: decode_base64(encoded)

  def decode(%{"bytes" => bytes}) when is_binary(bytes), do: {:ok, bytes}
  def decode(%{bytes: bytes}) when is_binary(bytes), do: {:ok, bytes}
  def decode(_params), do: {:error, :missing_bytes}

  @spec token_path(String.t()) :: String.t()
  def token_path(token), do: Path.join(dir(), token <> ".bin")

  @spec valid_token?(String.t()) :: boolean()
  def valid_token?(token) when is_binary(token), do: Regex.match?(@token_regex, token)
  def valid_token?(_token), do: false

  @spec dir() :: String.t()
  def dir, do: Path.join(System.tmp_dir!(), @dir_name)

  defp consume_token(token) do
    if valid_token?(token) do
      consume_path(token_path(token))
    else
      {:error, :invalid_bytes_token}
    end
  end

  defp consume_path(path) do
    with :ok <- ensure_spool_path(path),
         {:ok, bytes} <- File.read(path) do
      _ = File.rm(path)
      {:ok, bytes}
    end
  end

  defp ensure_spool_path(path) when is_binary(path) do
    root = Path.expand(dir())
    expanded = Path.expand(path)

    if expanded != root and String.starts_with?(expanded, root <> "/") do
      :ok
    else
      {:error, :invalid_bytes_path}
    end
  end

  defp ensure_spool_path(_path), do: {:error, :invalid_bytes_path}

  defp decode_base64(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64}
    end
  end
end
