defmodule ContractWeb.FeatureCase do
  @moduledoc """
  ExUnit case template for Wallaby browser tests.

  Starts a Wallaby session for browser tests. The SQL sandbox was removed
  with the DB substrate.

  Tests using this case should set `@moduletag :browser`. The default
  `mix test` run excludes `:browser` (see `test/test_helper.exs`); run
  `mix test --include browser` to drive the suite through Chromium.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      import Contract.PersonaFactory
      import ContractWeb.FeatureCase

      alias Contract.PersonaFactory
      alias Wallaby.Query
    end
  end

  setup _tags do
    {:ok, session} = Wallaby.start_session()

    {:ok, session: session}
  end
end
