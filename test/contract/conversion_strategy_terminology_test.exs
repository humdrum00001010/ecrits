defmodule Contract.ConversionStrategyTerminologyTest do
  use Contract.DataCase, async: false
  use Oban.Testing, repo: Contract.Repo

  import Mox

  alias Contract.Conversion
  alias Contract.Conversion.{FieldPlan, Plan, PlanCache}
  alias Contract.Context
  alias Contract.Documents
  alias Contract.IO.R2Stub
  alias Contract.Workers.ConversionPlanJob

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    R2Stub.setup()
    R2Stub.reset()
    original = Application.get_env(:contract, :io_drivers, [])
    Application.put_env(:contract, :io_drivers, Keyword.put(original, :r2, R2Stub))
    on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)
    :ok
  end

  defp scope do
    %Context{
      user: %Contract.Accounts.User{id: Ecto.UUID.generate(), email: "u@x"},
      tenant: Ecto.UUID.generate(),
      perms: [:type_change, :read, :write]
    }
  end

  defp source_doc(scope) do
    {:ok, doc} =
      Documents.create(scope, %{
        "title" => "src",
        "type_key" => "nda_v1"
      })

    doc
  end

  # Wave 4 terminology migration: `:link_to_matter_field` was renamed
  # to `:link_to_shared_fact`. We accept the legacy strategy on input
  # paths (set_field_strategy/4, lineage rows) but normalize-on-write to
  # the new atom. This test pins all three input surfaces in one shot.
  test "legacy :link_to_matter_field maps to :link_to_shared_fact across input surfaces" do
    scope = scope()
    doc = source_doc(scope)
    {:ok, %Plan{} = plan} = Conversion.plan(scope, doc.id, "service_agreement_v1", [])

    # 1. Allowed strategies list rejects the legacy name.
    assert :link_to_shared_fact in Conversion.allowed_strategies()
    refute :link_to_matter_field in Conversion.allowed_strategies()

    # 2. Plans built by Conversion.plan/4 use the new strategy with
    #    justification text that mentions "shared fact".
    shared_fact_plans = Enum.filter(plan.field_plans, &(&1.strategy == :link_to_shared_fact))
    assert shared_fact_plans != []

    assert Enum.all?(shared_fact_plans, fn p ->
             String.contains?(p.justification, "shared fact")
           end)

    # 3. set_field_strategy/4 with the legacy atom normalizes to the new one.
    [first | _] = plan.field_plans

    assert {:ok, %Plan{field_plans: field_plans}} =
             Conversion.set_field_strategy(
               scope,
               plan,
               first.source_field_id,
               :link_to_matter_field
             )

    assert Enum.find(field_plans, &(&1.source_field_id == first.source_field_id)).strategy ==
             :link_to_shared_fact

    # 4. create_variant/2 persists lineage with the new atom even when
    #    the in-memory FieldPlan carries the legacy value.
    [first_eligible | _] = Enum.reject(plan.field_plans, &(&1.strategy in [:ignore, :ask_user]))

    legacy_plan = %Plan{
      plan
      | field_plans:
          Enum.map(plan.field_plans, fn %FieldPlan{} = fp ->
            if fp.source_field_id == first_eligible.source_field_id,
              do: %FieldPlan{fp | strategy: :link_to_matter_field},
              else: fp
          end)
    }

    {:ok, {new_doc, _change}} = Conversion.create_variant(scope, legacy_plan)

    assert Enum.any?(Documents.list_lineage(scope, new_doc.id), fn lineage ->
             lineage.source_field_id == first_eligible.source_field_id and
               lineage.strategy == :link_to_shared_fact
           end)
  end

  test "legacy matter field model output maps to shared fact strategy" do
    plan = %Plan{
      source_document_id: "doc-#{System.unique_integer([:positive])}",
      source_type_key: "nda_v1",
      target_type_key: "service_agreement_v1",
      strategies: Conversion.allowed_strategies(),
      field_plans: [
        %FieldPlan{
          source_field_id: "field_1",
          target_field_id: "field_1",
          strategy: :ask_user,
          justification: "ambiguous"
        }
      ]
    }

    plan_id = Conversion.plan_id(plan)
    :ok = PlanCache.put(plan_id, plan)

    refinements_json =
      Jason.encode!(%{
        "refinements" => [
          %{
            "source_field_id" => "field_1",
            "suggested_strategy" => "link_to_matter_field",
            "justification" => "Legacy strategy name."
          }
        ]
      })

    Contract.IO.OpenAIMock
    |> expect(:one_shot, fn _params, _opts -> {:ok, %{"output_text" => refinements_json}} end)

    assert :ok = perform_job(ConversionPlanJob, %{"plan_id" => plan_id})

    {:ok, refined} = PlanCache.get(plan_id)
    [field_plan] = refined.field_plans
    assert field_plan.strategy == :link_to_shared_fact
  end
end
