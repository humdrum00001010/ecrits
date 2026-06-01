defmodule Contract.ConfigTest do
  use ExUnit.Case, async: false

  alias Contract.Config

  describe "assert_loaded!/1" do
    test ":prod raises on missing required keys; :dev/:test return :ok" do
      key = "OPENAI_API_KEY"
      original = System.get_env(key)
      System.delete_env(key)

      try do
        assert_raise RuntimeError, ~r/missing required environment variables/, fn ->
          Config.assert_loaded!(:prod)
        end

        assert :ok = Config.assert_loaded!(:dev)
        assert :ok = Config.assert_loaded!(:test)
      after
        if original, do: System.put_env(key, original)
      end
    end
  end

  describe "required_keys/1" do
    test ":prod requires SECRET_KEY_BASE + external services; DB URL is retired" do
      prod = Config.required_keys(:prod)
      refute "DATABASE_URL" in prod
      assert "SECRET_KEY_BASE" in prod
      assert "OPENAI_API_KEY" in prod
      refute "R2_BUCKET" in prod

      dev = Config.required_keys(:dev)
      refute "DATABASE_URL" in dev
      refute "SECRET_KEY_BASE" in dev
    end
  end
end
