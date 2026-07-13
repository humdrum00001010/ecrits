defmodule Ecrits.DocumentSearch.Transition do
  @moduledoc false

  import Ecto.Changeset

  alias Ecrits.DocumentSearch

  def reset(%DocumentSearch{}), do: DocumentSearch.new()

  def open(%DocumentSearch{} = search, document_id) do
    transition(search, %{open?: true, document_id: document_id, total: nil, index: nil},
      require: [:document_id]
    )
  end

  def put_query(%DocumentSearch{} = search, query) do
    transition(search, %{query: query, total: nil, index: nil})
  end

  def close(%DocumentSearch{} = search) do
    transition(search, %{open?: false, total: nil, index: nil})
  end

  def put_result(%DocumentSearch{} = search, attrs) when is_map(attrs) do
    result = DocumentSearch.result_changeset(attrs)

    if result.valid? and search.open? and
         get_change(result, :document_id) == search.document_id and
         get_change(result, :query) == search.query do
      transition(search, %{total: get_change(result, :total), index: get_change(result, :index)})
    else
      search
    end
  end

  def put_result(%DocumentSearch{} = search, _attrs), do: search

  def command(%DocumentSearch{} = search, action, format) do
    command = DocumentSearch.command_changeset(action, format)

    if command.valid? and is_binary(search.document_id) do
      action = get_change(command, :action)
      payload = %{action: action, document_id: search.document_id, query: search.query}

      payload =
        if action == "search",
          do: Map.put(payload, :format, get_change(command, :format, "")),
          else: payload

      {:ok, payload}
    else
      :error
    end
  end

  defp transition(search, attrs, opts \\ []) do
    changeset = DocumentSearch.changeset(search, attrs)
    changeset = validate_required(changeset, Keyword.get(opts, :require, []))
    if changeset.valid?, do: apply_changes(changeset), else: search
  end
end
