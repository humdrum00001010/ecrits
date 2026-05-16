defmodule Contract.ContractTypes do
  @moduledoc """
  Compile-time registry of contract types known to the Studio.

  The registry is loaded once at compile time by walking every TOML file
  in `priv/contract_types/*.toml`, decoding each one through the
  pure-Elixir `:toml` library, and building a `Contract.ContractTypes.TypeSpec`
  struct. The resulting map is then frozen into a module attribute so all
  reads at runtime are O(1) constant-folded lookups with zero IO.

  ## Recompiling on TOML edits

  Every TOML file is registered as an `@external_resource`, so editing a
  spec under `priv/contract_types/` triggers a recompile of this module
  on the next `mix compile`. There is no in-process reload — production
  type catalogue updates ship via a new release.

  ## Public API

  Matches SPEC.md §18 (scope-aware `ctx` first argument). The two
  arity-2 readers (`list/2`, `get/2`) and the binary helper
  (`compatible?/2`) are the only entry points that callers should depend
  on — the underlying storage is an implementation detail.
  """

  alias Contract.ContractTypes.TypeSpec

  @types_dir Application.app_dir(:contract, "priv/contract_types")

  # Files matched by this wildcard at compile time become external resources;
  # editing any of them invalidates this module's compile cache.
  @toml_paths @types_dir |> Path.join("*.toml") |> Path.wildcard() |> Enum.sort()

  for path <- @toml_paths do
    @external_resource path
  end

  @types (for path <- @toml_paths, into: %{} do
            case Toml.decode_file(path) do
              {:ok, data} ->
                spec = TypeSpec.from_toml(data, path)
                {spec.key, spec}

              {:error, reason} ->
                raise "failed to decode #{path}: #{inspect(reason)}"
            end
          end)

  # If two TOML files declare the same `key`, the map collapses them and we
  # lose one silently. Fail the compile instead.
  @type_count length(@toml_paths)

  if map_size(@types) != @type_count do
    raise "duplicate key detected across #{@type_count} TOML files in #{@types_dir} " <>
            "(loaded #{map_size(@types)} unique keys)"
  end

  @doc """
  Returns the list of all loaded contract type specs.

  ## Options

    * `:family` — keep only specs whose `family` atom matches. Pass a
      single atom or a list of atoms.
    * `:source` — keep only specs whose `source` atom matches. Pass a
      single atom or a list of atoms.

  Results are sorted by `key` for stable rendering. Wrapped in the
  `T.result/1` shape (`{:ok, list}`) per SPEC.md §18.
  """
  @spec list(Contract.Types.ctx(), Contract.Types.opts()) ::
          Contract.Types.result([TypeSpec.t()])
  def list(_ctx \\ nil, opts \\ []) when is_list(opts) do
    families = opts |> Keyword.get(:family) |> normalise()
    sources = opts |> Keyword.get(:source) |> normalise()

    filtered =
      @types
      |> Map.values()
      |> Enum.filter(fn spec ->
        (families == :any or spec.family in families) and
          (sources == :any or spec.source in sources)
      end)
      |> Enum.sort_by(& &1.key)

    {:ok, filtered}
  end

  @doc """
  Fetch a single spec by its string `key`.

  Returns `{:ok, spec}` on a hit or `{:error, :not_found}` on a miss —
  the `T.result/1` shape mandated by SPEC.md §18.
  """
  @spec get(Contract.Types.ctx(), Contract.Types.contract_type_key()) ::
          Contract.Types.result(TypeSpec.t())
  def get(_ctx \\ nil, key) when is_binary(key) do
    case Map.fetch(@types, key) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  True iff each type lists the other in its `compatible_with` set.

  Symmetric by construction: this prevents accidentally exposing a
  one-way conversion path that only one side has audited.
  """
  @spec compatible?(String.t(), String.t()) :: boolean()
  def compatible?(from_key, to_key) when is_binary(from_key) and is_binary(to_key) do
    with {:ok, from} <- Map.fetch(@types, from_key),
         {:ok, to} <- Map.fetch(@types, to_key) do
      to_key in from.compatible_with and from_key in to.compatible_with
    else
      :error -> false
    end
  end

  @doc """
  Return all specs as a plain list. Convenience for tests and tooling
  that don't care about ordering or filtering.
  """
  @spec all() :: [TypeSpec.t()]
  def all, do: Map.values(@types)

  @doc """
  Locale-aware display name for a contract type.

  Reads the current locale from the `ContractWeb.Gettext` process
  dictionary (set by the `ContractWeb.Locale` plug / `on_mount` hook).

    * In the `"ko"` locale, returns `name_ko` (falling back to `name_en`
      if the Korean name is missing or empty).
    * In any other locale, returns `name_en` (falling back to `name_ko`
      if the English name is missing or empty — this should never happen
      for shipped specs, since `name_en` is `@enforce_keys`, but we
      still guard against an empty string).

  Accepts either a `%TypeSpec{}` struct or a string key. For an unknown
  string key, the key itself is returned so callers can render
  "something" rather than an error. This keeps stale `type_key`
  references (e.g. from a deleted TOML spec) from crashing the UI.

  `nil` (per SPEC.md §18 — a document may be untyped on creation,
  awaiting `Action(:set_contract_type)`) renders as a locale-aware
  placeholder: "유형 미지정" in Korean, "Untyped" in English.
  """
  @spec display_name(TypeSpec.t() | String.t() | nil) :: String.t()
  def display_name(nil) do
    case Gettext.get_locale(ContractWeb.Gettext) do
      "ko" -> "유형 미지정"
      _ -> "Untyped"
    end
  end

  def display_name(%TypeSpec{name_ko: ko, name_en: en}) do
    case Gettext.get_locale(ContractWeb.Gettext) do
      "ko" -> pick(ko, en)
      _ -> pick(en, ko)
    end
  end

  def display_name(key) when is_binary(key) do
    case Map.fetch(@types, key) do
      {:ok, spec} -> display_name(spec)
      :error -> key
    end
  end

  defp pick(primary, fallback) do
    cond do
      is_binary(primary) and primary != "" -> primary
      is_binary(fallback) and fallback != "" -> fallback
      true -> ""
    end
  end

  @doc """
  Return the set of TOML paths that were loaded at compile time.

  Primarily for tests that want to assert the registry actually picked
  up every shipped file.
  """
  @spec __toml_paths__() :: [String.t()]
  def __toml_paths__, do: @toml_paths

  # ---- internals --------------------------------------------------------

  defp normalise(nil), do: :any
  defp normalise(value) when is_atom(value), do: [value]
  defp normalise(value) when is_list(value), do: value
end
