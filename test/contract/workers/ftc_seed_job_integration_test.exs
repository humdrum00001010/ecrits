defmodule Contract.Workers.FtcSeedJobIntegrationTest do
  @moduledoc """
  Live end-to-end test for `Contract.Workers.FtcSeedJob`. Hits the real
  ftc.go.kr site **and** the real Upstage Document Parse API. Skipped
  by default — set the `LIVE_UPSTAGE=1` env var and pass the
  `--include live_upstage` tag to run it manually:

      LIVE_UPSTAGE=1 mix test --include live_upstage \\
        test/contract/workers/ftc_seed_job_integration_test.exs

  Runs once: don't burn quota in CI.
  """
  use Contract.DataCase, async: false
  use Oban.Testing, repo: Contract.Repo

  @moduletag :live_upstage

  alias Contract.Documents.Document
  alias Contract.Workers.FtcSeedJob

  # The FTC landing page used in `priv/seeds/ftc_templates.exs`. This
  # is the public 표준약관 board; the worker is expected to handle the
  # response even if the page is HTML (Upstage Document Parse accepts
  # HTML / PDF / HWP / images). Operators replace this with the
  # concrete `fileDown.do?...` URL once they have the attachment ids.
  @ftc_landing_url "https://www.ftc.go.kr/www/cop/bbs/selectBoardList.do?bbsId=BBSMSTR_000000002320&key=153"

  test "real-network seed run materializes a :template Document" do
    args = %{
      "type_key" => "service_agreement_v1",
      "source_url" => @ftc_landing_url,
      "title" => "용역위탁 표준계약서 (live)"
    }

    assert :ok = perform_job(FtcSeedJob, args)

    assert [%Document{status: :template}] =
             Repo.all(
               from d in Document,
                 where:
                   d.owner_id == ^FtcSeedJob.system_user_id() and
                     d.type_key == "service_agreement_v1"
             )
  end
end
