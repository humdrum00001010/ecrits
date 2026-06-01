defmodule Contract.Local.Agent.Adapter do
  @moduledoc """
  Behaviour for provider-specific local agent adapters.

  Adapters receive one normalized turn and return an enumerable of normalized
  events. `Contract.Local.Agent.Session` owns supervision, PubSub, tool
  execution, approval policy, and cancellation.
  """

  @type turn :: %{
          required(:id) => binary(),
          required(:session_id) => binary(),
          required(:input) => term(),
          required(:tools) => [map()],
          optional(:document_id) => binary() | nil,
          optional(:workspace_root) => binary() | nil,
          optional(:tool_context) => map()
        }

  @type event ::
          %{required(:type) => atom() | String.t()}
          | {:text_delta, binary()}
          | {:tool_call, binary(), map()}

  @callback stream_turn(turn(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
end
