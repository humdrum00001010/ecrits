defmodule Mix.Tasks.Contract.Seed.Ftc do
  @moduledoc """
  Enqueue FTC standard-contract template seed jobs.

  Reads `priv/seeds/ftc_templates.exs` and enqueues one
  `Contract.Workers.FtcSeedJob` per entry. The worker is idempotent
  (`check_not_already_seeded/3`), so running this task twice is a
  no-op for already-seeded `type_key`s.

  Live seeding makes real network calls to ftc.go.kr **and** to the
  Upstage Document Parse API. Burn quota deliberately, not in CI.

  ## Usage

      # enqueue + let Oban execute on the :system queue
      mix contract.seed.ftc

      # enqueue and immediately drain the :system queue inline
      mix contract.seed.ftc --drain
  """
  use Mix.Task

  @shortdoc "Enqueue FTC template seed jobs"

  @impl Mix.Task
  def run(_argv) do
    Mix.raise("contract.seed.ftc is retired with the DB/Oban substrate")
  end
end
