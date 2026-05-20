defmodule Contract.ContractTypesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Contract.ContractTypes
  alias Contract.ContractTypes.TypeSpec

  describe "list/2" do
    test "ships supported specs, sorted by key, all %TypeSpec{}" do
      assert {:ok, specs} = ContractTypes.list()

      assert length(specs) == length(ContractTypes.__toml_paths__())
      assert length(specs) >= 4
      assert Enum.all?(specs, &match?(%TypeSpec{}, &1))

      keys = specs |> Enum.map(& &1.key)
      key_set = MapSet.new(keys)
      assert keys == Enum.sort(keys)

      for expected <- ~w(nda_v1 service_agreement_v1 employment_v1 custom_v1) do
        assert expected in key_set, "missing canonical type #{expected}"
      end

      refute "franchise_v1" in key_set
      refute "franchise_chicken_v2024_12" in key_set
      refute "supply_v1" in key_set

      # Accepts a ctx as first positional argument (SPEC §18 shape).
      assert {:ok, _} = ContractTypes.list(%{user_id: "u-123"})
    end

    test ":family filter accepts an atom or list of atoms; :source filters by publisher" do
      assert {:ok, employment} = ContractTypes.list(nil, family: :employment)
      assert length(employment) >= 1
      assert Enum.all?(employment, &(&1.family == :employment))

      assert {:ok, pair} = ContractTypes.list(nil, family: [:nda, :employment])
      families = pair |> Enum.map(& &1.family) |> Enum.uniq() |> Enum.sort()
      assert families == [:employment, :nda]

      assert {:ok, ftc} = ContractTypes.list(nil, source: :ftc)
      assert Enum.all?(ftc, &(&1.source == :ftc))
      assert length(ftc) >= 1

      # Unknown family yields an empty list.
      assert ContractTypes.list(nil, family: :nonexistent_family) == {:ok, []}
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
    test "true only when both directions list each other; false for one-way / unknown keys" do
      # service_agreement_v1 <-> nda_v1 are seeded as mutually compatible.
      assert ContractTypes.compatible?("service_agreement_v1", "nda_v1")
      assert ContractTypes.compatible?("nda_v1", "service_agreement_v1")

      # employment_v1 has compatible_with = [], so nothing should pair with it.
      refute ContractTypes.compatible?("employment_v1", "nda_v1")
      refute ContractTypes.compatible?("nda_v1", "employment_v1")

      # Unknown keys return false in either position.
      refute ContractTypes.compatible?("nda_v1", "ghost_key")
      refute ContractTypes.compatible?("ghost_key", "nda_v1")
      refute ContractTypes.compatible?("ghost_a", "ghost_b")
    end
  end

  describe "loaded spec invariants" do
    test "shipped specs are well-formed: fields populated, unique ids, valid compatible_with" do
      specs = ContractTypes.all()
      keys = specs |> Enum.map(& &1.key) |> MapSet.new()

      for spec <- specs do
        assert is_binary(spec.key) and spec.key != ""
        assert is_atom(spec.family)
        assert is_binary(spec.name_en) and spec.name_en != ""
        assert is_binary(spec.version) and spec.version != ""
        assert is_atom(spec.source)
        assert is_list(spec.recommended_fields)
        assert is_list(spec.compatible_with)

        # Every recommended_field has well-formed shape.
        for field <- spec.recommended_fields do
          assert is_binary(field.id) and field.id != ""
          assert is_binary(field.label_en) and field.label_en != ""
          assert field.kind in [:text, :number, :date, :party, :money]
        end

        # Field ids are unique within a spec.
        ids = Enum.map(spec.recommended_fields, & &1.id)
        assert ids == Enum.uniq(ids), "duplicate field id in #{spec.key}"

        # compatible_with only references shipped keys.
        for partner <- spec.compatible_with do
          assert partner in keys,
                 "#{spec.key}.compatible_with references unknown key #{partner}"
        end
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

      check all(path <- StreamData.member_of(paths)) do
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

    test "returns the locale-appropriate name and falls back when empty" do
      {:ok, nda} = ContractTypes.get(nil, "nda_v1")

      # :ko locale → name_ko (struct + string-key form).
      Gettext.put_locale(ContractWeb.Gettext, "ko")
      assert nda.name_ko != nil and nda.name_ko != ""
      assert ContractTypes.display_name(nda) == nda.name_ko
      # Unknown string keys round-trip the key itself.
      assert ContractTypes.display_name("nonexistent_v999") == "nonexistent_v999"

      # :en locale → name_en.
      Gettext.put_locale(ContractWeb.Gettext, "en")
      assert ContractTypes.display_name(nda) == nda.name_en

      # Fallback when the localized name is empty.
      empty_ko = %TypeSpec{
        key: "x",
        family: :nda,
        name_en: "Fallback EN",
        name_ko: "",
        version: "1",
        source: :custom
      }

      Gettext.put_locale(ContractWeb.Gettext, "ko")
      assert ContractTypes.display_name(empty_ko) == "Fallback EN"

      empty_en = %TypeSpec{
        key: "x",
        family: :nda,
        name_en: "",
        name_ko: "한글 폴백",
        version: "1",
        source: :custom
      }

      Gettext.put_locale(ContractWeb.Gettext, "en")
      assert ContractTypes.display_name(empty_en) == "한글 폴백"
    end

    # SPEC.md §18: documents can be created untyped (type_key: nil) and
    # only get a key once the user (Cmd+K) or the agent fills one in
    # via `Action(:set_contract_type)`. The UI must still parse at a
    # glance, so `display_name/1` of nil returns a locale-aware
    # placeholder — "유형 미지정" in :ko, "Untyped" in :en.
    test "display_name(nil) returns locale-aware untyped placeholder" do
      Gettext.put_locale(ContractWeb.Gettext, "ko")
      assert ContractTypes.display_name(nil) == "유형 미지정"

      Gettext.put_locale(ContractWeb.Gettext, "en")
      assert ContractTypes.display_name(nil) == "Untyped"
    end
  end

  describe "TypeSpec.from_toml/2" do
    test "raises on missing fields and unknown values, stringifies numeric version" do
      # Missing required field.
      assert_raise ArgumentError, ~r/missing required field "key"/, fn ->
        TypeSpec.from_toml(%{
          "family" => "nda",
          "name_en" => "x",
          "version" => "1",
          "source" => "custom"
        })
      end

      base = fn ->
        %{
          "key" => "x",
          "name_en" => "X",
          "version" => "1"
        }
      end

      assert_raise ArgumentError, ~r/unknown family/, fn ->
        TypeSpec.from_toml(Map.merge(base.(), %{"family" => "lawful_evil", "source" => "custom"}))
      end

      assert_raise ArgumentError, ~r/unknown source/, fn ->
        TypeSpec.from_toml(Map.merge(base.(), %{"family" => "nda", "source" => "moonbase"}))
      end

      assert_raise ArgumentError, ~r/unknown field kind/, fn ->
        TypeSpec.from_toml(
          Map.merge(base.(), %{
            "family" => "nda",
            "source" => "custom",
            "recommended_fields" => [%{"id" => "f", "label_en" => "F", "kind" => "blob"}]
          })
        )
      end

      # Numeric version stringifies + recommended_fields/compatible_with default [].
      assert %TypeSpec{
               version: "1.0",
               recommended_fields: [],
               compatible_with: []
             } =
               TypeSpec.from_toml(%{
                 "key" => "x",
                 "family" => "nda",
                 "name_en" => "X",
                 "version" => 1.0,
                 "source" => "custom"
               })
    end
  end
end
