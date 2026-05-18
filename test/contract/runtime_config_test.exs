defmodule Contract.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)

  describe "dev mailer runtime config" do
    test "keeps Swoosh local mailbox even when SMTP env vars are present" do
      with_env(
        %{
          "APP_BASE_URL" => "https://contract-studio.example.test",
          "MAIL_HOST" => "smtp.example.test",
          "MAIL_PORT" => "465",
          "MAIL_USERNAME" => "smtp-user",
          "MAIL_PASSWORD" => "smtp-password"
        },
        fn ->
          {base_config, _imports} = Config.Reader.read_imports!("config/config.exs", env: :dev)
          runtime_config = Config.Reader.read!(@runtime_config, env: :dev)
          config = Config.Reader.merge(base_config, runtime_config)

          assert config[:contract][Contract.Mailer][:adapter] == Swoosh.Adapters.Local
        end
      )
    end
  end

  defp with_env(vars, fun) do
    original = Map.new(vars, fn {key, _value} -> {key, System.get_env(key)} end)

    try do
      Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)
      fun.()
    after
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
