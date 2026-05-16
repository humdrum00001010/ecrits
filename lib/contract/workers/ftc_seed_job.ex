defmodule Contract.Workers.FtcSeedJob do
  @moduledoc """
  Wave 5 — Korean Fair Trade Commission 표준계약서 (standard contract
  templates) seed-ingest worker.

  Per SPEC.md §23 (Provider Pipeline):

      Upload → SourceSnapshot → Upstage parse → Engine normalizes hard IR → Document

  This worker is the system-job variant of that flow for FTC-published
  template HWP/PDF files. The download URLs are hand-curated in
  `priv/seeds/ftc_templates.exs`; an operator enqueues jobs via
  `mix contract.seed.ftc`.

  ## Pipeline

    1. `ensure_templates_matter/0` — gets or creates the system-owned
       "FTC 표준약관" matter (NOT a user-owned matter).
    2. `check_not_already_seeded/2` — short-circuits with `:ok` if a
       `status: :template` Document with this `type_key` already
       exists in the templates matter. Re-running the seed task is
       therefore idempotent.
    3. `download_source/1` — fetches the source HWP/PDF bytes via Req
       with a Korean `Accept-Language` and a desktop User-Agent (the
       FTC site rejects bare clients otherwise).
    4. `Upstage.parse/2` — runs the bytes through Upstage Document
       Parse and returns the raw elements.
    5. `Upstage.normalize_elements/1` — maps elements to the hard-IR
       node taxonomy (paragraph/heading/list/table/figure/...).
    6. `Contract.Documents.create/2` — inserts the Document row with
       `status: :template`, owned by the templates matter, scoped to
       the system user (synthesized in the seed-system-user
       migration).
    7. `emit_initial_change/2` — runs an `Action(:create_document)`
       through `Contract.Runtime.apply/2` so an audit Change row
       lands. The parsed nodes ride along in the Action payload for
       future Engine-side hydration; currently the projection is
       seeded at load-time via Snapshot replay.

  ## Args

      %{
        "type_key"   => "franchise_v1",
        "source_url" => "https://www.ftc.go.kr/.../franchise.hwp",
        "title"      => "가맹사업 표준계약서"
      }

  ## Failure handling

    * Download errors → retried up to `max_attempts: 5` by Oban.
    * Upstage parse errors → returned, retried.
    * Idempotency: if `check_not_already_seeded/2` finds an existing
      template Document, the job returns `:ok` without downloading
      anything (re-running `mix contract.seed.ftc` is a no-op).

  ## Driver swap (tests)

  The worker reads its Upstage driver from
  `Application.get_env(:contract, :io_drivers)[:upstage]`, falling
  back to `Contract.IO.Upstage`. Tests swap in a stub module via the
  Wave 1A2 driver-indirection pattern.
  """
  use Oban.Worker, queue: :system, max_attempts: 5

  require Logger

  alias Contract.Action
  alias Contract.Context
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.Matters.Matter
  alias Contract.Repo
  alias Contract.Runtime

  @system_user_id "00000000-0000-0000-0000-00000000c0de"
  @system_user_email "system@contract.local"
  @templates_matter_name "FTC 표준약관"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type_key" => type_key, "source_url" => url, "title" => title}}) do
    with {:ok, system_user} <- ensure_system_user(),
         {:ok, templates_matter} <- ensure_templates_matter(system_user.id),
         scope = system_scope(system_user, templates_matter),
         :ok <- check_not_already_seeded(scope, templates_matter, type_key),
         {:ok, file_path, mime_type} <- download_source(url),
         {:ok, parsed} <- upstage_driver().parse(file_path, []),
         projection_nodes <- normalize_to_projection(parsed),
         {:ok, doc} <-
           Documents.create(scope, %{
             "matter_id" => templates_matter.id,
             "title" => title,
             "type_key" => type_key,
             "status" => :template,
             "metadata" => %{
               "source_url" => url,
               "source_mime" => mime_type,
               "node_count" => length(projection_nodes),
               "ingested_at" => DateTime.utc_now() |> DateTime.to_iso8601()
             }
           }),
         {:ok, _change} <- emit_initial_change(doc, projection_nodes, system_user.id) do
      File.rm(file_path)

      Logger.info(
        "FtcSeedJob: seeded template #{inspect(type_key)} doc=#{doc.id} nodes=#{length(projection_nodes)}"
      )

      :ok
    else
      {:ok, :already_seeded} ->
        Logger.info("FtcSeedJob: skipping #{inspect(type_key)} — already seeded")
        :ok

      {:error, reason} = err ->
        Logger.warning("FtcSeedJob: #{inspect(type_key)} failed: #{inspect(reason)}")
        err
    end
  end

  def perform(%Oban.Job{args: args}),
    do: {:error, {:bad_ftc_seed_args, args}}

  # ----------------------------------------------------------------------------
  # ensure_system_user/0
  # ----------------------------------------------------------------------------

  @doc false
  @spec ensure_system_user() :: {:ok, Contract.Accounts.User.t()} | {:error, term()}
  def ensure_system_user do
    case Repo.get(Contract.Accounts.User, @system_user_id) do
      %Contract.Accounts.User{} = user ->
        {:ok, user}

      nil ->
        # Synthesize the row if the migration hasn't run (e.g. fresh test
        # DBs that bypass our `seed_system_user` migration). The id is
        # fixed so subsequent reads find it.
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        %Contract.Accounts.User{
          id: @system_user_id,
          email: @system_user_email,
          confirmed_at: now,
          inserted_at: now,
          updated_at: now
        }
        |> Repo.insert(on_conflict: :nothing, conflict_target: :email)
        |> case do
          {:ok, _user} -> {:ok, Repo.get!(Contract.Accounts.User, @system_user_id)}
          {:error, _} -> {:error, :system_user_unavailable}
        end
    end
  end

  # ----------------------------------------------------------------------------
  # ensure_templates_matter/1
  # ----------------------------------------------------------------------------

  @doc false
  @spec ensure_templates_matter(binary()) :: {:ok, Matter.t()} | {:error, term()}
  def ensure_templates_matter(system_user_id) do
    case Repo.get_by(Matter, name: @templates_matter_name) do
      %Matter{} = matter ->
        {:ok, matter}

      nil ->
        %Matter{}
        |> Matter.changeset(%{
          "name" => @templates_matter_name,
          "owner_id" => system_user_id,
          "tenant_id" => nil,
          "status" => "active",
          "metadata" => %{"system" => true, "source" => "ftc"}
        })
        |> Repo.insert()
    end
  end

  # ----------------------------------------------------------------------------
  # check_not_already_seeded/3
  # ----------------------------------------------------------------------------

  defp check_not_already_seeded(_scope, %Matter{id: matter_id}, type_key) do
    import Ecto.Query

    exists? =
      from(d in Document,
        where:
          d.matter_id == ^matter_id and
            d.type_key == ^type_key and
            d.status == :template,
        limit: 1
      )
      |> Repo.exists?()

    if exists?, do: {:ok, :already_seeded}, else: :ok
  rescue
    DBConnection.ConnectionError -> :ok
    Postgrex.Error -> :ok
  end

  # ----------------------------------------------------------------------------
  # download_source/1
  # ----------------------------------------------------------------------------

  defp download_source(url) when is_binary(url) do
    headers = [
      {"user-agent",
       "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"},
      {"accept-language", "ko-KR,ko;q=0.9,en;q=0.6"},
      {"accept", "application/octet-stream,application/x-hwp,application/pdf,*/*"}
    ]

    case Req.get(url, headers: headers, receive_timeout: 60_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body, headers: resp_headers}} when is_binary(body) ->
        mime = mime_for(resp_headers, url)
        ext = ext_for_mime(mime, url)
        path = Path.join(System.tmp_dir!(), "ftc-seed-#{System.unique_integer([:positive])}.#{ext}")
        File.write!(path, body)
        {:ok, path, mime}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:ftc_http, status, summarize(body)}}

      {:error, reason} ->
        {:error, {:ftc_transport, reason}}
    end
  end

  defp mime_for(headers, url) do
    headers
    |> Enum.find_value(fn
      {"content-type", v} -> v
      {"Content-Type", v} -> v
      _ -> nil
    end)
    |> case do
      nil -> guess_mime(url)
      v when is_binary(v) -> v
      [v | _] -> v
    end
  end

  defp guess_mime(url) do
    cond do
      String.ends_with?(url, ".hwp") -> "application/x-hwp"
      String.ends_with?(url, ".hwpx") -> "application/haansoft-hwpx"
      String.ends_with?(url, ".pdf") -> "application/pdf"
      true -> "application/octet-stream"
    end
  end

  defp ext_for_mime(mime, url) do
    cond do
      String.contains?(mime, "pdf") -> "pdf"
      String.contains?(mime, "hwpx") -> "hwpx"
      String.contains?(mime, "hwp") -> "hwp"
      String.ends_with?(url, ".pdf") -> "pdf"
      String.ends_with?(url, ".hwpx") -> "hwpx"
      String.ends_with?(url, ".hwp") -> "hwp"
      true -> "bin"
    end
  end

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 120)
  defp summarize(other), do: other

  # ----------------------------------------------------------------------------
  # normalize_to_projection/1
  # ----------------------------------------------------------------------------

  defp normalize_to_projection(%{elements: elements}) when is_list(elements) do
    Contract.IO.Upstage.normalize_elements(elements)
  end

  defp normalize_to_projection(_), do: []

  # ----------------------------------------------------------------------------
  # emit_initial_change/3
  # ----------------------------------------------------------------------------

  defp emit_initial_change(%Document{} = doc, nodes, actor_id) do
    node_order =
      nodes
      |> Enum.map(fn n -> Map.get(n, "id") || Map.get(n, :id) end)
      |> Enum.reject(&is_nil/1)

    action = %Action{
      kind: :create_document,
      matter_id: doc.matter_id,
      document_id: doc.id,
      actor_type: :system,
      actor_id: actor_id,
      base_revision: 0,
      idempotency_key: "ftc-seed:#{doc.id}",
      payload: %{
        "title" => doc.title,
        "type_key" => doc.type_key,
        "nodes" => nodes,
        "node_order" => node_order,
        "source" => "ftc"
      },
      message: "FTC template seed"
    }

    case Runtime.apply(nil, action) do
      {:ok, change} -> {:ok, change}
      {:error, _} = err -> err
    end
  end

  # ----------------------------------------------------------------------------
  # system_scope/2
  # ----------------------------------------------------------------------------

  defp system_scope(user, _matter) do
    %Context{
      user: user,
      tenant: nil,
      perms: [:read, :write, :commit, :tenant_admin]
    }
  end

  # ----------------------------------------------------------------------------
  # driver indirection (test seam)
  # ----------------------------------------------------------------------------

  defp upstage_driver do
    Application.get_env(:contract, :io_drivers, [])
    |> Keyword.get(:upstage, Contract.IO.Upstage)
  end

  # ----------------------------------------------------------------------------
  # constants exposed for tests + Mix task
  # ----------------------------------------------------------------------------

  @doc "Stable id of the synthetic system user that owns the templates matter."
  @spec system_user_id() :: binary()
  def system_user_id, do: @system_user_id

  @doc "Display name of the system-owned templates matter."
  @spec templates_matter_name() :: binary()
  def templates_matter_name, do: @templates_matter_name
end
