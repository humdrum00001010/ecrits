defmodule Mix.Tasks.Contract.Imagegen do
  @moduledoc """
  Generate landing imagery via OpenAI's `gpt-image-1` model.

  Reads the manifest at `priv/imagegen/manifest.exs` — a list of maps with
  `:slug`, `:prompt`, `:size`, `:quality`, and `:output_path` — and POSTs
  each entry to `https://api.openai.com/v1/images/generations`. The
  base64 PNG comes back in `data[0].b64_json`; we decode and write it.

  ## Usage

      mix contract.imagegen                          # generate any missing outputs
      mix contract.imagegen --force                  # regenerate everything
      mix contract.imagegen --manifest path/to.exs   # use a non-default manifest
      mix contract.imagegen --only hero,feature-citation  # only these slugs

  ## Behavior

    * Idempotent. If the output exists with non-zero size and `--force`
      is NOT given, the entry is skipped.
    * Fails LOUDLY on API error — does NOT fall back to placeholders.
    * Total budget guard: stops if the estimated cost would exceed $1.00.

  Auth: reads `OPENAI_API_KEY` from the environment via
  `System.fetch_env!/1`. The Mix task fails immediately if it is missing.

  See `feedback-generated-imagery.md` for the style budget and rationale.
  """

  use Mix.Task

  @shortdoc "Generate landing imagery via OpenAI gpt-image-1 from priv/imagegen/manifest.exs"

  @endpoint "https://api.openai.com/v1/images/generations"
  @manifest_path "priv/imagegen/manifest.exs"
  @model "gpt-image-1"
  @budget_usd 1.00

  # Rough cost table for quality "medium" (per OpenAI's pricing page,
  # Wave 3C0-C era). Used only as a sanity gate against runaway loops.
  @cost_table %{
    {"medium", "1024x1024"} => 0.04,
    {"medium", "1024x1536"} => 0.06,
    {"medium", "1536x1024"} => 0.06,
    {"high", "1024x1024"} => 0.17,
    {"high", "1024x1536"} => 0.25,
    {"high", "1536x1024"} => 0.25,
    {"low", "1024x1024"} => 0.011,
    {"low", "1024x1536"} => 0.016,
    {"low", "1536x1024"} => 0.016
  }

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [force: :boolean, manifest: :string, only: :string],
        aliases: [f: :force]
      )

    force? = Keyword.get(opts, :force, false)
    manifest = Keyword.get(opts, :manifest, @manifest_path)

    only_slugs =
      case Keyword.get(opts, :only) do
        nil -> nil
        "" -> nil
        s -> s |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()
      end

    Application.ensure_all_started(:req)

    api_key =
      case System.fetch_env("OPENAI_API_KEY") do
        {:ok, ""} ->
          Mix.raise("OPENAI_API_KEY is set but empty. Cannot generate imagery.")

        {:ok, key} ->
          key

        :error ->
          Mix.raise(
            "OPENAI_API_KEY is not set. Source your .env or export it, then re-run mix contract.imagegen."
          )
      end

    entries = read_manifest!(manifest)

    entries =
      case only_slugs do
        nil ->
          entries

        slugs ->
          filtered = Enum.filter(entries, fn e -> MapSet.member?(slugs, e.slug) end)
          present = filtered |> Enum.map(& &1.slug) |> MapSet.new()
          missing = MapSet.difference(slugs, present)

          unless MapSet.size(missing) == 0 do
            Mix.raise(
              "[imagegen] --only references unknown slugs: #{Enum.join(MapSet.to_list(missing), ", ")}"
            )
          end

          filtered
      end

    {generated, skipped, total_cost} =
      Enum.reduce(entries, {0, 0, 0.0}, fn entry, {gen, skip, cost} ->
        out = entry.output_path

        cond do
          not force? and exists_nonempty?(out) ->
            Mix.shell().info("[imagegen] skip   #{entry.slug} (#{out} already present)")
            {gen, skip + 1, cost}

          true ->
            est = Map.get(@cost_table, {entry.quality, entry.size}, 0.06)

            if cost + est > @budget_usd do
              Mix.raise(
                "[imagegen] budget guard: generating #{entry.slug} would push estimated " <>
                  "spend past $#{:erlang.float_to_binary(@budget_usd, decimals: 2)}. " <>
                  "Generated #{gen} of #{length(entries)} entries; aborting."
              )
            end

            generate!(entry, api_key)
            {gen + 1, skip, cost + est}
        end
      end)

    Mix.shell().info(
      "[imagegen] done: #{generated} generated, #{skipped} skipped, " <>
        "estimated spend ≈ $#{:erlang.float_to_binary(total_cost, decimals: 2)}."
    )

    :ok
  end

  defp read_manifest!(manifest_path) do
    path = Path.expand(manifest_path, File.cwd!())

    unless File.exists?(path) do
      Mix.raise("Manifest not found at #{path}.")
    end

    {entries, _bindings} = Code.eval_file(path)

    unless is_list(entries) do
      Mix.raise("Manifest at #{path} did not return a list — got #{inspect(entries)}.")
    end

    Enum.each(entries, &validate_entry!/1)
    entries
  end

  defp validate_entry!(%{slug: s, prompt: p, size: sz, quality: q, output_path: o})
       when is_binary(s) and is_binary(p) and is_binary(sz) and is_binary(q) and is_binary(o),
       do: :ok

  defp validate_entry!(other),
    do:
      Mix.raise(
        "Manifest entry missing required keys :slug, :prompt, :size, :quality, :output_path — got #{inspect(other)}"
      )

  defp exists_nonempty?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > 0 -> true
      _ -> false
    end
  end

  defp generate!(entry, api_key) do
    Mix.shell().info("[imagegen] start  #{entry.slug} (#{entry.size}, quality=#{entry.quality})")
    t0 = System.monotonic_time(:millisecond)

    # `moderation: "low"` relaxes gpt-image-1's safety filter for editorial
    # / diagrammatic prompts. Our prompts are austere line-art; the strict
    # default mode false-positives on language like "contract page" or
    # "legal document". Keep this at "low" until prompts are fully sanitized.
    body = %{
      model: @model,
      prompt: entry.prompt,
      size: entry.size,
      quality: entry.quality,
      moderation: "low",
      n: 1
    }

    # Tests inject `:req_options` (e.g. `plug: {Req.Test, :imagegen}`) via
    # `Application.put_env(:contract, :imagegen_req_options, ...)` so the
    # task can be exercised without real OpenAI traffic.
    extra_opts = Application.get_env(:contract, :imagegen_req_options, [])

    req =
      Req.new(
        [
          url: @endpoint,
          headers: [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"}
          ],
          json: body,
          receive_timeout: 120_000,
          connect_options: [timeout: 30_000]
        ] ++ extra_opts
      )

    case Req.post(req) do
      {:ok, %Req.Response{status: 200, body: %{"data" => [%{"b64_json" => b64} | _]}}} ->
        png = Base.decode64!(b64)
        out = entry.output_path
        File.mkdir_p!(Path.dirname(out))
        File.write!(out, png)
        bytes = byte_size(png)
        dt = System.monotonic_time(:millisecond) - t0

        Mix.shell().info("[imagegen] ok     #{entry.slug} → #{out} (#{bytes} bytes, #{dt}ms)")

      {:ok, %Req.Response{status: status, body: body}} ->
        Mix.raise(
          "[imagegen] FAIL #{entry.slug}: HTTP #{status}\n  body: #{inspect(body, limit: :infinity, printable_limit: :infinity)}"
        )

      {:error, exception} ->
        Mix.raise("[imagegen] FAIL #{entry.slug}: transport error #{inspect(exception)}")
    end
  end
end
