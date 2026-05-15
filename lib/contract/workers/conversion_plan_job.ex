defmodule Contract.Workers.ConversionPlanJob do
  @moduledoc """
  Background worker for asynchronous OpenAI-assisted field-plan
  proposals (SPEC.md §19).

  As of Wave 4, `Contract.Conversion.propose_fields/2` is deterministic
  and rule-based — the worker exists so the wizard can enqueue an
  upgrade path without changing its call site.

  TODO Wave-4.5: invoke OpenAI for ambiguous-field heuristics. When
  shipping, the worker will:

    1. Fetch the source `Document` via `Contract.Documents.get/2`.
    2. Build a prompt with both contract types' fields.
    3. Call `Contract.IO.OpenAI` with a structured-output schema.
    4. Persist the refined `FieldPlan` list against the in-flight
       wizard session (or publish via PubSub for the LV to pick up).

  Args:

      %{
        "scope_user_id" => uuid,
        "document_id" => uuid,
        "target_type_key" => string
      }
  """
  use Oban.Worker, queue: :agent, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Stub. The deterministic planner already runs inline; this worker
    # is a no-op until Wave-4.5 OpenAI heuristics land.
    _ = args
    :ok
  end
end
