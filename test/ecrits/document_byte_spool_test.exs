defmodule Ecrits.Document.ByteSpoolTest do
  use ExUnit.Case, async: true

  alias Ecrits.Document.ByteSpool

  test "decodes claimed octet binaries passed through as bytes" do
    assert {:ok, "raw binary"} = ByteSpool.decode(%{"bytes" => "raw binary"})
    assert {:ok, "raw binary"} = ByteSpool.decode(%{bytes: "raw binary"})
  end

  test "keeps legacy base64 decode compatibility" do
    assert {:ok, "abc"} = ByteSpool.decode(%{"bytes_base64" => Base.encode64("abc")})
    assert {:error, :invalid_base64} = ByteSpool.decode(%{"bytes_base64" => "%%%"})
  end

  test "reports missing byte payloads" do
    assert {:error, :missing_bytes} = ByteSpool.decode(%{"bytes_token" => "retired-lane"})
    assert {:error, :missing_bytes} = ByteSpool.decode(%{})
  end
end
