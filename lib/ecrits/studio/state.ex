defmodule Ecrits.Studio.State do
  @moduledoc """
  Per-LiveView session state. NOT durable. See SPEC.md §9.

  v0.5: `:matter_id` and `:context_reservoir` are gone. The Matter
  container was removed from the product model; Document is the only
  scope. The Context Reservoir is no longer in v0.5 — the left rail is
  optional outline / related-docs in a later wave.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Ecrits.Types, as: T

  @type t :: %__MODULE__{}

  @primary_key false

  embedded_schema do
    field :selected_document_id, :binary_id
    field :selected_node_id, :binary_id

    field :last_seen_version, :integer

    field :chat_open?, :boolean, default: true
    field :document_picker_open?, :boolean, default: false
    field :metadata_panel_open?, :boolean, default: false
    field :migration_panel_open?, :boolean, default: false
    field :upload_panel_open?, :boolean, default: false
    field :type_picker_open?, :boolean, default: false
    field :export_picker_open?, :boolean, default: false

    # When the user picks "다른 문서에서 변형 만들기" from the no-document
    # agent prompt (SPEC.md §10), we open the document_picker modal and
    # set this flag so the modal knows the next pick should kick off a
    # type-conversion flow rather than just open the document.
    field :variant_source_picker?, :boolean, default: false

    field :agent_run_id, :binary_id

    field :mode, Ecto.Enum, values: [:no_document, :briefing, :editing, :reviewing]

    # Map of `node_id => System.system_time(:millisecond)` capturing the
    # epoch when an agent-authored change last touched the node. Used by
    # `Canvas.Editor` to stamp `data-recently-authored="agent"` for a
    # short freshness window so the IR canvas can play a subtle reveal
    # animation. Cleared per-node by the editor JS hook on `animationend`,
    # and pruned server-side by `Ecrits.Studio.State.prune_recently_authored/2`
    # whenever a new agent change arrives.
    field :recently_authored_agent, :map, default: %{}
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :selected_document_id,
      :selected_node_id,
      :last_seen_version,
      :chat_open?,
      :document_picker_open?,
      :metadata_panel_open?,
      :migration_panel_open?,
      :upload_panel_open?,
      :type_picker_open?,
      :export_picker_open?,
      :variant_source_picker?,
      :agent_run_id,
      :mode,
      :recently_authored_agent
    ])
  end

  @doc """
  Freshness window for the "agent typing-reveal" animation. After this
  many milliseconds the marker is dropped so subsequent renders don't
  re-trigger the CSS keyframe. Kept comfortably above the 600 ms CSS
  animation so the marker survives the full reveal even on a delayed
  client re-render.
  """
  @recently_authored_ttl_ms 6_000

  @spec recently_authored_ttl_ms() :: pos_integer()
  def recently_authored_ttl_ms, do: @recently_authored_ttl_ms

  @doc """
  Drops entries older than `recently_authored_ttl_ms/0` from the
  `:recently_authored_agent` map. Called whenever the map is read or
  updated so the per-LV state can't grow unbounded across a long
  session of agent edits.
  """
  @spec prune_recently_authored(t(), integer()) :: t()
  def prune_recently_authored(%__MODULE__{recently_authored_agent: nil} = state, _now),
    do: %__MODULE__{state | recently_authored_agent: %{}}

  def prune_recently_authored(%__MODULE__{recently_authored_agent: map} = state, now)
      when is_map(map) and is_integer(now) do
    cutoff = now - @recently_authored_ttl_ms

    pruned =
      for {node_id, ts} <- map, is_integer(ts) and ts >= cutoff, into: %{} do
        {node_id, ts}
      end

    %__MODULE__{state | recently_authored_agent: pruned}
  end

  @doc """
  Stamps `node_ids` as agent-authored at `now` (epoch ms). Existing
  stale entries are pruned first.
  """
  @spec mark_recently_authored(t(), [String.t()], integer()) :: t()
  def mark_recently_authored(%__MODULE__{} = state, node_ids, now)
      when is_list(node_ids) and is_integer(now) do
    state = prune_recently_authored(state, now)

    new_map =
      Enum.reduce(node_ids, state.recently_authored_agent || %{}, fn id, acc ->
        if is_binary(id), do: Map.put(acc, id, now), else: acc
      end)

    %__MODULE__{state | recently_authored_agent: new_map}
  end

  @doc """
  Removes a single node from `:recently_authored_agent`. Used when the
  client signals the animation has completed via `ack_agent_animation`.
  """
  @spec clear_recently_authored(t(), String.t()) :: t()
  def clear_recently_authored(%__MODULE__{recently_authored_agent: map} = state, node_id)
      when is_binary(node_id) and is_map(map) do
    %__MODULE__{state | recently_authored_agent: Map.delete(map, node_id)}
  end

  def clear_recently_authored(%__MODULE__{} = state, _node_id), do: state
end
