defmodule Contract.ChangeInput do
  @moduledoc """
  Intermediate result of `Contract.Session.Reducer.compile/2`: a validated, ready-to-apply
  representation of an `Contract.Command`. Not durable — only `Contract.Change`
  is. See SPEC.md §13.

  Lifecycle:

      Reducer.compile/2       → returns %ChangeInput{}            (ops, marks filled)
      Reducer.validate/2      → returns :ok                       (no struct change)
      Reducer.preimage/2      → returns map                       (caller stuffs into :preimage)
      Reducer.inverse/2       → returns [Operation.t()]           (caller stuffs into :inverse_ops)
      Reducer.apply/2         → returns new Runtime.State
      Reducer.affected_refs/2 → returns [map()]                   (caller stuffs into :affected_refs)
      Reducer.build_change/3  → returns Contract.Change           (durable)
  """

  alias Contract.{MarkInput, Operation, Types}

  @type t :: %__MODULE__{
          action_kind: atom(),
          document_id: Types.document_id() | nil,
          base_revision: Types.revision() | nil,
          idempotency_key: Types.idempotency_key() | nil,
          actor_type: atom(),
          actor_id: Types.user_id() | nil,
          ops: [Operation.t()],
          marks: [MarkInput.t()],
          message: String.t() | nil,
          affected_refs: [map()],
          preimage: map() | nil,
          inverse_ops: [Operation.t()],
          agent_run_id: Types.agent_run_id() | nil,
          metadata: map()
        }

  defstruct action_kind: nil,
            document_id: nil,
            base_revision: nil,
            idempotency_key: nil,
            actor_type: :user,
            actor_id: nil,
            ops: [],
            marks: [],
            message: nil,
            affected_refs: [],
            preimage: nil,
            inverse_ops: [],
            agent_run_id: nil,
            metadata: %{}
end
