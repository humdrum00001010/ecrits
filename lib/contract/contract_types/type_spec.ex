defmodule Contract.ContractTypes.TypeSpec do
  @moduledoc """
  A single entry in the Contract Studio type registry.

  Specs are loaded at compile time from TOML files under
  `priv/contract_types/*.toml`. Each spec describes one canonical contract
  type (e.g. NDA, employment, franchise) along with the fields a drafter
  typically wants captured up front, the publication source (FTC / MTE /
  custom), and a list of sibling type keys it can convert into without
  requiring a content variant.

  See `Contract.ContractTypes` for the loader and the public read API.
  """

  @enforce_keys [:key, :family, :name_en, :version, :source]
  defstruct [
    :key,
    :family,
    :name_en,
    :name_ko,
    :version,
    :source,
    :source_url,
    :template_hwp_path,
    :template_hwpx_path,
    :notes_en,
    :notes_ko,
    recommended_fields: [],
    compatible_with: []
  ]

  @type field_kind :: :text | :number | :date | :party | :money
  @type family ::
          :commercial | :employment | :nda | :services | :realestate | :other
  @type source :: :ftc | :kftc | :mte | :custom

  @type recommended_field :: %{
          id: String.t(),
          label_en: String.t(),
          label_ko: String.t() | nil,
          kind: field_kind()
        }

  @type t :: %__MODULE__{
          key: String.t(),
          family: family(),
          name_en: String.t(),
          name_ko: String.t() | nil,
          version: String.t(),
          source: source(),
          source_url: String.t() | nil,
          template_hwp_path: String.t() | nil,
          template_hwpx_path: String.t() | nil,
          notes_en: String.t() | nil,
          notes_ko: String.t() | nil,
          recommended_fields: [recommended_field()],
          compatible_with: [String.t()]
        }

  @valid_families ~w(commercial employment nda services realestate other)a
  @valid_sources ~w(ftc kftc mte custom)a
  @valid_kinds ~w(text number date party money)a

  @doc """
  Build a `%TypeSpec{}` from a TOML-decoded map (string keys).

  Raises `ArgumentError` on missing required fields, unknown family /
  source / kind, or otherwise malformed input. Errors are raised loudly
  so a bad TOML file fails the compile rather than silently shipping a
  broken type into production.
  """
  @spec from_toml(map(), String.t()) :: t()
  def from_toml(data, source_path \\ "(in-memory)") when is_map(data) do
    %__MODULE__{
      key: fetch!(data, "key", source_path),
      family: parse_family!(fetch!(data, "family", source_path), source_path),
      name_en: fetch!(data, "name_en", source_path),
      name_ko: Map.get(data, "name_ko"),
      version: to_version_string!(fetch!(data, "version", source_path), source_path),
      source: parse_source!(fetch!(data, "source", source_path), source_path),
      source_url: Map.get(data, "source_url"),
      template_hwp_path: Map.get(data, "template_hwp_path"),
      template_hwpx_path: Map.get(data, "template_hwpx_path"),
      notes_en: Map.get(data, "notes_en"),
      notes_ko: Map.get(data, "notes_ko"),
      recommended_fields:
        data
        |> Map.get("recommended_fields", [])
        |> Enum.map(&parse_field!(&1, source_path)),
      compatible_with: Map.get(data, "compatible_with", []) |> List.wrap()
    }
  end

  # ---- internals --------------------------------------------------------

  defp fetch!(data, key, source_path) do
    case Map.fetch(data, key) do
      {:ok, value} when value != nil and value != "" ->
        value

      _ ->
        raise ArgumentError,
              "missing required field #{inspect(key)} in contract type spec (#{source_path})"
    end
  end

  defp parse_family!(value, source_path) do
    atom = String.to_atom(to_string(value))

    if atom in @valid_families do
      atom
    else
      raise ArgumentError,
            "unknown family #{inspect(value)} in #{source_path} — " <>
              "expected one of #{inspect(@valid_families)}"
    end
  end

  defp parse_source!(value, source_path) do
    atom = String.to_atom(to_string(value))

    if atom in @valid_sources do
      atom
    else
      raise ArgumentError,
            "unknown source #{inspect(value)} in #{source_path} — " <>
              "expected one of #{inspect(@valid_sources)}"
    end
  end

  defp parse_field!(field, source_path) when is_map(field) do
    kind_str = field |> Map.get("kind") |> to_string()
    kind = String.to_atom(kind_str)

    unless kind in @valid_kinds do
      raise ArgumentError,
            "unknown field kind #{inspect(kind_str)} in #{source_path} — " <>
              "expected one of #{inspect(@valid_kinds)}"
    end

    %{
      id: fetch!(field, "id", source_path),
      label_en: fetch!(field, "label_en", source_path),
      label_ko: Map.get(field, "label_ko"),
      kind: kind
    }
  end

  defp parse_field!(other, source_path) do
    raise ArgumentError,
          "recommended_fields entry must be a table, got #{inspect(other)} in #{source_path}"
  end

  # Version may parse as a float (e.g. `1.0`) or a string (`"2024.3"`); we
  # always store it as a string so callers don't have to handle both forms.
  defp to_version_string!(value, _source_path) when is_binary(value), do: value
  defp to_version_string!(value, _source_path) when is_number(value), do: to_string(value)

  defp to_version_string!(value, source_path) do
    raise ArgumentError,
          "version must be a string or number in #{source_path}, got #{inspect(value)}"
  end
end
