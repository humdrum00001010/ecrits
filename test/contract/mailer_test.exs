defmodule Contract.MailerTest do
  use ExUnit.Case, async: true

  import Swoosh.Email
  alias Contract.Mailer

  describe "from/0" do
    test "returns the configured :mail_from tuple" do
      original = Application.get_env(:contract, :mail_from)

      try do
        Application.put_env(:contract, :mail_from, {"Contract", "ereignis@korea.ac.kr"})
        assert {"Contract", "ereignis@korea.ac.kr"} = Mailer.from()
      after
        if original do
          Application.put_env(:contract, :mail_from, original)
        else
          Application.delete_env(:contract, :mail_from)
        end
      end
    end

    test "falls back to a safe default when env is unset" do
      original = Application.get_env(:contract, :mail_from)
      Application.delete_env(:contract, :mail_from)

      try do
        assert {"Contract", "no-reply@example.com"} = Mailer.from()
      after
        if original, do: Application.put_env(:contract, :mail_from, original)
      end
    end
  end

  describe "Swoosh.Adapters.Test (default in test env)" do
    import Swoosh.TestAssertions

    test "deliver/1 captures the email and uses Mailer.from()" do
      Application.put_env(:contract, :mail_from, {"Contract", "ereignis@korea.ac.kr"})

      email =
        new()
        |> to({"User", "user@example.com"})
        |> from(Mailer.from())
        |> subject("Hello")
        |> text_body("Body")

      assert {:ok, _meta} = Mailer.deliver(email)
      assert_email_sent(subject: "Hello")
    end
  end

  describe "smtp_config/1 (prod runtime config)" do
    test "builds the expected SMTP adapter keyword list from env vars" do
      env = %{
        "MAIL_HOST" => "smtp.example.com",
        "MAIL_PORT" => "465",
        "MAIL_USERNAME" => "user@example.com",
        "MAIL_PASSWORD" => "secret"
      }

      cfg = Mailer.smtp_config(env)

      assert cfg[:adapter] == Swoosh.Adapters.SMTP
      assert cfg[:relay] == "smtp.example.com"
      assert cfg[:port] == 465
      assert cfg[:ssl] == true
      assert cfg[:tls] == :never
      assert cfg[:auth] == :always
      assert cfg[:username] == "user@example.com"
      assert cfg[:password] == "secret"
      assert cfg[:retries] == 2
      assert cfg[:no_mx_lookups] == true

      sockopts = cfg[:sockopts]
      assert is_list(sockopts)
      assert sockopts[:versions] == [:"tlsv1.2", :"tlsv1.3"]
      assert sockopts[:verify] == :verify_peer
      assert is_list(sockopts[:cacerts])
      assert sockopts[:depth] == 3
      assert sockopts[:server_name_indication] == ~c"smtp.example.com"

      hostname_check = sockopts[:customize_hostname_check]
      assert is_list(hostname_check)
      assert is_function(hostname_check[:match_fun], 2)
    end

    test "raises KeyError when MAIL_HOST is missing" do
      env = %{
        "MAIL_PORT" => "465",
        "MAIL_USERNAME" => "u",
        "MAIL_PASSWORD" => "p"
      }

      assert_raise KeyError, fn -> Mailer.smtp_config(env) end
    end

    test "raises KeyError when MAIL_PORT is missing" do
      env = %{
        "MAIL_HOST" => "h",
        "MAIL_USERNAME" => "u",
        "MAIL_PASSWORD" => "p"
      }

      assert_raise KeyError, fn -> Mailer.smtp_config(env) end
    end

    test "raises ArgumentError when MAIL_PORT is non-numeric" do
      env = %{
        "MAIL_HOST" => "h",
        "MAIL_PORT" => "not-a-port",
        "MAIL_USERNAME" => "u",
        "MAIL_PASSWORD" => "p"
      }

      assert_raise ArgumentError, fn -> Mailer.smtp_config(env) end
    end
  end

  describe "live SMTP smoke (tagged, opt-in)" do
    @describetag :live_smtp

    test "sends a real message to MAIL_FROM_ADDRESS" do
      addr = System.fetch_env!("MAIL_FROM_ADDRESS")

      email =
        new()
        |> to({"Self", addr})
        |> from(Mailer.from())
        |> subject("Contract Studio :live_smtp smoke")
        |> text_body("If you see this, Worksmobile SMTP works under OTP 28.")

      assert {:ok, _meta} = Mailer.deliver(email)
    end
  end
end
