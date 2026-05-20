defmodule Contract.Conversion.PlanCacheTest do
  use ExUnit.Case, async: false

  alias Contract.Conversion.{FieldPlan, Plan, PlanCache}

  defp build_plan(opts \\ []) do
    %Plan{
      source_document_id: Keyword.get(opts, :doc_id, Ecto.UUID.generate()),
      target_type_key: Keyword.get(opts, :target, "service_agreement_v1"),
      source_type_key: Keyword.get(opts, :source, "nda_v1"),
      strategies: [:copy_once, :ask_user],
      field_plans:
        Keyword.get(opts, :field_plans, [
          %FieldPlan{
            source_field_id: "f1",
            target_field_id: "f1",
            strategy: :ask_user,
            justification: "deterministic-default"
          }
        ]),
      impact: %{compatible?: true}
    }
  end

  describe "PlanCache lifecycle (put/get/update/overwrite)" do
    test "round-trips, applies updates atomically, and overwrites on re-put" do
      plan = build_plan()
      key = "plan-#{System.unique_integer([:positive])}"

      # round-trip
      assert :ok = PlanCache.put(key, plan)
      assert {:ok, ^plan} = PlanCache.get(key)

      # update applies atomically
      assert :ok =
               PlanCache.update(key, fn %Plan{} = cached ->
                 [%FieldPlan{} = fp] = cached.field_plans
                 %Plan{cached | field_plans: [%FieldPlan{fp | strategy: :copy_once}]}
               end)

      assert {:ok, updated} = PlanCache.get(key)
      assert [%FieldPlan{strategy: :copy_once}] = updated.field_plans

      # second put overwrites
      replacement = build_plan(target: "employment_v1")
      assert :ok = PlanCache.put(key, replacement)
      assert {:ok, %Plan{target_type_key: "employment_v1"}} = PlanCache.get(key)
    end

    test "missing keys return {:error, :not_found} on get/update" do
      ghost = "ghost-#{System.unique_integer([:positive])}"
      assert {:error, :not_found} = PlanCache.get(ghost)
      assert {:error, :not_found} = PlanCache.update(ghost, & &1)
    end
  end
end
