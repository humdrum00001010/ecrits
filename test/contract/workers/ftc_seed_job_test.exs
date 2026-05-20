defmodule Contract.Workers.FtcSeedJobTest do
  use Contract.DataCase, async: false
  use Oban.Testing, repo: Contract.Repo

  alias Contract.Change
  alias Contract.Documents.Document
  alias Contract.IO.UpstageStub
  alias Contract.Workers.FtcSeedJob

  @ftc_url "http://localhost:0/service.hwp"

  setup do
    UpstageStub.setup()
    UpstageStub.reset()

    bypass = Bypass.open()

    original_drivers = Application.get_env(:contract, :io_drivers, [])

    Application.put_env(
      :contract,
      :io_drivers,
      Keyword.put(original_drivers, :upstage, UpstageStub)
    )

    on_exit(fn ->
      Application.put_env(:contract, :io_drivers, original_drivers)
    end)

    {:ok, bypass: bypass}
  end

  defp url_for(bypass, path \\ "/service.hwp") do
    "http://localhost:#{bypass.port}#{path}"
  end

  defp stub_ftc_download(bypass, body \\ "HWPBYTES") do
    Bypass.expect(bypass, "GET", "/service.hwp", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/x-hwp")
      |> Plug.Conn.resp(200, body)
    end)
  end

  defp stub_upstage_response do
    UpstageStub.set_response(%{
      elements: [
        %{"id" => 0, "category" => "heading1", "content" => %{"text" => "용역위탁 표준계약서"}},
        %{"id" => 1, "category" => "paragraph", "content" => %{"text" => "제1조 본 계약은 ..."}},
        %{"id" => 2, "category" => "paragraph", "content" => %{"text" => "제2조 원사업자는 ..."}}
      ],
      content: %{},
      raw: %{}
    })
  end

  defp job_args(bypass) do
    %{
      "type_key" => "service_agreement_v1",
      "source_url" => url_for(bypass),
      "title" => "용역위탁 표준계약서"
    }
  end

  describe "perform/1 — happy path" do
    test "creates the system user + template Document + Change", %{
      bypass: bypass
    } do
      stub_ftc_download(bypass)
      stub_upstage_response()

      assert :ok = perform_job(FtcSeedJob, job_args(bypass))

      # System user landed.
      assert %Contract.Accounts.User{email: "system@contract.local"} =
               Repo.get(Contract.Accounts.User, FtcSeedJob.system_user_id())

      # Document landed under the system owner with parsed metadata.
      [doc] =
        Repo.all(
          from d in Document,
            where:
              d.owner_id == ^FtcSeedJob.system_user_id() and
                d.type_key == "service_agreement_v1"
        )

      assert doc.status == :draft
      assert doc.title == "용역위탁 표준계약서"
      assert doc.metadata["source_url"] == url_for(bypass)
      assert doc.metadata["node_count"] == 3
      assert is_binary(doc.metadata["ingested_at"])

      # Change with action_kind :create_document was emitted.
      changes =
        Repo.all(from c in Change, where: c.document_id == ^doc.id)

      assert [%Change{command_kind: action_kind, actor_type: :system} = change] = changes
      assert action_kind in [:create_document, "create_document"]
      assert change.idempotency_key == "ftc-seed:#{doc.id}"
    end

    test "passes the FTC URL + Korean Accept-Language header on the way out", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/franchise.hwp", fn conn ->
        [ua] = Plug.Conn.get_req_header(conn, "user-agent")
        [accept_lang] = Plug.Conn.get_req_header(conn, "accept-language")
        assert ua =~ "Mozilla"
        assert accept_lang =~ "ko"

        conn
        |> Plug.Conn.put_resp_content_type("application/x-hwp")
        |> Plug.Conn.resp(200, "HWPBYTES")
      end)

      stub_upstage_response()
      assert :ok = perform_job(FtcSeedJob, job_args(bypass))
    end
  end

  describe "perform/1 — idempotency" do
    test "running twice does not duplicate the Document and skips the Upstage call",
         %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/service.hwp", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-hwp")
        |> Plug.Conn.resp(200, "HWPBYTES")
      end)

      stub_upstage_response()
      assert :ok = perform_job(FtcSeedJob, job_args(bypass))

      # Second run: fresh UpstageStub state to verify it is NOT touched.
      UpstageStub.reset()
      stub_upstage_response()
      assert :ok = perform_job(FtcSeedJob, job_args(bypass))

      # Idempotency: single Document row, second run skipped the Upstage driver.
      assert 1 =
               Repo.aggregate(
                 from(d in Document,
                   where:
                     d.owner_id == ^FtcSeedJob.system_user_id() and
                       d.type_key == "service_agreement_v1"
                 ),
                 :count,
                 :id
               )

      assert UpstageStub.calls() == []
    end
  end

  describe "perform/1 — failure paths" do
    test "returns an error tuple when the FTC download 5xxs", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/franchise.hwp", fn conn ->
        Plug.Conn.resp(conn, 503, "service unavailable")
      end)

      assert {:error, {:ftc_http, 503, _}} = perform_job(FtcSeedJob, job_args(bypass))
    end

    test "returns an error tuple when Upstage parse fails", %{bypass: bypass} do
      stub_ftc_download(bypass)
      UpstageStub.fail_next(:upstage_quota_exceeded)

      assert {:error, :upstage_quota_exceeded} = perform_job(FtcSeedJob, job_args(bypass))
    end

    test "bad args produce {:error, {:bad_ftc_seed_args, _}}" do
      assert {:error, {:bad_ftc_seed_args, _}} = perform_job(FtcSeedJob, %{})
    end
  end

  describe "Mix.Tasks.Contract.Seed.Ftc enqueue path" do
    test "manually enqueueing a job via Oban.insert is testable" do
      args = %{
        "type_key" => "service_agreement_v1",
        "source_url" => @ftc_url,
        "title" => "용역위탁 표준계약서"
      }

      assert {:ok, %Oban.Job{} = job} =
               args |> FtcSeedJob.new() |> Oban.insert()

      assert job.worker == "Contract.Workers.FtcSeedJob"
      assert job.queue == "system"
      assert job.args == args
    end
  end
end
