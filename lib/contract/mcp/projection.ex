defmodule Contract.MCP.Projection do
  @moduledoc """
  Adapter from `Contract.Runtime.State` projection (node-graph) to the flat
  `sections → paragraphs` shape that `Contract.Agent.Prompt.IRRenderer`
  consumes.

  ## Source of truth

  R2 is the canonical source. At snapshot time the client uploads both
  the HWPX original (`<rev>.hwpx`) and the extracted agent IR
  (`<rev>.ir.json`); doc.get reads the `.ir.json` blob via the
  S3-compatible client (`Contract.IO.R2.get/2`). Postgres
  `snapshots.projection` stays as a hot cache that's used when R2 is
  unreachable.

  Using the snapshotted IR (not an op-log replay) is what makes the
  agent see the same paragraphs the user sees: per-keystroke IME
  composition steps each emit their own delete+insert pair, and
  replaying them later doesn't reliably reconstruct the visible text.

  Falls back to the legacy `node_order` projection path for docs created
  via `create_node` that never went through rhwp (no snapshot row).

  TODO(#120): emit `kind: "table"` with nested cell paragraphs once
  edit_table / insert_block lands.
  """

  import Ecto.Query
  require Logger

  alias Contract.IO.R2
  alias Contract.Repo
  alias Contract.Runtime
  alias Contract.Runtime.State
  alias Contract.Snapshot

  @doc """
  Build the agent-IR map for `IRRenderer.render/1`. Returns a plain map
  with stringified keys + the current revision baked in.
  """
  @spec to_agent_ir(State.t()) :: map()
  def to_agent_ir(%State{} = state) do
    case latest_rhwp_snapshot(state.document_id) do
      %Snapshot{} = snap ->
        case fetch_ir_from_r2(snap) do
          {:ok, ir} when is_map(ir) and map_size(ir) > 0 ->
            from_snapshot(ir, state)

          _ ->
            db_projection_or_legacy(snap, state)
        end

      nil ->
        from_legacy_projection(state)
    end
  end

  defp latest_rhwp_snapshot(document_id) do
    from(s in Snapshot,
      where: s.document_id == ^document_id and like(s.r2_key, ^"%.hwpx"),
      order_by: [desc: s.revision],
      limit: 1
    )
    |> Repo.one()
  end

  defp fetch_ir_from_r2(%Snapshot{r2_key: hwpx_key}) when is_binary(hwpx_key) do
    ir_key = ir_key_for(hwpx_key)

    with {:ok, body} <- R2.get(ir_key),
         {:ok, ir} <- Jason.decode(body) do
      {:ok, ir}
    else
      err ->
        Logger.debug("doc.get: R2 IR fetch failed for #{ir_key}: #{inspect(err)}")
        err
    end
  end

  defp fetch_ir_from_r2(_), do: {:error, :no_key}

  defp ir_key_for(hwpx_key) do
    if String.ends_with?(hwpx_key, ".hwpx") do
      String.replace_suffix(hwpx_key, ".hwpx", ".ir.json")
    else
      hwpx_key <> ".ir.json"
    end
  end

  defp db_projection_or_legacy(%Snapshot{projection: %{} = snap}, %State{} = state)
       when map_size(snap) > 0,
       do: from_snapshot(snap, state)

  defp db_projection_or_legacy(_snap, %State{} = state),
    do: from_legacy_projection(state)

  defp from_snapshot(snap, %State{} = state) do
    %{
      "title" => Map.get(snap, "title") || Map.get(state.projection, :title),
      "revision" => state.revision,
      "contract_type" =>
        Map.get(snap, "contract_type") || Map.get(state.projection, :type_key),
      "sections" => normalize_sections(Map.get(snap, "sections", [])),
      "fields" => normalize_fields(Map.get(snap, "fields", []), state)
    }
  end

  defp from_legacy_projection(%State{} = state) do
    %{
      "title" => Map.get(state.projection, :title),
      "revision" => state.revision,
      "contract_type" => Map.get(state.projection, :type_key),
      "sections" => [%{"idx" => 0, "paragraphs" => paragraphs_from_projection(state)}],
      "fields" => fields_for(state)
    }
  end

  defp normalize_sections(sections) when is_list(sections) do
    sections
    |> Enum.with_index()
    |> Enum.map(fn {sec, default_idx} ->
      %{
        "idx" => Map.get(sec, "idx", default_idx),
        "paragraphs" =>
          sec
          |> Map.get("paragraphs", [])
          |> Enum.with_index()
          |> Enum.map(fn {p, default_pidx} ->
            %{
              "idx" => Map.get(p, "idx", default_pidx),
              "text" => Map.get(p, "text", "")
            }
            |> maybe_put_kind(p)
          end)
      }
    end)
  end

  defp normalize_sections(_), do: []

  defp maybe_put_kind(paragraph, %{"kind" => kind}) when is_binary(kind),
    do: Map.put(paragraph, "kind", kind)

  defp maybe_put_kind(paragraph, _), do: paragraph

  defp normalize_fields(fields, _state) when is_list(fields) and fields != [], do: fields
  defp normalize_fields(_, state), do: fields_for(state)

  @spec load_agent_ir(any(), binary()) :: {:ok, map()} | {:error, term()}
  def load_agent_ir(ctx, document_id) do
    with {:ok, %State{} = state} <- Runtime.load(ctx, document_id) do
      {:ok, to_agent_ir(state)}
    end
  end

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
