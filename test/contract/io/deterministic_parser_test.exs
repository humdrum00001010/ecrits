defmodule Contract.IO.DeterministicParserTest do
  use ExUnit.Case, async: true

  alias Contract.IO.DeterministicParser

  test "rejects binary uploads instead of manufacturing placeholder regions" do
    assert {:error, :invalid_text_upload} =
             DeterministicParser.parse(<<0xD0, 0xCF, 0x11, 0xE0>>, filename: "sample.hwp")
  end
end
