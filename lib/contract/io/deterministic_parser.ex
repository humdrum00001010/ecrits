defmodule Contract.IO.DeterministicParser do
  @moduledoc """
  Deterministic source parser for dev/test-auth browser QA.

  It implements the small `Contract.IO.Upstage.parse/2` driver surface without
  any network calls, deriving predictable regions and source claims from plain
  text uploads. Production-like deployments keep using the configured Upstage
  driver.
  """

  @spec parse(binary() | Path.t(), keyword()) ::
          {:ok, %{elements: list(), content: map(), raw: map()}} | {:error, term()}
  def parse(file_or_bytes, _opts \\ []) do
    with {:ok, text} <- read_text(file_or_bytes) do
      lines = text |> String.split(~r/\R/, trim: true)

      elements =
        lines
        |> Enum.with_index()
        |> Enum.map(fn {line, index} ->
          %{
            "id" => "det-region-#{index + 1}",
            "category" => "paragraph",
            "page" => 1,
            "coordinates" => [],
            "content" => %{"text" => line}
          }
        end)

      claims =
        lines
        |> Enum.with_index()
        |> Enum.flat_map(fn {line, index} -> claims_for_line(line, index + 1) end)

      {:ok, %{elements: elements, content: %{"text" => text}, raw: %{"claims" => claims}}}
    end
  end

  def normalize_elements(list), do: Contract.IO.Upstage.normalize_elements(list)

  defp read_text(path) when is_binary(path) do
    body =
      if File.exists?(path) and not String.contains?(path, "\n") do
        File.read!(path)
      else
        path
      end

    if String.valid?(body), do: {:ok, body}, else: {:error, :invalid_text_upload}
  end

  defp claims_for_line(line, index) do
    region_id = "det-region-#{index}"

    [
      claim_from_label(line, region_id, ~r/^\s*effective\s+date\s*:\s*(.+)$/i, "effective_date"),
      claim_from_label(line, region_id, ~r/^\s*party\s+a\s*:\s*(.+)$/i, "party_a"),
      claim_from_label(line, region_id, ~r/^\s*party\s+b\s*:\s*(.+)$/i, "party_b")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp claim_from_label(line, region_id, regex, kind) do
    case Regex.run(regex, line, capture: :all_but_first) do
      [value] ->
        value = String.trim(value)

        %{
          "region_id" => region_id,
          "kind" => kind,
          "value" => value,
          "confidence" => 1.0,
          "anchors" => [%{"page" => 1, "text" => line}],
          "rationale" => "Deterministic parser matched #{kind}."
        }

      _ ->
        nil
    end
  end
end
