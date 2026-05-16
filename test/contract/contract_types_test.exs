defmodule Contract.ContractTypesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Contract.ContractTypes
  alias Contract.ContractTypes.TypeSpec

  describe "list/2" do
    test "returns one spec per shipped TOML file" do
      assert {:ok, specs} = ContractTypes.list()

      assert length(specs) == length(ContractTypes.__toml_paths__())
      assert length(specs) >= 5

      assert Enum.all?(specs, &match?(%TypeSpec{}, &1))
    end

    test "ships the five canonical keys the dashboard depends on" do
      {:ok, specs} = ContractTypes.list()
      keys = specs |> Enum.map(& &1.key) |> MapSet.new()

      for expected <- ~w(nda_v1 franchise_v1 service_agreement_v1 employment_v1 supply_v1) do
        assert expected in keys, "missing canonical type #{expected}"
      end
    end

    test "is sorted by key for stable rendering" do
      {:ok, specs} = ContractTypes.list()
      keys = Enum.map(specs, & &1.key)
      assert keys == Enum.sort(keys)
    end

    test ":family option filters by a single family atom" do
      assert {:ok, employment} = ContractTypes.list(nil, family: :employment)
      assert length(employment) >= 1
      assert Enum.all?(employment, &(&1.family == :employment))
    end

    test ":family option accepts a list of atoms" do
      assert {:ok, pair} = ContractTypes.list(nil, family: [:nda, :employment])

      families =
        pair
        |> Enum.map(& &1.family)
        |> Enum.uniq()
        |> Enum.sort()

      assert families == [:employment, :nda]
    end

    test ":source option filters by source publisher" do
      assert {:ok, ftc} = ContractTypes.list(nil, source: :ftc)
      assert Enum.all?(ftc, &(&1.source == :ftc))
      # We ship at least the FTC franchise spec.
      assert length(ftc) >= 1
    end

    test "unknown family yields an empty list" do
      assert ContractTypes.list(nil, family: :nonexistent_family) == {:ok, []}
    end

    test "accepts a ctx as the first positional argument (SPEC §18 shape)" do
      ctx = %{user_id: "u-123"}
      assert {:ok, specs} = ContractTypes.list(ctx)
      assert is_list(specs)
    end
  end

  describe "get/2" do
    test "returns {:ok, spec} for a known key" do
      assert {:ok, %TypeSpec{} = spec} = ContractTypes.get(nil, "nda_v1")
      assert spec.key == "nda_v1"
      assert spec.family == :nda
    end

    test "returns {:error, :not_found} for an unknown key" do
      assert ContractTypes.get(nil, "definitely_not_a_real_key") == {:error, :not_found}
    end
  end

  describe "compatible?/2" do
    test "is true when both directions list each other (and we ship at least one such pair)" do
      # service_agreement_v1 <-> nda_v1 are seeded as mutually compatible.
      assert ContractTypes.compatible?("service_agreement_v1", "nda_v1")
      assert ContractTypes.compatible?("nda_v1", "service_agreement_v1")
    end

    test "is false for a one-way edge" do
      # employment_v1 has compatible_with = [], so nothing should pair with it.
      refute ContractTypes.compatible?("employment_v1", "nda_v1")
      refute ContractTypes.compatible?("nda_v1", "employment_v1")
    end

    test "is false when either key is unknown" do
      refute ContractTypes.compatible?("nda_v1", "ghost_key")
      refute ContractTypes.compatible?("ghost_key", "nda_v1")
      refute ContractTypes.compatible?("ghost_a", "ghost_b")
    end
  end

  describe "loaded spec invariants" do
    test "every shipped spec has the required fields populated" do
      for spec <- ContractTypes.all() do
        assert is_binary(spec.key) and spec.key != ""
        assert is_atom(spec.family)
        assert is_binary(spec.name_en) and spec.name_en != ""
        assert is_binary(spec.version) and spec.version != ""
        assert is_atom(spec.source)
        assert is_list(spec.recommended_fields)
        assert is_list(spec.compatible_with)
      end
    end

    test "every recommended_field has id/label_en/kind" do
      for spec <- ContractTypes.all(),
          field <- spec.recommended_fields do
        assert is_binary(field.id) and field.id != ""
        assert is_binary(field.label_en) and field.label_en != ""
        assert field.kind in [:text, :number, :date, :party, :money]
      end
    end

    test "field ids are unique within a spec" do
      for spec <- ContractTypes.all() do
        ids = Enum.map(spec.recommended_fields, & &1.id)
        assert ids == Enum.uniq(ids), "duplicate field id in #{spec.key}"
      end
    end

    test "compatible_with only references shipped keys" do
      keys = ContractTypes.all() |> Enum.map(& &1.key) |> MapSet.new()

      for spec <- ContractTypes.all(),
          partner <- spec.compatible_with do
        assert partner in keys,
               "#{spec.key}.compatible_with references unknown key #{partner}"
      end
    end
  end

  describe "compile-time wiring" do
    test "@external_resource lists every shipped TOML path" do
      paths = ContractTypes.__toml_paths__()

      assert length(paths) >= 5
      assert Enum.all?(paths, &String.ends_with?(&1, ".toml"))

      # external_resource attrs are recorded on the module; surface them via
      # Module.get_attribute analogue: read the BEAM attribute list.
      external =
        :attributes
        |> ContractTypes.__info__()
        |> Keyword.get_values(:external_resource)
        |> List.flatten()

      for path <- paths do
        assert path in external,
               "expected #{path} to be registered as an @external_resource"
      end
    end

    test "every shipped TOML decodes successfully (property)" do
      paths = ContractTypes.__toml_paths__()

      check all path <- StreamData.member_of(paths) do
        assert {:ok, data} = Toml.decode_file(path)
        assert is_map(data)
        assert is_binary(data["key"])
        assert is_binary(data["family"])
        assert is_binary(data["name_en"])
      end
    end
  end

  describe "display_name/1 — locale-aware label" do
    # Wave 5: subagent regression — the new-document picker, type-picker
    # modal, and recent-documents table were all rendering `name_en` /
    # raw `type_key` regardless of locale, so Korean lawyers saw
    # "Mutual Non-Disclosure Agreement" / "nda_v1" instead of
    # "상호 비밀유지계약서". `display_name/1` reads the process-level
    # Gettext locale and picks the localized name.

    setup do
      # The locale lives in the process dictionary; capture and restore
      # so we don't bleed state between tests.
      previous = Gettext.get_locale(ContractWeb.Gettext)
      on_exit(fn -> Gettext.put_locale(ContractWeb.Gettext, previous) end)
      :ok
    end

    test "in :ko locale returns name_ko for a TypeSpec" do
      Gettext.put_locale(ContractWeb.Gettext, "ko")
      {:ok, spec} = ContractTypes.get(nil, "nda_v1")
      assert spec.name_ko != nil and spec.name_ko != ""
      assert ContractTypes.display_name(spec) == spec.name_ko
    end

    test "in :en locale returns name_en for a TypeSpec" do
      Gettext.put_locale(ContractWeb.Gettext, "en")
      {:ok, spec} = ContractTypes.get(nil, "nda_v1")
      assert ContractTypes.display_name(spec) == spec.name_en
    end

    test "accepts a string key and returns the localized name" do
      Gettext.put_locale(ContractWeb.Gettext, "ko")
      {:ok, spec} = ContractTypes.get(nil, "franchise_v1")
      assert ContractTypes.display_name("franchise_v1") == spec.name_ko
    end

    test "string-key form falls back to the key itself when unknown" do
      Gettext.put_locale(ContractWeb.Gettext, "ko")
      assert ContractTypes.display_name("nonexistent_v999") == "nonexistent_v999"
    end

    test "falls back to name_en when name_ko is empty in :ko locale" do
      spec = %TypeSpec{
        key: "x",
        family: :nda,
        name_en: "Fallback EN",
        name_ko: "",
        version: "1",
        source: :custom
      }

      Gettext.put_locale(ContractWeb.Gettext, "ko")
      assert ContractTypes.display_name(spec) == "Fallback EN"
    end

    # SPEC.md §18: documents can be created untyped (type_key: nil) and
    # only get a key once the user (Cmd+K) or the agent fills one in
    # via `Action(:set_contract_type)`. The UI must still parse at a
    # glance, so `display_name/1` of nil returns a locale-aware
    # placeholder — "유형 미지정" in :ko, "Untyped" in :en.
    test "display_name(nil) returns 유형 미지정 under :ko locale" do
      Gettext.put_locale(ContractWeb.Gettext, "ko")
      assert ContractTypes.display_name(nil) == "유형 미지정"
    end

    test "display_name(nil) returns Untyped under :en locale" do
      Gettext.put_locale(ContractWeb.Gettext, "en")
      assert ContractTypes.display_name(nil) == "Untyped"
    end

    test "falls back to name_ko when name_en is empty in :en locale" do
      # Defensive — `name_en` is @enforce_keys so this is a synthetic
      # struct, but the helper should still survive an empty string.
      spec = %TypeSpec{
        key: "x",
        family: :nda,
        name_en: "",
        name_ko: "한글 폴백",
        version: "1",
        source: :custom
      }

      Gettext.put_locale(ContractWeb.Gettext, "en")
      assert ContractTypes.display_name(spec) == "한글 폴백"
    end
  end

  describe "TypeSpec.from_toml/2" do
    test "raises on missing required field" do
      assert_raise ArgumentError, ~r/missing required field "key"/, fn ->
        TypeSpec.from_toml(%{"family" => "nda", "name_en" => "x", "version" => "1", "source" => "custom"})
      end
    end

    test "raises on unknown family" do
      data = %{
        "key" => "x",
        "family" => "lawful_evil",
        "name_en" => "X",
        "version" => "1",
        "source" => "custom"
      }

      assert_raise ArgumentError, ~r/unknown family/, fn ->
        TypeSpec.from_toml(data)
      end
    end

    test "raises on unknown source" do
      data = %{
        "key" => "x",
        "family" => "nda",
        "name_en" => "X",
        "version" => "1",
        "source" => "moonbase"
      }

      assert_raise ArgumentError, ~r/unknown source/, fn ->
        TypeSpec.from_toml(data)
      end
    end

    test "raises on unknown field kind" do
      data = %{
        "key" => "x",
        "family" => "nda",
        "name_en" => "X",
        "version" => "1",
        "source" => "custom",
        "recommended_fields" => [
          %{"id" => "f", "label_en" => "F", "kind" => "blob"}
        ]
      }

      assert_raise ArgumentError, ~r/unknown field kind/, fn ->
        TypeSpec.from_toml(data)
      end
    end

    test "accepts numeric version and stringifies it" do
      data = %{
        "key" => "x",
        "family" => "nda",
        "name_en" => "X",
        "version" => 1.0,
        "source" => "custom"
      }

      assert %TypeSpec{version: "1.0"} = TypeSpec.from_toml(data)
    end

    test "defaults recommended_fields and compatible_with to []" do
      data = %{
        "key" => "x",
        "family" => "nda",
        "name_en" => "X",
        "version" => "1",
        "source" => "custom"
      }

      assert %TypeSpec{recommended_fields: [], compatible_with: []} =
               TypeSpec.from_toml(data)
    end
  end
end
