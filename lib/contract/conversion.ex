defmodule Contract.Conversion do
  @moduledoc """
  Type conversion + field migration (SPEC.md §19).

  Converting a document to a different contract type avoids massive
  text-diff Changes by **creating a new variant Document** that inherits
  selected fields from the source. The original document is left
  untouched.

  ## Pipeline

      plan(scope, document_id, target_type_key, opts)
        → %Plan{}                                # field strategies pre-filled

      propose_fields(scope, plan)
        → {:ok, [%FieldPlan{}, ...]}             # deterministic refinement

      set_field_strategy(scope, plan, field_id, strategy)
        → {:ok, %Plan{}}                         # user override

      create_variant(scope, plan)
        → {:ok, %Document{}, %Change{}}          # the new variant + Change

  ## Strategies (the only allowed values)

    * `:copy_once`              — snapshot the source field value into
      the new document. Records lineage.
    * `:link_to_matter_field`   — reference a Matter-level field
      instead of materialising the value. Records lineage.
    * `:derive`                 — keep a computed reference. Records
      lineage.
    * `:reference_only`         — leave the source field where it is;
      the new document refers to it. Records lineage.
    * `:ignore`                 — drop the field on the floor. No
      lineage row.
    * `:ask_user`               — defer to the user; raises on
      `create_variant/2` (the wizard MUST resolve every ambiguity
      before submit).

  ## Defaults (SPEC.md §19 table)

      identity facts (party, date)            → :link_to_matter_field
      document-specific commercial terms      → :copy_once
      ambiguous fields                        → :ask_user
      irrelevant fields                       → :ignore

  When source ↔ target are not declared compatible in their TypeSpecs,
  every field plan defaults to `:ask_user` — the wizard forces the user
  to explicitly handle every field.
  """

  alias Contract.Action
  alias Contract.Change
  alias Contract.Context
  alias Contract.ContractTypes
  alias Contract.ContractTypes.TypeSpec
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.Engine
  alias Contract.Lease
  alias Contract.Repo
  alias Contract.Runtime
  alias Contract.Store
  alias Contract.Types, as: T

  # ---------------------------------------------------------------------------
  # Plan / FieldPlan structs
  # ---------------------------------------------------------------------------

  defmodule Plan do
    @moduledoc """
    Conversion plan returned by `Contract.Conversion.plan/4`. Carries
    enough state to render the migration wizard end-to-end without
    re-querying the source document.
    """

    @enforce_keys [:source_document_id, :target_type_key, :strategies]
    defstruct [
      :source_document_id,
      :target_type_key,
      :source_type_key,
      :strategies,
      :field_plans,
      :impact
    ]

    @type t :: %__MODULE__{
            source_document_id: String.t(),
            target_type_key: String.t(),
            source_type_key: String.t() | nil,
            strategies: [atom()],
            field_plans: [Contract.Conversion.FieldPlan.t()] | nil,
            impact: map() | nil
          }
  end

  defmodule FieldPlan do
    @moduledoc """
    One row in a `%Plan{}.field_plans` list.
    """
    @enforce_keys [:source_field_id, :target_field_id, :strategy]
    defstruct [:source_field_id, :target_field_id, :strategy, :justification]

    @type t :: %__MODULE__{
            source_field_id: String.t(),
            target_field_id: String.t() | nil,
            strategy: atom(),
            justification: String.t() | nil
          }
  end

  # The five strategies enumerated in SPEC §19 plus :ask_user. The
  # @allowed_strategies module attribute is the authoritative whitelist
  # for set_field_strategy/4.
  @allowed_strategies [
    :copy_once,
    :link_to_matter_field,
    :derive,
    :reference_only,
    :ignore,
    :ask_user
  ]

  @doc "The exact strategy enum mandated by SPEC.md §19."
  @spec allowed_strategies() :: [atom()]
  def allowed_strategies, do: @allowed_strategies

  # ---------------------------------------------------------------------------
  # plan/4
  # ---------------------------------------------------------------------------

  @doc """
  Build a conversion plan from a source document to a target type.

  Loads the source document, fetches the target `TypeSpec`, computes
  initial `FieldPlan` defaults per the §19 strategy table, and returns a
  `%Plan{}`.

  Errors:

    * `{:error, :not_found}` — no such source document or target type.
    * `{:error, :forbidden}` — ACL gate failed.
    * `{:error, :missing_type_change_perm}` — scope lacks `:type_change`.
  """
  @spec plan(Context.t(), T.id(), T.contract_type_key(), keyword()) ::
          T.result(Plan.t())
  def plan(%Context{} = scope, document_id, target_type_key, _opts \\ [])
      when is_binary(document_id) and is_binary(target_type_key) do
    with :ok <- check_perm(scope, :type_change),
         {:ok, %Document{} = source} <- Documents.get(scope, document_id),
         {:ok, %TypeSpec{} = target_spec} <- ContractTypes.get(scope, target_type_key) do
      source_type_key = source.type_key

      source_spec =
        case ContractTypes.get(scope, source_type_key) do
          {:ok, spec} -> spec
          _ -> nil
        end

      compatible? = ContractTypes.compatible?(source_type_key, target_type_key)

      field_plans =
        build_default_field_plans(source_spec, target_spec, compatible?)

      plan = %Plan{
        source_document_id: source.id,
        source_type_key: source_type_key,
        target_type_key: target_type_key,
        strategies: @allowed_strategies,
        field_plans: field_plans,
        impact: %{
          compatible?: compatible?,
          source_field_count: source_spec && length(source_spec.recommended_fields) || 0,
          target_field_count: length(target_spec.recommended_fields)
        }
      }

      {:ok, plan}
    end
  end

  # ---------------------------------------------------------------------------
  # propose_fields/2
  # ---------------------------------------------------------------------------

  @doc """
  Returns the list of `FieldPlan`s that the deterministic planner
  recommends. This is deterministic and rule-based for now (per the
  Wave-4 deliverable); the Oban worker `Contract.Workers.ConversionPlanJob`
  is the future async-OpenAI path.
  """
  @spec propose_fields(Context.t(), Plan.t()) :: T.result([FieldPlan.t()])
  def propose_fields(%Context{}, %Plan{field_plans: nil}) do
    {:ok, []}
  end

  def propose_fields(%Context{}, %Plan{field_plans: plans}) do
    {:ok, plans}
  end

  # ---------------------------------------------------------------------------
  # set_field_strategy/4
  # ---------------------------------------------------------------------------

  @doc """
  Override the strategy for a single source field in the plan.

  Returns `{:error, :invalid_strategy}` for strategies not in the
  SPEC.md §19 enumeration.
  """
  @spec set_field_strategy(Context.t(), Plan.t(), T.id(), atom()) ::
          T.result(Plan.t())
  def set_field_strategy(%Context{}, %Plan{} = plan, source_field_id, strategy)
      when is_binary(source_field_id) do
    strategy = normalize_strategy(strategy)

    if strategy in @allowed_strategies do
      new_field_plans =
        Enum.map(plan.field_plans || [], fn
          %FieldPlan{source_field_id: ^source_field_id} = fp ->
            %FieldPlan{fp | strategy: strategy}

          fp ->
            fp
        end)

      {:ok, %Plan{plan | field_plans: new_field_plans}}
    else
      {:error, :invalid_strategy}
    end
  end

  # ---------------------------------------------------------------------------
  # create_variant/2
  # ---------------------------------------------------------------------------

  @doc """
  Create a new variant document from a plan.

  Steps (all in one Repo.transaction so a downstream failure rolls back
  the inserted Document row):

    1. Insert a new `Document` row with `parent_document_id` pointing at
       the source.
    2. Append a `:create_converted_variant` Change against the new
       document via the Engine + Store pipeline.
    3. Insert one `FieldLineage` row per non-ignored, non-ask_user
       FieldPlan.
    4. Stamp the new Document's `variant_of_change_id` with the change id.

  Returns `{:ok, document, change}` on success.
  """
  @spec create_variant(Context.t(), Plan.t()) ::
          T.result({Document.t(), Change.t()})
  def create_variant(%Context{} = scope, %Plan{} = plan) do
    with :ok <- check_perm(scope, :type_change),
         :ok <- check_no_ask_user_remaining(plan),
         {:ok, %Document{} = source} <- Documents.get(scope, plan.source_document_id) do
      do_create_variant(scope, plan, source)
    end
  end

  defp do_create_variant(%Context{user: user} = scope, %Plan{} = plan, %Document{} = source) do
    Repo.transaction(fn ->
      title_prefix = source.title || "Converted document"

      with {:ok, new_doc} <-
             Documents.create(scope, %{
               "matter_id" => source.matter_id,
               "title" => "#{title_prefix} (#{plan.target_type_key})",
               "type_key" => plan.target_type_key,
               "parent_document_id" => source.id,
               "metadata" => %{
                 "converted_from" => source.id,
                 "source_type_key" => source.type_key
               }
             }),
           {:ok, change} <- append_variant_change(new_doc, source, plan, user),
           {:ok, doc_with_lineage} <- stamp_change_id(new_doc, change.id),
           :ok <- insert_lineage_rows(doc_with_lineage, source, plan) do
        {doc_with_lineage, change}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp append_variant_change(%Document{} = new_doc, %Document{} = source, %Plan{} = plan, user) do
    action = %Action{
      kind: :create_converted_variant,
      matter_id: new_doc.matter_id,
      document_id: new_doc.id,
      actor_type: :user,
      actor_id: user && user.id,
      base_revision: 0,
      idempotency_key: "conversion-#{new_doc.id}",
      payload: %{
        "parent_document_id" => source.id,
        "target_type_key" => plan.target_type_key,
        "new_document_id" => new_doc.id,
        "source_type_key" => source.type_key
      },
      message: "Converted from #{source.type_key} to #{plan.target_type_key}"
    }

    empty_state = %Runtime.State{document_id: new_doc.id, revision: 0}

    with {:ok, %Contract.ChangeInput{} = input} <- Engine.compile(action, empty_state),
         {:ok, _} <- Engine.validate(input, empty_state),
         {:ok, preimage} <- Engine.preimage(input, empty_state),
         {:ok, inverse_ops} <- Engine.inverse(input, preimage),
         {:ok, affected_refs} <- Engine.affected_refs(input, empty_state),
         enriched = %Contract.ChangeInput{
           input
           | preimage: preimage,
             inverse_ops: inverse_ops,
             affected_refs: affected_refs
         },
         {:ok, change} <- Engine.build_change(action, enriched, empty_state),
         {:ok, lease} <- Lease.acquire(new_doc.id, "conversion:#{new_doc.id}"),
         {:ok, persisted} <- Store.append(new_doc.id, change, lease.fencing_token) do
      _ = Lease.release(new_doc.id, "conversion:#{new_doc.id}", lease.fencing_token)
      {:ok, persisted}
    end
  end

  defp stamp_change_id(%Document{} = doc, change_id) when is_binary(change_id) do
    doc
    |> Document.changeset(%{"variant_of_change_id" => change_id})
    |> Repo.update()
  end

  defp insert_lineage_rows(%Document{} = new_doc, %Document{} = source, %Plan{} = plan) do
    Enum.reduce_while(plan.field_plans || [], :ok, fn fp, _acc ->
      cond do
        fp.strategy in [:ignore, :ask_user] ->
          {:cont, :ok}

        true ->
          case Documents.insert_lineage(%{
                 "document_id" => new_doc.id,
                 "field_id" => fp.target_field_id || fp.source_field_id,
                 "source_document_id" => source.id,
                 "source_field_id" => fp.source_field_id,
                 "strategy" => fp.strategy,
                 "justification" => fp.justification
               }) do
            {:ok, _row} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # adapt_in_place/3
  # ---------------------------------------------------------------------------

  @doc """
  The "minor edits" path (SPEC.md §15.13). When conversion produces a
  small enough delta that creating a variant would be overkill, the
  agent's compiled Action is applied directly to the source document
  via `Runtime.apply/2`.

  This is NOT the default — `create_variant/2` is. Callers must
  explicitly opt in.
  """
  @spec adapt_in_place(Context.t(), Plan.t(), Action.t()) :: T.result(Change.t())
  def adapt_in_place(%Context{} = scope, %Plan{} = _plan, %Action{} = agent_action) do
    case Runtime.apply(scope, agent_action) do
      {:ok, %Change{} = change} -> {:ok, change}
      {:ok, other} -> {:error, {:unexpected_runtime_return, other}}
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # internals — default strategy table
  # ---------------------------------------------------------------------------

  defp build_default_field_plans(nil, %TypeSpec{recommended_fields: target_fields}, _compatible?) do
    # No source spec known — every target field starts unassigned.
    Enum.map(target_fields, fn tf ->
      %FieldPlan{
        source_field_id: tf.id,
        target_field_id: tf.id,
        strategy: :ask_user,
        justification: "No source contract type available."
      }
    end)
  end

  defp build_default_field_plans(
         %TypeSpec{recommended_fields: source_fields},
         %TypeSpec{recommended_fields: target_fields},
         compatible?
       ) do
    # Build target field index for quick lookups.
    target_by_id = Map.new(target_fields, fn tf -> {tf.id, tf} end)

    source_fields
    |> Enum.map(fn sf ->
      target = Map.get(target_by_id, sf.id)
      target_id = target && target.id

      default_strategy(sf, target, compatible?)
      |> build_field_plan(sf.id, target_id, sf.kind)
    end)
  end

  defp build_field_plan({strategy, justification}, source_id, target_id, _kind) do
    %FieldPlan{
      source_field_id: source_id,
      target_field_id: target_id,
      strategy: strategy,
      justification: justification
    }
  end

  # When source/target types are not declared compatible, every field
  # is :ask_user — the user must consciously handle each one.
  defp default_strategy(_sf, _target, false), do: {:ask_user, "Types are not declared compatible."}

  # Target has no slot for this source field → ignore (irrelevant per §19).
  defp default_strategy(_sf, nil, true), do: {:ignore, "Field has no slot in target type."}

  # Identity facts (parties, dates) → link to matter-level field.
  defp default_strategy(%{kind: :party}, _target, true),
    do: {:link_to_matter_field, "Party identity is matter-level fact."}

  defp default_strategy(%{kind: :date}, _target, true),
    do: {:link_to_matter_field, "Date is a matter-level fact."}

  # Money / number / text → copy_once. Document-specific commercial term.
  defp default_strategy(%{kind: :money}, _target, true),
    do: {:copy_once, "Commercial term carried over by value."}

  defp default_strategy(%{kind: :number}, _target, true),
    do: {:copy_once, "Numeric term carried over by value."}

  defp default_strategy(%{kind: :text}, _target, true),
    do: {:copy_once, "Text field carried over by snapshot."}

  defp default_strategy(_sf, _target, true), do: {:ask_user, "Ambiguous field."}

  # ---------------------------------------------------------------------------
  # internals — perm / consistency checks
  # ---------------------------------------------------------------------------

  defp check_perm(%Context{perms: nil}, _perm), do: {:error, :forbidden}

  defp check_perm(%Context{perms: perms}, perm) when is_list(perms) do
    cond do
      perm in perms -> :ok
      Atom.to_string(perm) in perms -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp check_perm(_scope, _perm), do: {:error, :forbidden}

  defp check_no_ask_user_remaining(%Plan{field_plans: nil}), do: :ok

  defp check_no_ask_user_remaining(%Plan{field_plans: plans}) do
    if Enum.any?(plans, &(&1.strategy == :ask_user)) do
      {:error, :unresolved_ask_user_fields}
    else
      :ok
    end
  end

  defp normalize_strategy(s) when is_atom(s), do: s

  defp normalize_strategy(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> :__invalid__
    end
  end

  defp normalize_strategy(_), do: :__invalid__
end
