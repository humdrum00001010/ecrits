defmodule Ecrits.Document.ByteSpoolTest do
  use ExUnit.Case, async: true

  alias Ecrits.Document.ByteSpool

  test "reserve writes a consumable token file" do
    assert {:ok, token, path} = ByteSpool.reserve()
    bytes = "draft bytes"
    File.write!(path, bytes)

    assert {:ok, ^bytes} = ByteSpool.decode(%{"bytes_token" => token})
    refute File.exists?(path)
  end

  test "rejects paths outside the spool directory" do
    assert {:error, :invalid_bytes_path} =
             ByteSpool.decode(%{"bytes_path" => "/tmp/not-owned.bin"})
  end

  test "keeps legacy base64 decode compatibility" do
    assert {:ok, "abc"} = ByteSpool.decode(%{"bytes_base64" => Base.encode64("abc")})
  end
end
