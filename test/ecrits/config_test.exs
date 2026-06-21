defmodule Ecrits.ConfigTest do
  use ExUnit.Case, async: false

  alias Ecrits.Config

  describe "assert_loaded!/1" do
    test ":prod raises on missing SECRET_KEY_BASE; :dev/:test return :ok without env" do
      key = "SECRET_KEY_BASE"
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
    test ":prod requires only SECRET_KEY_BASE; DB / retired-SaaS keys are gone" do
      prod = Config.required_keys(:prod)
      refute "DATABASE_URL" in prod
      assert "SECRET_KEY_BASE" in prod
      refute "LAW_OC" in prod
      # SaaS provider stack (OpenAI / Upstage / SMTP mailer) and the legacy
      # object store are retired — their env vars are no longer required.
      refute "OPENAI_API_KEY" in prod
      refute "UPSTAGE_API_KEY" in prod
      refute "MAIL_HOST" in prod
      refute "R2_BUCKET" in prod

      dev = Config.required_keys(:dev)
      refute "DATABASE_URL" in dev
      refute "SECRET_KEY_BASE" in dev
      refute "LAW_OC" in dev
    end
  end
end
