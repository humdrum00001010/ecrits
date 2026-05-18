defmodule Contract.Workers.ConversionPlanJobTest do
  use Contract.DataCase, async: false
  use Oban.Testing, repo: Contract.Repo

  import Mox

  alias Contract.Conversion
  alias Contract.Conversion.{FieldPlan, Plan, PlanCache}
  alias Contract.Workers.ConversionPlanJob

  setup :set_mox_from_context
  setup :verify_on_exit!

  # --- helpers ----------------------------------------------------------

  defp build_plan(opts) do
    field_count = Keyword.get(opts, :ambiguous_count, 5)

    field_plans =
      Enum.map(1..field_count, fn n ->
        %FieldPlan{
          source_field_id: "field_#{n}",
          target_field_id: "field_#{n}",
          strategy: :ask_user,
          justification: "ambiguous (default)"
        }
      end)

    %Plan{
      source_document_id: Keyword.get(opts, :doc_id, "doc-#{System.unique_integer([:positive])}"),
      target_type_key: Keyword.get(opts, :target, "service_agreement_v1"),
      source_type_key: Keyword.get(opts, :source, "nda_v1"),
      strategies: Conversion.allowed_strategies(),
      field_plans: field_plans,
      impact: %{compatible?: true}
    }
  end

  defp stash(plan) do
    key = Conversion.plan_id(plan)
    :ok = PlanCache.put(key, plan)
    key
  end

  # The OpenAI Responses-API returns a `output_text` shortcut when the
  # request used JSON-mode. Our worker accepts both shapes — we use the
  # easier one in fixtures.
  defp openai_response_with_text(text) when is_binary(text) do
    %{"output_text" => text}
  end

  # --- tests ------------------------------------------------------------

  describe "perform/1" do
    test "drains job, updates PlanCache with refined strategies, broadcasts :plan_refined" do
      plan = build_plan(ambiguous_count: 3)
      plan_id = stash(plan)
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, ConversionPlanJob.topic(plan_id))

      refinements_json =
        Jason.encode!(%{
          "refinements" => [
            %{
              "source_field_id" => "field_1",
              "suggested_strategy" => "copy_once",
              "justification" => "Looks like a commercial term."
            },
            %{
              "source_field_id" => "field_2",
              "suggested_strategy" => "link_to_shared_fact",
              "justification" => "Party identity is shared."
            },
            %{
              "source_field_id" => "field_3",
              "suggested_strategy" => "ignore",
              "justification" => "Source has no target slot."
            }
          ]
        })

      Contract.IO.OpenAIMock
      |> expect(:one_shot, fn _params, _opts ->
        {:ok, openai_response_with_text(refinements_json)}
      end)

      assert :ok = perform_job(ConversionPlanJob, %{"plan_id" => plan_id})
      assert_receive {:plan_refined, ^plan_id}, 1_000

      {:ok, refined} = PlanCache.get(plan_id)
      by_id = Map.new(refined.field_plans, &{&1.source_field_id, &1})

      assert by_id["field_1"].strategy == :copy_once
      assert by_id["field_1"].justification == "Looks like a commercial term."
      assert by_id["field_2"].strategy == :link_to_shared_fact
      assert by_id["field_3"].strategy == :ignore
    end

    test "<3 ambiguous fields → NO job enqueued by propose_fields/2" do
      # Build a fully compatible plan (no :ask_user fields) directly through
      # the Conversion API so we hit the real dispatch decision.
      scope = %Contract.Context{
        user: %Contract.Accounts.User{id: Ecto.UUID.generate(), email: "u@x"},
        tenant: Ecto.UUID.generate(),
        perms: [:type_change, :read, :write]
      }

      {:ok, d} =
        Contract.Documents.create(scope, %{
          "title" => "src",
          "type_key" => "nda_v1"
        })

      {:ok, plan} = Conversion.plan(scope, d.id, "service_agreement_v1", [])

      # nda → service_agreement is compatible: default strategies are
      # :copy_once / :link_to_shared_fact, so well under 3 :ask_user.
      assert Enum.count(plan.field_plans, &(&1.strategy == :ask_user)) < 3

      assert {:ok, _plans} = Conversion.propose_fields(scope, plan)
      # No driver expect set up — verify_on_exit! would catch an
      # unexpected call. Also assert via Oban.Testing:
      refute_enqueued(worker: ConversionPlanJob)
    end

    test "5 ambiguous fields, OpenAI refines only 3 → other 2 stay :ask_user" do
      plan = build_plan(ambiguous_count: 5)
      plan_id = stash(plan)
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, ConversionPlanJob.topic(plan_id))

      refinements_json =
        Jason.encode!(%{
          "refinements" => [
            %{"source_field_id" => "field_1", "suggested_strategy" => "copy_once"},
            %{"source_field_id" => "field_2", "suggested_strategy" => "ignore"},
            %{"source_field_id" => "field_3", "suggested_strategy" => "derive"}
          ]
        })

      Contract.IO.OpenAIMock
      |> expect(:one_shot, fn _params, _opts ->
        {:ok, openai_response_with_text(refinements_json)}
      end)

      assert :ok = perform_job(ConversionPlanJob, %{"plan_id" => plan_id})
      assert_receive {:plan_refined, ^plan_id}, 1_000

      {:ok, refined} = PlanCache.get(plan_id)
      by_id = Map.new(refined.field_plans, &{&1.source_field_id, &1})

      assert by_id["field_1"].strategy == :copy_once
      assert by_id["field_2"].strategy == :ignore
      assert by_id["field_3"].strategy == :derive
      assert by_id["field_4"].strategy == :ask_user
      assert by_id["field_5"].strategy == :ask_user
    end

    test "junk strategy atoms from the model are dropped, not applied" do
      plan = build_plan(ambiguous_count: 3)
      plan_id = stash(plan)

      refinements_json =
        Jason.encode!(%{
          "refinements" => [
            %{"source_field_id" => "field_1", "suggested_strategy" => "obliterate"},
            %{"source_field_id" => "field_2", "suggested_strategy" => "copy_once"}
          ]
        })

      Contract.IO.OpenAIMock
      |> expect(:one_shot, fn _params, _opts ->
        {:ok, openai_response_with_text(refinements_json)}
      end)

      assert :ok = perform_job(ConversionPlanJob, %{"plan_id" => plan_id})

      {:ok, refined} = PlanCache.get(plan_id)
      by_id = Map.new(refined.field_plans, &{&1.source_field_id, &1})

      assert by_id["field_1"].strategy == :ask_user
      assert by_id["field_2"].strategy == :copy_once
    end

    test "unknown plan_id is a silent :ok (wizard closed while job was queued)" do
      assert :ok = perform_job(ConversionPlanJob, %{"plan_id" => "no-such-plan"})
    end

    test "OpenAI driver error / malformed JSON → plan untouched, no broadcast" do
      # Malformed JSON branch.
      malformed_plan = build_plan(ambiguous_count: 3)
      malformed_id = stash(malformed_plan)
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, ConversionPlanJob.topic(malformed_id))

      Contract.IO.OpenAIMock
      |> expect(:one_shot, fn _params, _opts ->
        {:ok, openai_response_with_text("this is not json {{{")}
      end)

      assert :ok = perform_job(ConversionPlanJob, %{"plan_id" => malformed_id})
      refute_receive {:plan_refined, _}, 200

      {:ok, malformed_after} = PlanCache.get(malformed_id)
      assert Enum.all?(malformed_after.field_plans, &(&1.strategy == :ask_user))

      # Driver error branch.
      plan = build_plan(ambiguous_count: 3)
      plan_id = stash(plan)
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, ConversionPlanJob.topic(plan_id))

      Contract.IO.OpenAIMock
      |> expect(:one_shot, fn _params, _opts -> {:error, :upstream_down} end)

      assert :ok = perform_job(ConversionPlanJob, %{"plan_id" => plan_id})
      refute_receive {:plan_refined, _}, 200

      {:ok, after_plan} = PlanCache.get(plan_id)
      assert Enum.all?(after_plan.field_plans, &(&1.strategy == :ask_user))
    end
  end

  describe "propose_fields/2 dispatch" do
    test "≥ 3 :ask_user fields → enqueues a ConversionPlanJob with the plan_id" do
      scope = %Contract.Context{
        user: %Contract.Accounts.User{id: Ecto.UUID.generate(), email: "u@x"},
        tenant: Ecto.UUID.generate(),
        perms: [:type_change, :read, :write]
      }

      {:ok, d} =
        Contract.Documents.create(scope, %{
          "title" => "src",
          "type_key" => "nda_v1"
        })

      # nda_v1 → employment_v1 is NOT declared compatible: every field
      # defaults to :ask_user (well over 3).
      {:ok, plan} = Conversion.plan(scope, d.id, "employment_v1", [])
      assert Enum.count(plan.field_plans, &(&1.strategy == :ask_user)) >= 3

      assert {:ok, _plans} = Conversion.propose_fields(scope, plan)

      expected_id = Conversion.plan_id(plan)
      assert_enqueued(worker: ConversionPlanJob, args: %{"plan_id" => expected_id})

      # And the plan should be parked under that ID so the worker can read it.
      assert {:ok, %Plan{}} = PlanCache.get(expected_id)
    end
  end
end
