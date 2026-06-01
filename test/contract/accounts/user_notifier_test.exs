defmodule Contract.Accounts.UserNotifierTest do
  @moduledoc """
  Regression test for the localhost-in-emails bug.

  `Contract.Accounts.UserNotifier` builds emails whose body contains an
  absolute URL produced via `ContractWeb.url(~p"/users/log-in/<token>")`.
  That helper reads `ContractWeb.Endpoint`'s `:url` config — so if `:url`
  defaults to `localhost`, the public sprite recipients get an unreachable
  link.

  This test pins `:url` to the per-sprite hostname (mimicking what
  `runtime.exs` does when `APP_BASE_URL` is set) and asserts the email
  body contains `https://contract-studio-v7zk.sprites.app/...` and NOT
  `localhost`.
  """
  use Contract.DataCase, async: false
  use Oban.Testing, repo: Contract.Repo

  alias Contract.Accounts
  alias Contract.AccountsFixtures
  alias ContractWeb.Endpoint

  @public_host "contract-studio-v7zk.sprites.app"

  setup do
    original = Application.get_env(:contract, Endpoint) || []

    updated =
      Keyword.put(original, :url, host: @public_host, port: 443, scheme: "https")

    Application.put_env(:contract, Endpoint, updated)
    # Phoenix caches `:url` in a `:persistent_term` populated at boot; we must
    # call `config_change/2` so the supervisor re-runs `warmup_persistent/1`
    # and `Endpoint.url/0` returns the new value. The `changed` arg is the
    # standard Application config_change shape: `[{Module, new_config}]`.
    :ok = Endpoint.config_change([{Endpoint, updated}], [])

    on_exit(fn ->
      Application.put_env(:contract, Endpoint, original)
      Endpoint.config_change([{Endpoint, original}], [])
    end)

    :ok
  end

  test "login-instructions email contains the public sprite URL, not localhost" do
    user = AccountsFixtures.unconfirmed_user_fixture()

    # Mimic the call shape from ContractWeb.UserLive.Login / Registration:
    # `&url(~p"/users/log-in/#{&1}")`. `Phoenix.VerifiedRoutes.url/1` ultimately
    # delegates to `Endpoint.url/0`, which reads the `:url` config we just stubbed.
    # As of the async-mailer wave the call enqueues an Oban job instead of
    # delivering inline; drain it synchronously to flush the email into the
    # Swoosh test inbox.
    {:ok, %Oban.Job{}} =
      Accounts.deliver_login_instructions(
        user,
        &(Endpoint.url() <> "/users/log-in/" <> &1)
      )

    assert_enqueued(
      worker: Contract.Workers.MailerJob,
      args: %{"kind" => "login_instructions", "args" => %{"user_id" => user.id}}
    )

    assert %{success: 1} = Oban.drain_queue(queue: :mailer)

    # Pull the email straight from the mailbox so we can inspect both the
    # subject and the body off a single struct. `Swoosh.Adapters.Test`
    # delivers each email as a `{:email, %Swoosh.Email{}}` message to the
    # current process (and its $callers, which covers the inline-drained
    # Oban worker).
    assert_receive {:email, email}, 100

    assert email.subject == "계정 확인 안내 · 계약기계"
    body = email.text_body

    assert body =~ "https://#{@public_host}/users/log-in/",
           "expected the email body to embed the public sprite URL but got:\n#{body}"

    refute body =~ "localhost",
           "email body must not contain localhost — got:\n#{body}"
  end
end
