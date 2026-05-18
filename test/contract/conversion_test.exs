defmodule Contract.ConversionTest do
  use Contract.DataCase, async: false

  alias Contract.Conversion
  alias Contract.Conversion.{FieldPlan, Plan}
  alias Contract.Context
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.Documents.FieldLineage
  alias Contract.IO.R2Stub

  setup do
    R2Stub.setup()
    R2Stub.reset()
    original = Application.get_env(:contract, :io_drivers, [])
    Application.put_env(:contract, :io_drivers, Keyword.put(original, :r2, R2Stub))
    on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)
    :ok
  end

  defp scope(opts \\ []) do
    perms = Keyword.get(opts, :perms, [:type_change, :read, :write])

    %Context{
      user: %Contract.Accounts.User{id: Ecto.UUID.generate(), email: "u@x"},
      tenant: Ecto.UUID.generate(),
      perms: perms
    }
  end

  defp build_source_doc(s, type_key \\ "nda_v1") do
    {:ok, d} =
      Documents.create(s, %{
        "title" => "src",
        "type_key" => type_key
      })

    d
  end

  describe "plan/4" do
    test "returns a Plan with field_plans for compatible types" do
      s = scope()
      d = build_source_doc(s, "nda_v1")

      assert {:ok, %Plan{} = plan} =
               Conversion.plan(s, d.id, "service_agreement_v1", [])

      assert plan.source_document_id == d.id
      assert plan.target_type_key == "service_agreement_v1"
      assert plan.source_type_key == "nda_v1"
      assert is_list(plan.field_plans)
      assert length(plan.field_plans) > 0
      assert plan.impact[:compatible?] == true
    end

    test "returns a Plan with :ask_user defaults for incompatible types" do
      s = scope()
      d = build_source_doc(s, "nda_v1")

      # nda_v1 is NOT declared compatible with employment_v1.
      assert {:ok, %Plan{} = plan} =
               Conversion.plan(s, d.id, "employment_v1", [])

      assert plan.impact[:compatible?] == false
      assert Enum.all?(plan.field_plans, &(&1.strategy == :ask_user))
    end

    test "rejects unknown target / missing :type_change perm / nil-perms scope" do
      s = scope()
      d = build_source_doc(s)
      assert {:error, :not_found} = Conversion.plan(s, d.id, "nonsense_v1", [])

      read_only = scope(perms: [:read])
      ro_doc = build_source_doc(read_only)

      assert {:error, :forbidden} =
               Conversion.plan(read_only, ro_doc.id, "service_agreement_v1", [])

      nil_perms = %Context{
        user: %Contract.Accounts.User{id: Ecto.UUID.generate(), email: "u@x"},
        tenant: Ecto.UUID.generate(),
        perms: nil
      }

      assert {:error, :forbidden} =
               Conversion.plan(nil_perms, Ecto.UUID.generate(), "service_agreement_v1", [])
    end
  end

  describe "propose_fields/2" do
    test "deterministic for all five shipped types" do
      s = scope()
      d = build_source_doc(s, "nda_v1")

      for target <-
            ~w(nda_v1 service_agreement_v1 supply_v1 employment_v1 franchise_v1) do
        assert {:ok, plan} = Conversion.plan(s, d.id, target, [])
        assert {:ok, plans} = Conversion.propose_fields(s, plan)
        assert is_list(plans)
        # Determinism: running twice must yield identical strategies.
        assert {:ok, plan2} = Conversion.plan(s, d.id, target, [])
        assert {:ok, plans2} = Conversion.propose_fields(s, plan2)
        assert plans == plans2
      end
    end
  end

  describe "set_field_strategy/4" do
    test "accepts valid strategies (atom + string), rejects unknown" do
      s = scope()
      d = build_source_doc(s, "nda_v1")
      {:ok, plan} = Conversion.plan(s, d.id, "service_agreement_v1", [])
      [first | _] = plan.field_plans

      assert {:ok, %Plan{field_plans: new_plans}} =
               Conversion.set_field_strategy(s, plan, first.source_field_id, :copy_once)

      assert Enum.find(new_plans, &(&1.source_field_id == first.source_field_id)).strategy ==
               :copy_once

      # String form accepted.
      assert {:ok, %Plan{}} =
               Conversion.set_field_strategy(s, plan, first.source_field_id, "ignore")

      # Unknown atom rejected.
      assert {:error, :invalid_strategy} =
               Conversion.set_field_strategy(s, plan, first.source_field_id, :bogus)
    end
  end

  describe "create_variant/2" do
    test "produces new Document with parent + new type_key + Change + variant_of_change_id" do
      s = scope()
      source = build_source_doc(s, "nda_v1")
      {:ok, plan} = Conversion.plan(s, source.id, "service_agreement_v1", [])

      assert {:ok, {%Document{} = new_doc, %Contract.Change{} = change}} =
               Conversion.create_variant(s, plan)

      assert new_doc.parent_document_id == source.id
      assert new_doc.type_key == "service_agreement_v1"
      assert new_doc.owner_id == source.owner_id
      assert change.command_kind == "create_converted_variant"
      assert change.document_id == new_doc.id

      # The new document stamps variant_of_change_id with the originating
      # Change so the audit lineage stays append-only.
      assert new_doc.variant_of_change_id == change.id
      # The Change exposes an inverse list so Engine can round-trip it.
      assert is_list(change.inverse)
    end

    test "lineage rows track non-ignored/non-ask_user strategies and drop on per-field force" do
      s = scope()
      source = build_source_doc(s, "nda_v1")
      {:ok, %Plan{} = plan} = Conversion.plan(s, source.id, "service_agreement_v1", [])

      eligible =
        Enum.filter(plan.field_plans, &(&1.strategy not in [:ignore, :ask_user]))

      eligible_count = length(eligible)
      assert eligible_count > 0

      # Baseline: lineage row count == eligible count.
      {:ok, {new_doc, _change}} = Conversion.create_variant(s, plan)
      assert length(Documents.list_lineage(s, new_doc.id)) == eligible_count

      # Force one eligible field to :ignore → lineage drops by 1.
      [first_eligible | _] = eligible

      forced_one_plan = %Plan{
        plan
        | field_plans:
            Enum.map(plan.field_plans, fn %FieldPlan{} = fp ->
              if fp.source_field_id == first_eligible.source_field_id,
                do: %FieldPlan{fp | strategy: :ignore},
                else: fp
            end)
      }

      {:ok, {forced_doc, _}} = Conversion.create_variant(s, forced_one_plan)
      forced_lineage = Documents.list_lineage(s, forced_doc.id)
      assert length(forced_lineage) == eligible_count - 1
      refute Enum.any?(forced_lineage, &(&1.source_field_id == first_eligible.source_field_id))

      # Force every field to :ignore → no lineage rows.
      all_ignored = %Plan{
        plan
        | field_plans:
            Enum.map(plan.field_plans, fn %FieldPlan{} = field_plan ->
              %FieldPlan{field_plan | strategy: :ignore}
            end)
      }

      {:ok, {empty_doc, _}} = Conversion.create_variant(s, all_ignored)
      assert [] = Documents.list_lineage(s, empty_doc.id)
    end

    test "remaining :ask_user fields block create_variant" do
      s = scope()
      source = build_source_doc(s, "nda_v1")
      {:ok, %Plan{} = plan} = Conversion.plan(s, source.id, "employment_v1", [])

      # Incompatible types → every field defaults to :ask_user.
      assert {:error, :unresolved_ask_user_fields} = Conversion.create_variant(s, plan)
    end

    test "scope without :type_change perm → :forbidden" do
      s = scope(perms: [:read])
      d = build_source_doc(s, "nda_v1")

      plan = %Plan{
        source_document_id: d.id,
        target_type_key: "service_agreement_v1",
        strategies: Conversion.allowed_strategies(),
        field_plans: []
      }

      assert {:error, :forbidden} = Conversion.create_variant(s, plan)
    end
  end

  describe "allowed_strategies/0" do
    test "matches the SPEC.md §19 enumeration" do
      assert Conversion.allowed_strategies() == [
               :copy_once,
               :link_to_shared_fact,
               :derive,
               :reference_only,
               :ignore,
               :ask_user
             ]
    end
  end

  describe "Plan struct" do
    test "enforces source_document_id / target_type_key / strategies" do
      assert_raise ArgumentError, fn ->
        struct!(Plan, target_type_key: "x", strategies: [])
      end
    end
  end

  describe "FieldLineage append-only" do
    test "lineage rows survive a re-read with the correct columns" do
      s = scope()
      source = build_source_doc(s, "nda_v1")
      {:ok, plan} = Conversion.plan(s, source.id, "service_agreement_v1", [])

      {:ok, {new_doc, _change}} = Conversion.create_variant(s, plan)

      lineage = Documents.list_lineage(s, new_doc.id)

      assert Enum.all?(lineage, fn row ->
               %FieldLineage{strategy: strat, source_document_id: sdoc} = row

               strat in [:copy_once, :link_to_shared_fact, :derive, :reference_only] and
                 sdoc == source.id
             end)
    end
  end
end
