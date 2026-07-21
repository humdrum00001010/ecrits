defmodule Ecrits.Document.EditTimeline do
  @moduledoc """
  Pure lifecycle reducer for genuine mounted-document edit revisions.

  Candidate state is transient. Committed edit facts remain in the timeline so
  asynchronous durable snapshot publication cannot discard earlier highlights.
  """

  @type phase :: :candidate | :committed | :rejected | :snapshot_ready

  @type t :: %__MODULE__{
          turn_id: String.t(),
          document_id: String.t(),
          candidates: %{optional(String.t()) => map()},
          candidate_order: [String.t()],
          committed: %{optional(String.t()) => map()},
          committed_order: [String.t()],
          current_ref: {:candidate | :committed, String.t()} | nil
        }

  defstruct [
    :turn_id,
    :document_id,
    candidates: %{},
    candidate_order: [],
    committed: %{},
    committed_order: [],
    current_ref: nil
  ]

  @spec new(String.t(), String.t()) :: t()
  def new(turn_id, document_id) when is_binary(turn_id) and is_binary(document_id) do
    %__MODULE__{turn_id: turn_id, document_id: document_id}
  end

  @spec apply_event(t(), map()) :: {:ok, t()} | {:stale, t()} | {:error, term()}
  def apply_event(%__MODULE__{} = timeline, event) when is_map(event) do
    with :ok <- validate_identity(timeline, event),
         {:ok, phase} <- event_phase(event),
         {:ok, edit_id, revision} <- event_revision_identity(event) do
      reduce(timeline, event, phase, edit_id, revision)
    end
  end

  def apply_event(%__MODULE__{}, _event), do: {:error, :invalid_event}

  @spec highlights(t()) :: [map()]
  def highlights(%__MODULE__{} = timeline) do
    timeline
    |> committed_highlights()
    |> order_highlights()
  end

  @spec visible_highlights(t()) :: [map()]
  def visible_highlights(%__MODULE__{} = timeline) do
    candidate_highlights =
      case timeline.current_ref do
        {:candidate, edit_id} ->
          timeline.candidates
          |> Map.get(edit_id, %{})
          |> field(:highlights, [])
          |> List.wrap()

        _current_ref ->
          []
      end

    timeline
    |> committed_highlights()
    |> Kernel.++(candidate_highlights)
    |> order_highlights()
  end

  defp committed_highlights(timeline) do
    Enum.flat_map(timeline.committed_order, fn edit_id ->
      timeline.committed
      |> Map.fetch!(edit_id)
      |> field(:highlights, [])
      |> List.wrap()
    end)
  end

  defp order_highlights(highlights) do
    highlights
    |> Enum.filter(&is_map/1)
    |> Enum.uniq_by(&canonical_term/1)
    |> Enum.with_index()
    |> Enum.sort_by(fn {highlight, stable_index} ->
      {highlight_position(highlight), stable_index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  @spec current(t()) :: map() | nil
  def current(%__MODULE__{current_ref: {:candidate, edit_id}} = timeline),
    do: Map.get(timeline.candidates, edit_id)

  def current(%__MODULE__{current_ref: {:committed, edit_id}} = timeline),
    do: Map.get(timeline.committed, edit_id)

  def current(%__MODULE__{}), do: nil

  defp reduce(timeline, event, :candidate, edit_id, _revision) do
    timeline = %{
      timeline
      | candidates: Map.put(timeline.candidates, edit_id, atomize_phase(event, :candidate)),
        candidate_order: append_once(timeline.candidate_order, edit_id),
        current_ref: {:candidate, edit_id}
    }

    {:ok, timeline}
  end

  defp reduce(timeline, event, :committed, edit_id, revision) do
    case Map.get(timeline.candidates, edit_id) do
      candidate when is_map(candidate) ->
        if field(candidate, :revision) == revision,
          do: commit(timeline, event, edit_id, revision),
          else: {:stale, timeline}

      _candidate ->
        commit(timeline, event, edit_id, revision)
    end
  end

  defp reduce(timeline, _event, :rejected, edit_id, revision) do
    case Map.get(timeline.candidates, edit_id) do
      candidate when is_map(candidate) ->
        if field(candidate, :revision) == revision do
          candidates = Map.delete(timeline.candidates, edit_id)
          candidate_order = List.delete(timeline.candidate_order, edit_id)

          {:ok,
           %{
             timeline
             | candidates: candidates,
               candidate_order: candidate_order,
               current_ref: latest_committed_ref(timeline.committed_order)
           }}
        else
          {:stale, timeline}
        end

      _candidate ->
        {:stale, timeline}
    end
  end

  defp reduce(timeline, event, :snapshot_ready, edit_id, revision) do
    case Map.get(timeline.committed, edit_id) do
      committed when is_map(committed) ->
        if field(committed, :revision) == revision do
          decorated =
            committed
            |> Map.put(:phase, :snapshot_ready)
            |> Map.put(:preview_snapshot, field(event, :preview_snapshot))
            |> Map.put(:preview_snapshot_error, field(event, :preview_snapshot_error))

          {:ok, %{timeline | committed: Map.put(timeline.committed, edit_id, decorated)}}
        else
          {:stale, timeline}
        end

      _committed ->
        {:stale, timeline}
    end
  end

  defp commit(timeline, event, edit_id, revision) do
    already_committed? =
      case Map.get(timeline.committed, edit_id) do
        committed when is_map(committed) -> field(committed, :revision) == revision
        _committed -> false
      end

    committed_event =
      event
      |> atomize_phase(:committed)
      |> preserve_snapshot(Map.get(timeline.committed, edit_id), revision)

    committed_order =
      if already_committed?,
        do: timeline.committed_order,
        else: append_once(timeline.committed_order, edit_id)

    timeline = %{
      timeline
      | candidates: Map.delete(timeline.candidates, edit_id),
        candidate_order: List.delete(timeline.candidate_order, edit_id),
        committed: Map.put(timeline.committed, edit_id, committed_event),
        committed_order: committed_order,
        current_ref: {:committed, edit_id}
    }

    {:ok, timeline}
  end

  defp validate_identity(timeline, event) do
    cond do
      field(event, :turn_id) != timeline.turn_id ->
        {:error, :turn_mismatch}

      field(event, :document_id) != timeline.document_id ->
        {:error, :document_mismatch}

      true ->
        :ok
    end
  end

  defp event_phase(event) do
    case field(event, :phase) do
      phase when phase in [:candidate, :committed, :rejected, :snapshot_ready] -> {:ok, phase}
      phase -> {:error, {:invalid_phase, phase}}
    end
  end

  defp event_revision_identity(event) do
    edit_id = field(event, :edit_id)
    revision = field(event, :revision)

    if is_binary(edit_id) and edit_id != "" and is_binary(revision) and revision != "" do
      {:ok, edit_id, revision}
    else
      {:error, :missing_revision_identity}
    end
  end

  defp atomize_phase(event, phase), do: Map.put(event, :phase, phase)

  defp preserve_snapshot(event, previous, revision) when is_map(previous) do
    if field(previous, :revision) == revision do
      event
      |> Map.put(:preview_snapshot, field(previous, :preview_snapshot))
      |> Map.put(:preview_snapshot_error, field(previous, :preview_snapshot_error))
    else
      event
    end
  end

  defp preserve_snapshot(event, _previous, _revision), do: event

  defp append_once(order, edit_id), do: List.delete(order, edit_id) ++ [edit_id]

  defp latest_committed_ref([]), do: nil
  defp latest_committed_ref(order), do: {:committed, List.last(order)}

  defp highlight_position(highlight) do
    case highlight |> field(:ref) |> decoded_ref() do
      ref when is_map(ref) ->
        section = numeric_field(ref, :section, 0)
        cell = field(ref, :cell)

        paragraph =
          if is_map(cell),
            do: numeric_field(cell, :parentParaIndex, numeric_field(ref, :paragraph, 0)),
            else: numeric_field(ref, :paragraph, 0)

        {
          0,
          section,
          paragraph,
          if(is_map(cell), do: 1, else: 0),
          numeric_field(cell, :controlIndex, 0),
          numeric_field(cell, :cellIndex, 0),
          numeric_field(cell, :cellParaIndex, 0),
          numeric_field(ref, :offset, 0)
        }

      {:opaque, ref} ->
        {1, natural_ref_key(ref)}

      _ref ->
        {2, []}
    end
  end

  defp decoded_ref(ref) when is_map(ref), do: ref

  defp decoded_ref(ref) when is_binary(ref) do
    case Jason.decode(ref) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _decoded -> {:opaque, ref}
    end
  end

  defp decoded_ref(_ref), do: nil

  defp natural_ref_key(ref) do
    ~r/(\d+)/u
    |> Regex.split(ref, include_captures: true, trim: true)
    |> Enum.map(fn token ->
      case Integer.parse(token) do
        {number, ""} -> {0, number}
        _not_number -> {1, String.downcase(token)}
      end
    end)
  end

  defp numeric_field(map, key, default) when is_map(map) do
    case field(map, key, default) do
      value when is_integer(value) -> value
      _value -> default
    end
  end

  defp numeric_field(_map, _key, default), do: default

  defp canonical_term(term) when is_map(term) do
    term
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_term(value)} end)
    |> Enum.sort()
  end

  defp canonical_term(term) when is_list(term), do: Enum.map(term, &canonical_term/1)
  defp canonical_term(term), do: term

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
