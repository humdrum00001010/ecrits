defmodule Ecrits.Studio.ChatRailState do
  @moduledoc """
  Embedded transmission model for the Studio chat rail.

  The rail receives one validated application-state value instead of a parallel
  collection of LiveView assigns. The chat message stream remains outside this
  model because it is a LiveView runtime carrier rather than application state.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @modes [:no_document, :briefing, :editing, :reviewing]
  @layouts [:default, :mobile_full]
  @agent_statuses [:idle, :working, :queued, :materializing]
  @permissions [:read, :write, :commit, :revoke, :agent_run, :export, :type_change]

  embedded_schema do
    field :mode, Ecto.Enum, values: @modes, default: :briefing
    field :agent_run_id, :string
    field :agent_status, Ecto.Enum, values: @agent_statuses, default: :idle
    field :agent_current_run_id, :string
    field :agent_queue_size, :integer, default: 0

    field :permissions, {:array, Ecto.Enum}, values: @permissions, default: []

    field :thread_title, :string
    field :thread_message_count, :integer, default: 0

    field :layout, Ecto.Enum, values: @layouts, default: :default
    field :grill_active?, :boolean, default: false
    field :grill_marks, {:array, :map}, default: []
  end

  @type t :: %__MODULE__{}

  @fields [
    :mode,
    :agent_run_id,
    :agent_status,
    :agent_current_run_id,
    :agent_queue_size,
    :permissions,
    :thread_title,
    :thread_message_count,
    :layout,
    :grill_active?,
    :grill_marks
  ]

  @doc "Builds rail state from either canonical fields or the owning LiveView values."
  @spec new(map()) :: t()
  def new(attrs \\ %{}) when is_map(attrs) do
    apply_valid_changes(%__MODULE__{}, attrs)
  end

  @doc "Applies a partial application-state update through the same changeset contract."
  @spec put(t(), map()) :: t()
  def put(%__MODULE__{} = state, attrs) when is_map(attrs) do
    apply_valid_changes(state, attrs)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = state, attrs) when is_map(attrs) do
    state
    |> cast(params(state, attrs), @fields)
    |> validate_number(:agent_queue_size, greater_than_or_equal_to: 0)
    |> validate_number(:thread_message_count, greater_than_or_equal_to: 0)
    |> validate_length(:agent_run_id, max: 500)
    |> validate_length(:agent_current_run_id, max: 500)
    |> validate_length(:thread_title, max: 1_000)
  end

  def mobile?(%__MODULE__{layout: :mobile_full}), do: true
  def mobile?(%__MODULE__{}), do: false

  def no_document?(%__MODULE__{mode: :no_document}), do: true
  def no_document?(%__MODULE__{}), do: false

  def observer_mode?(%__MODULE__{permissions: permissions}) do
    :agent_run in permissions and :write in permissions and :commit in permissions and
      :export not in permissions and :type_change not in permissions
  end

  def chat_context_empty?(%__MODULE__{thread_message_count: count}), do: count == 0

  def busy?(%__MODULE__{agent_status: status}),
    do: status in [:working, :queued, :materializing]

  defp params(state, attrs) do
    attrs
    |> canonical_params()
    |> put_studio_state(attrs, state)
    |> put_agent_document_status(attrs, state)
    |> put_scope(attrs)
    |> put_thread(attrs)
    |> put_grill_marks()
  end

  defp apply_valid_changes(state, attrs) do
    changeset = changeset(state, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: state
  end

  defp canonical_params(attrs), do: Map.take(attrs, @fields ++ Enum.map(@fields, &to_string/1))

  defp put_studio_state(params, attrs, state) do
    case fetch(attrs, :studio_state) do
      {:ok, studio_state} when is_map(studio_state) ->
        agent_run_id = value(studio_state, :agent_run_id)
        studio_grill_active? = value(studio_state, :grill_active?) == true
        explicit_grill_active? = value(attrs, :grill_active?) == true

        params
        |> put_if_present(:mode, value(studio_state, :mode))
        |> Map.put(:agent_run_id, agent_run_id)
        |> Map.put(:agent_status, if(is_binary(agent_run_id), do: :working, else: :idle))
        |> Map.put(:agent_current_run_id, agent_run_id)
        |> Map.put(:agent_queue_size, 0)
        |> Map.put(:grill_active?, studio_grill_active? or explicit_grill_active?)

      _other ->
        if Map.has_key?(params, :grill_active?) or Map.has_key?(params, "grill_active?") do
          params
        else
          Map.put(params, :grill_active?, state.grill_active?)
        end
    end
  end

  defp put_agent_document_status(params, attrs, _state) do
    case fetch(attrs, :agent_document_status) do
      {:ok, status} when is_map(status) ->
        current = value(status, :current_attempt)
        queue_size = status |> value(:queue) |> List.wrap() |> length()
        current_run_id = if is_map(current), do: value(current, :id)

        agent_status =
          cond do
            not is_nil(current) and queue_size > 0 -> :queued
            not is_nil(current) -> :working
            queue_size > 0 -> :materializing
            true -> Map.get(params, :agent_status, Map.get(params, "agent_status", :idle))
          end

        params
        |> Map.put(:agent_status, agent_status)
        |> Map.put(:agent_current_run_id, current_run_id)
        |> Map.put(:agent_queue_size, queue_size)

      _other ->
        params
    end
  end

  defp put_scope(params, attrs) do
    case fetch(attrs, :current_scope) do
      {:ok, scope} when is_map(scope) -> Map.put(params, :permissions, value(scope, :perms) || [])
      _other -> params
    end
  end

  defp put_thread(params, attrs) do
    case fetch(attrs, :chat_thread) do
      {:ok, thread} when is_map(thread) ->
        params
        |> put_if_present(:thread_title, value(thread, :title))
        |> put_if_present(:thread_message_count, value(thread, :message_count))

      _other ->
        params
    end
  end

  defp put_grill_marks(params) do
    case Map.get(params, :grill_marks, Map.get(params, "grill_marks")) do
      marks when is_list(marks) -> Map.put(params, :grill_marks, Enum.map(marks, &map_value/1))
      _other -> params
    end
  end

  defp map_value(%_module{} = struct), do: struct |> Map.from_struct() |> Map.delete(:__meta__)
  defp map_value(value) when is_map(value), do: value

  defp put_if_present(params, _key, nil), do: params
  defp put_if_present(params, key, value), do: Map.put(params, key, value)

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      :error -> Map.fetch(map, to_string(key))
      result -> result
    end
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key)))
end
