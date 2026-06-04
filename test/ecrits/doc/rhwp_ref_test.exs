defmodule Ecrits.Doc.Rhwp.RefTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.Rhwp.Ref

  describe "encode/decode round-trips" do
    test "paragraph ref" do
      ref = %{kind: :paragraph, sec: 0, para: 7}
      encoded = Ref.encode(ref)
      assert encoded == "hwp:s0/p7"
      assert {:ok, ^ref} = Ref.decode(encoded)
    end

    test "char run ref" do
      ref = %{kind: :char, sec: 0, para: 7, off: 6, len: 14}
      encoded = Ref.encode(ref)
      assert encoded == "hwp:s0/p7/c6+14"
      assert {:ok, ^ref} = Ref.decode(encoded)
    end

    test "document root ref" do
      ref = %{kind: :document}
      assert Ref.encode(ref) == "hwp:/"
      assert {:ok, ^ref} = Ref.decode("hwp:/")
    end

    test "section ref" do
      ref = %{kind: :section, sec: 2}
      assert Ref.encode(ref) == "hwp:s2"
      assert {:ok, ^ref} = Ref.decode("hwp:s2")
    end
  end

  describe "decode/1 errors" do
    test "rejects non-hwp scheme" do
      assert {:error, _} = Ref.decode("office:/DrawPages/0")
    end

    test "rejects malformed ref" do
      assert {:error, _} = Ref.decode("hwp:garbage")
      assert {:error, _} = Ref.decode("not a ref")
      assert {:error, _} = Ref.decode(123)
    end
  end

  test "decode is the inverse of encode for all supported kinds" do
    for ref <- [
          %{kind: :document},
          %{kind: :section, sec: 0},
          %{kind: :paragraph, sec: 1, para: 12},
          %{kind: :char, sec: 0, para: 3, off: 0, len: 5}
        ] do
      assert {:ok, ^ref} = ref |> Ref.encode() |> Ref.decode()
    end
  end
end
