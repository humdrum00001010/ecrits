defmodule Contract.MCP.Projection do
  @moduledoc """
  Adapter from `Contract.Runtime.State` projection (node-graph) to the flat
  `sections → paragraphs` shape that `Contract.Agent.Prompt.IRRenderer`
  consumes.

  v1 is intentionally minimal: every top-level node in `node_order` becomes
  one paragraph in a single section 0. Tables and headings render as plain
  body paragraphs (their text content). Field positions are passed through
  if present on the projection's `fields` map.

  TODO(#120): emit `kind: "table"` with nested cell paragraphs once
  edit_table / insert_block lands.
  """

  alias Contract.Runtime
  alias Contract.Runtime.State

  @doc """
  Build the agent-IR map for `IRRenderer.render/1`. Returns a plain map
  with stringified keys + the current revision baked in.
  """
  @spec to_agent_ir(State.t()) :: map()
  def to_agent_ir(%State{} = state) do
    paragraphs =
      case Contract.MCP.RhwpReplay.replay(nil, state.document_id) do
        {:ok, [_ | _] = replayed} -> Enum.map(replayed, &paragraph_from_replay/1)
        _ -> paragraphs_from_projection(state)
      end

    %{
      "title" => Map.get(state.projection, :title),
      "revision" => state.revision,
      "contract_type" => Map.get(state.projection, :type_key),
      "sections" => [%{"idx" => 0, "paragraphs" => paragraphs}],
      "fields" => fields_for(state)
    }
  end

  @spec load_agent_ir(any(), binary()) :: {:ok, map()} | {:error, term()}
  def load_agent_ir(ctx, document_id) do
    with {:ok, %State{} = state} <- Runtime.load(ctx, document_id) do
      {:ok, to_agent_ir(state)}
    end
  end

  defp paragraph_from_replay(%{idx: idx, text: text}),
    do: %{"idx" => idx, "text" => text}

  # Fallback for docs whose body lives in the projection (legacy create_node
  # flow, never went through rhwp text ops).
  defp paragraphs_from_projection(%State{} = state) do
    state.projection
    |> Map.get(:node_order, [])
    |> Enum.with_index()
    |> Enum.flat_map(fn {node_id, idx} ->
      case node_for(state, node_id) do
        nil -> []
        node -> [paragraph_for(node, idx)]
      end
    end)
  end

  defp node_for(%State{projection: %{nodes: nodes}}, id) when is_map(nodes),
    do: Map.get(nodes, id)

  defp node_for(_state, _id), do: nil

  defp paragraph_for(node, idx) do
    %{
      "idx" => idx,
      "text" => to_string(Map.get(node, :content) || "")
    }
  end

  defp fields_for(%State{projection: %{fields: fields}}) when is_map(fields) do
    fields
    |> Map.values()
    |> Enum.map(fn f ->
      %{
        "id" => Map.get(f, :id),
        "label" => Map.get(f, :key) |> to_string_or_nil(),
        "kind" => Map.get(f, :kind) |> to_string_or_nil(),
        "position" => Map.get(f, :attrs, %{}) |> Map.get(:position, %{}),
        "value" => Map.get(f, :value)
      }
    end)
  end

  defp fields_for(_state), do: []

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)
end
