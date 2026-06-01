defmodule Contract.ChatThreads do
  @moduledoc """
  Durable chat-thread operations for Studio.

  Chat threads are owner scoped and may exist without a document. Messages are
  stored as maps so tool trace messages can survive reloads without another
  schema migration.
  """

  import Ecto.Query

  alias Contract.ChatThread
  alias Contract.Command
  alias Contract.Context
  alias Contract.Repo
  alias Contract.Studio.State

  @assistant_roles MapSet.new(["assistant", "agent"])
  @default_title "Discussion"
  @title_separator " - "
  @title_summary_max 64

  @doc """
  Persists the user's chat command and returns the enriched command.

  When the command carries `payload["grill_seed"] == true` (auto-grill
  on document open), the row is persisted with role `"system"` instead
  of `"user"` so it stays out of the visible rail and the LLM history.
  See `list_visible_messages/2` and `history_for_agent/2` for the
  filters.
  """
  @spec persist_user_message(Context.t(), Command.t()) ::
          {:ok, ChatThread.t(), Command.t(), map()} | {:error, term()}
  def persist_user_message(%Context{} = ctx, %Command{kind: :chat_message} = command) do
    role = if grill_seed?(command), do: "system", else: "user"

    with {:ok, thread} <- ensure_thread(ctx, command),
         message <- build_message(role, command.message || "", command),
         {:ok, updated} <- append_message(thread, message) do
      {:ok, updated, %{command | chat_thread_id: updated.id}, message}
    end
  end

  def persist_user_message(_ctx, _command), do: {:error, :invalid_chat_command}

  defp grill_seed?(%Command{payload: payload}) when is_map(payload) do
    Map.get(payload, "grill_seed") == true or Map.get(payload, :grill_seed) == true
  end

  defp grill_seed?(_), do: false

  @doc """
  Persists a tool-call operation as a thread message so it survives page
  reloads. The MCP `instrumented/4` wrapper calls this after a successful
  or failed tool dispatch. Skipped (no-op) if `chat_thread_id` is nil
  (test/legacy tokens) — those calls remain ephemeral over PubSub only.
  """
  @spec append_tool_call_message(binary() | nil, map()) ::
          {:ok, ChatThread.t()} | :ok | {:error, term()}
  def append_tool_call_message(nil, _operation), do: :ok

  def append_tool_call_message(thread_id, operation)
      when is_binary(thread_id) and is_map(operation) do
    case Repo.get(ChatThread, thread_id) do
      %ChatThread{} = thread ->
        persisted_operation = operation_for_persistence(operation)

        message = %{
          "id" => persisted_operation["id"] || Ecto.UUID.generate(),
          "role" => "agent",
          "content" => "",
          "agent_run_id" => operation["agent_run_id"],
          "operation" => persisted_operation,
          "inserted_at" => DateTime.to_iso8601(utc_now())
        }

        append_message(thread, message)

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Persists a completed reasoning ("Thinking") summary as a thread message
  so it survives reload and `stream(:chat_messages, reset: true)`. Modelled
  on `append_tool_call_message/2` — the row carries `role: "agent"` and an
  `operation` map of type `"reasoning"`, so the chat rail rehydrates it
  through the same `operation_block` path that already renders tool calls.
  Skipped when `chat_thread_id` is nil (test/legacy) or the text is empty
  / whitespace-only.
  """
  @spec append_reasoning_message(binary() | nil, map()) ::
          {:ok, ChatThread.t()} | :ok | {:error, term()}
  def append_reasoning_message(nil, _attrs), do: :ok

  def append_reasoning_message(thread_id, %{body: body} = attrs)
      when is_binary(thread_id) and is_binary(body) do
    case String.trim(body) do
      "" ->
        :ok

      _ ->
        case Repo.get(ChatThread, thread_id) do
          %ChatThread{} = thread ->
            agent_run_id = Map.get(attrs, :agent_run_id) || Map.get(attrs, "agent_run_id")
            operation = build_reasoning_operation(agent_run_id, body)

            message = %{
              "id" => operation["id"],
              "role" => "agent",
              "content" => "",
              "agent_run_id" => agent_run_id,
              "operation" => operation,
              "inserted_at" => DateTime.to_iso8601(utc_now())
            }

            append_message(thread, message)

          nil ->
            {:error, :not_found}
        end
    end
  end

  def append_reasoning_message(_thread_id, _attrs), do: :ok

  defp build_reasoning_operation(agent_run_id, body) when is_binary(body) do
    %{
      "id" => "reasoning-#{agent_run_id || Ecto.UUID.generate()}",
      "type" => "reasoning",
      "title" => "Thinking",
      "status" => "completed",
      "summary" => reasoning_summary_line(body),
      "details" => %{"text" => body},
      "agent_run_id" => agent_run_id
    }
  end

  defp reasoning_summary_line(body) do
    body
    |> String.split(~r/\r?\n/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc "Appends an assistant-visible message to a thread."
  @spec append_assistant_message(Context.t() | nil, Command.t(), String.t() | nil) ::
          {:ok, ChatThread.t()} | :ok | {:error, term()}
  def append_assistant_message(_ctx, %Command{chat_thread_id: nil}, _content), do: :ok
  def append_assistant_message(_ctx, _command, nil), do: :ok
  def append_assistant_message(_ctx, _command, ""), do: :ok

  def append_assistant_message(ctx, %Command{} = command, content) when is_binary(content) do
    case get_thread_for_command(ctx, command) do
      {:ok, thread} ->
        message = build_message("assistant", content, command)

        with {:ok, updated} <- append_message(thread, message) do
          maybe_append_assistant_summary_to_title(updated, content)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns chat messages to seed the Studio rail for the current state.

  Filters out rows whose role is `"system"` (used by the auto-grill seed
  on document open — the seed is an instruction to the agent and must
  never surface in the visible rail).
  """
  @spec list_visible_messages(Context.t(), State.t()) :: [map()]
  def list_visible_messages(%Context{} = ctx, %State{} = state) do
    ctx
    |> visible_thread(state)
    |> case do
      nil -> []
      %ChatThread{} = thread -> thread.messages || []
    end
    |> Enum.reject(&hidden_message?/1)
    |> Enum.map(&message_for_rail(ctx, &1))
  end

  def list_visible_messages(_ctx, _state), do: []

  @doc """
  Returns metadata for the currently visible active thread.

  The chat rail uses this for its compact header. `message_count` follows
  the visible rail count, so hidden system seed messages do not make a
  fresh context look populated.
  """
  @spec current_thread_info(Context.t(), State.t()) :: map() | nil
  def current_thread_info(%Context{} = ctx, %State{} = state) do
    case visible_thread(ctx, state) do
      %ChatThread{} = thread -> thread_info(thread)
      nil -> nil
    end
  end

  def current_thread_info(_ctx, _state), do: nil

  @doc """
  Renames the currently visible active thread.

  Manual title edits are scoped to the same active thread lookup used by the
  rail header and history reads, so a user cannot rename an archived or
  different owner's conversation by posting only a title.
  """
  @spec rename_context(Context.t(), State.t(), binary()) ::
          {:ok, ChatThread.t()} | {:error, term()}
  def rename_context(%Context{user: %{id: owner_id}} = ctx, %State{} = state, title)
      when is_binary(title) do
    case visible_thread(ctx, state) do
      %ChatThread{id: thread_id} ->
        now = utc_now()
        title = normalize_title(title)

        case Repo.update_all(
               from(t in ChatThread,
                 where: t.id == ^thread_id and t.owner_id == ^owner_id and t.status == "active"
               ),
               set: [title: title, updated_at: now]
             ) do
          {1, _} -> {:ok, Repo.get!(ChatThread, thread_id)}
          {0, _} -> {:error, :not_found}
        end

      nil ->
        case state.selected_document_id do
          document_id when is_binary(document_id) ->
            create_thread(owner_id, document_id, normalize_title(title))

          nil ->
            {:error, :not_found}
        end
    end
  end

  def rename_context(_ctx, _state, _title), do: {:error, :forbidden}

  @doc """
  Archives the currently visible active thread.

  The next user message for the same document/no-document scope creates a
  fresh `chat_threads` row via `persist_user_message/2`, giving the agent
  clean conversation history without deleting audit data.
  """
  @spec reset_context(Context.t(), State.t()) :: {:ok, :archived | :noop} | {:error, term()}
  def reset_context(%Context{user: %{id: owner_id}} = ctx, %State{} = state) do
    case visible_thread(ctx, state) do
      %ChatThread{id: thread_id} ->
        now = utc_now()

        case Repo.update_all(
               from(t in ChatThread,
                 where: t.id == ^thread_id and t.owner_id == ^owner_id and t.status == "active"
               ),
               set: [status: "archived", updated_at: now]
             ) do
          {1, _} -> {:ok, :archived}
          {0, _} -> {:error, :not_found}
        end

      nil ->
        {:ok, :noop}
    end
  end

  def reset_context(_ctx, _state), do: {:error, :forbidden}

  defp hidden_message?(%{} = message) do
    role = read(message, "role") || read(message, :role)
    role == "system"
  end

  defp hidden_message?(_), do: false

  @doc "Returns messages in OpenAI input shape for an agent command."
  @spec history_for_agent(Context.t() | nil, Command.t()) :: [
          %{role: String.t(), content: String.t()}
        ]
  def history_for_agent(ctx, %Command{} = command) do
    case get_thread_for_command(ctx, command) do
      {:ok, %ChatThread{messages: messages}} ->
        messages
        |> Enum.flat_map(&history_message_for_agent/1)

      {:error, _} ->
        []
    end
  end

  defp ensure_thread(%Context{user: %{id: owner_id}} = ctx, %Command{} = command) do
    case get_thread_for_command(ctx, command) do
      {:ok, thread} -> {:ok, thread}
      {:error, :not_found} -> create_thread(owner_id, command.document_id)
      {:error, _} = error -> error
    end
  end

  defp ensure_thread(_ctx, _command), do: {:error, :forbidden}

  defp get_thread_for_command(%Context{user: %{id: owner_id}}, %Command{chat_thread_id: thread_id})
       when is_binary(thread_id) do
    case Repo.get(ChatThread, thread_id) do
      %ChatThread{owner_id: ^owner_id} = thread -> {:ok, thread}
      %ChatThread{} -> {:error, :forbidden}
      nil -> {:error, :not_found}
    end
  end

  defp get_thread_for_command(%Context{user: %{id: owner_id}}, %Command{document_id: document_id})
       when is_binary(document_id) do
    query =
      from t in ChatThread,
        where: t.owner_id == ^owner_id and t.document_id == ^document_id and t.status == "active",
        order_by: [desc: t.last_message_at, desc: t.inserted_at],
        limit: 1

    case Repo.one(query) do
      %ChatThread{} = thread -> {:ok, thread}
      nil -> {:error, :not_found}
    end
  end

  defp get_thread_for_command(%Context{user: %{id: owner_id}}, %Command{document_id: nil}) do
    query =
      from t in ChatThread,
        where: t.owner_id == ^owner_id and is_nil(t.document_id) and t.status == "active",
        order_by: [desc: t.last_message_at, desc: t.inserted_at],
        limit: 1

    case Repo.one(query) do
      %ChatThread{} = thread -> {:ok, thread}
      nil -> {:error, :not_found}
    end
  end

  defp get_thread_for_command(_ctx, _command), do: {:error, :not_found}

  defp visible_thread(%Context{user: %{id: owner_id}}, %State{selected_document_id: document_id})
       when is_binary(document_id) do
    Repo.one(
      from t in ChatThread,
        where: t.owner_id == ^owner_id and t.document_id == ^document_id and t.status == "active",
        order_by: [desc: t.last_message_at, desc: t.inserted_at],
        limit: 1
    )
  end

  defp visible_thread(%Context{user: %{id: owner_id}}, %State{selected_document_id: nil}) do
    Repo.one(
      from t in ChatThread,
        where: t.owner_id == ^owner_id and is_nil(t.document_id) and t.status == "active",
        order_by: [desc: t.last_message_at, desc: t.inserted_at],
        limit: 1
    )
  end

  defp visible_thread(_ctx, _state), do: nil

  defp create_thread(owner_id, document_id, title \\ @default_title) do
    %ChatThread{}
    |> ChatThread.changeset(%{
      owner_id: owner_id,
      document_id: document_id,
      title: title,
      messages: [],
      status: "active"
    })
    |> Repo.insert()
  end

  # Atomic append via Postgres `array_append` on the jsonb[] column.
  # The agent stream and a concurrent user submit can hit the same row in
  # overlapping transactions; read-modify-write would lose one of the
  # writes (#131). The fragment below runs inside a single UPDATE so the
  # row's `messages` column is mutated atomically by Postgres.
  defp append_message(%ChatThread{id: thread_id}, message) do
    now = utc_now()

    query =
      from t in ChatThread,
        where: t.id == ^thread_id,
        update: [
          set: [
            messages: fragment("array_append(?, ?)", t.messages, ^message),
            last_message_at: ^now,
            updated_at: ^now
          ]
        ]

    case Repo.update_all(query, []) do
      {1, _} ->
        {:ok, Repo.get!(ChatThread, thread_id)}

      {0, _} ->
        {:error, :not_found}
    end
  end

  defp maybe_append_assistant_summary_to_title(%ChatThread{} = thread, content) do
    case summarize_title(content) do
      "" ->
        {:ok, thread}

      summary ->
        title = title_base(thread.title) <> @title_separator <> summary

        if title == thread.title do
          {:ok, thread}
        else
          thread
          |> ChatThread.changeset(%{title: title})
          |> Repo.update()
        end
    end
  end

  defp thread_info(%ChatThread{} = thread) do
    %{
      id: thread.id,
      title: thread.title || @default_title,
      message_count:
        thread.messages
        |> List.wrap()
        |> Enum.reject(&hidden_message?/1)
        |> length(),
      last_message_at: thread.last_message_at
    }
  end

  defp title_base(title) when is_binary(title) do
    title
    |> String.split(@title_separator, parts: 2)
    |> List.first()
    |> case do
      nil -> @default_title
      "" -> @default_title
      base -> base
    end
  end

  defp title_base(_title), do: @default_title

  defp normalize_title(title) when is_binary(title) do
    title
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> @default_title
      title -> truncate_title(title, @title_summary_max)
    end
  end

  defp summarize_title(content) when is_binary(content) do
    content
    |> String.split(~r/\r?\n/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.replace(~r/[\*_`#>]+/, "")
    |> String.trim()
    |> String.trim_leading("- ")
    |> String.replace(~r/\s+/, " ")
    |> truncate_title(@title_summary_max)
  end

  defp summarize_title(_content), do: ""

  defp truncate_title(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  defp build_message(role, content, %Command{} = command) do
    %{
      "id" => Ecto.UUID.generate(),
      "role" => role,
      "content" => content,
      "document_id" => command.document_id,
      "agent_run_id" => command.agent_run_id,
      "inserted_at" => DateTime.to_iso8601(utc_now())
    }
  end

  defp message_for_rail(%Context{} = ctx, %{} = message) do
    role = read(message, "role") || read(message, :role) || "assistant"

    content =
      read(message, "content") || read(message, :content) || read(message, "body") ||
        read(message, :body) || ""

    %{
      id: read(message, "id") || read(message, :id) || Ecto.UUID.generate(),
      role: rail_role(role),
      body: content,
      timestamp: read(message, "inserted_at") || read(message, :inserted_at),
      operation:
        rehydrate_operation(ctx, read(message, "operation") || read(message, :operation)),
      transient?: false
    }
  end

  defp rehydrate_operation(_ctx, operation), do: operation

  defp operation_for_persistence(%{} = operation) do
    base =
      %{
        "id" => read(operation, "id") || read(operation, :id) || Ecto.UUID.generate()
      }
      |> put_if_present("name", operation_tool_kind(operation) || operation_tool_name(operation))

    cond do
      operation_failed?(operation) ->
        base
        |> put_if_present("error", operation_error(operation))

      output = operation_output(operation) ->
        base
        |> put_if_present("output", tool_output_facts(operation_tool_kind(operation), output))

      true ->
        base
    end
  end

  defp operation_failed?(%{} = operation) do
    operation_status_failed?(operation) or
      operation_has_error_output?(operation)
  end

  defp operation_status_failed?(%{} = operation),
    do: (read(operation, "status") || read(operation, :status)) == "failed"

  defp operation_error(%{} = operation) do
    output = operation_output(operation)

    cond do
      is_binary(read(operation, "error")) ->
        read(operation, "error")

      is_binary(read(operation, :error)) ->
        read(operation, :error)

      is_map(output) and is_binary(read(output, "error")) ->
        read(output, "error")

      is_map(output) and is_binary(read(output, :error)) ->
        read(output, :error)

      operation_status_failed?(operation) and is_binary(read(operation, "reason")) ->
        read(operation, "reason")

      operation_status_failed?(operation) and is_binary(read(operation, :reason)) ->
        read(operation, :reason)

      operation_status_failed?(operation) and is_binary(read(operation, "summary")) ->
        read(operation, "summary")

      operation_status_failed?(operation) and is_binary(read(operation, :summary)) ->
        read(operation, :summary)

      true ->
        nil
    end
  end

  defp operation_has_error_output?(%{} = operation) do
    output = operation_output(operation)

    is_binary(read(operation, "error")) or is_binary(read(operation, :error)) or
      (is_map(output) and (is_binary(read(output, "error")) or is_binary(read(output, :error))))
  end

  defp history_message_for_agent(%{} = message) do
    operation = read(message, "operation") || read(message, :operation)

    case operation_history_content(operation) do
      nil -> text_history_message_for_agent(message)
      content -> [%{role: "assistant", content: content}]
    end
  end

  defp history_message_for_agent(_message), do: []

  defp text_history_message_for_agent(%{} = message) do
    role = normalize_history_role(read(message, "role") || read(message, :role))

    content =
      read(message, "content") || read(message, :content) || read(message, "body") ||
        read(message, :body)

    if role && is_binary(content) && content != "" do
      [%{role: role, content: content}]
    else
      []
    end
  end

  defp operation_history_content(%{} = operation) do
    if completed_tool_operation?(operation) do
      output = operation_output(operation)

      case tool_output_facts(operation_tool_kind(operation), output) do
        nil -> nil
        facts -> tool_output_history_content(operation_tool_kind(operation), facts)
      end
    end
  end

  defp operation_history_content(_operation), do: nil

  defp completed_tool_operation?(%{} = operation) do
    type = read(operation, "type") || read(operation, :type)
    status = read(operation, "status") || read(operation, :status)

    (is_nil(type) or type == "tool_call") and
      (is_nil(status) or status == "completed") and
      not operation_failed?(operation) and
      is_map(operation_output(operation))
  end

  defp operation_details(%{} = operation),
    do: read(operation, "details") || read(operation, :details)

  defp operation_details(_operation), do: nil

  defp operation_output(%{} = operation) do
    read(operation, "output") || read(operation, :output) ||
      operation |> operation_details() |> then(&(read(&1, "output") || read(&1, :output)))
  end

  defp operation_tool_kind(%{} = operation) do
    operation
    |> operation_tool_candidates()
    |> Enum.find_value(fn
      "doc.get" ->
        "doc.get"

      "doc.read" ->
        "doc.read"

      "doc.write" ->
        "doc.write"

      value when is_binary(value) ->
        cond do
          String.ends_with?(value, ".doc.get") -> "doc.get"
          String.ends_with?(value, ".doc.read") -> "doc.read"
          String.ends_with?(value, ".doc.write") -> "doc.write"
          true -> nil
        end

      _ ->
        nil
    end)
  end

  defp operation_tool_candidates(%{} = operation) do
    [
      read(operation, "tool_name"),
      read(operation, :tool_name),
      read(operation, "name"),
      read(operation, :name),
      read(operation, "raw_name"),
      read(operation, :raw_name),
      read(operation, "title"),
      read(operation, :title)
    ]
  end

  defp operation_tool_name(%{} = operation) do
    operation
    |> operation_tool_candidates()
    |> Enum.find(&is_binary/1)
  end

  defp tool_output_facts("doc.get", %{} = output) do
    %{}
    |> put_if_present("revision", output, "revision")
    |> put_if_present("d", output, "d")
    |> put_if_present("t", output, "t")
    |> put_if_present("counts", output, "counts")
    |> non_empty_map()
  end

  defp tool_output_facts("doc.read", %{} = output) do
    %{}
    |> put_if_present("revision", output, "revision")
    |> put_if_present("sec", output, "sec")
    |> put_if_present("at", output, "at")
    |> put_if_present("items", sanitize_read_items(read(output, "items") || read(output, :items)))
    |> put_if_present("next_at", output, "next_at")
    |> non_empty_map()
  end

  defp tool_output_facts("doc.write", %{} = output) do
    %{}
    |> put_if_present("revision", output, "revision")
    |> non_empty_map()
  end

  defp tool_output_facts(_tool, _output), do: nil

  defp sanitize_read_items(items) when is_list(items) do
    Enum.map(items, fn
      %{} = item ->
        %{}
        |> put_if_present("sec", item, "sec")
        |> put_if_present("para", item, "para")
        |> put_if_present("row", item, "row")
        |> put_if_present("col", item, "col")
        |> put_if_present("text", item, "text")
        |> put_if_present("chars", item, "chars")

      _ ->
        %{}
    end)
  end

  defp sanitize_read_items(_items), do: nil

  defp put_if_present(map, key, source, source_key) when is_map(source) do
    case read(source, source_key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp non_empty_map(map) when map == %{}, do: nil
  defp non_empty_map(map), do: map

  defp tool_output_history_content(tool, facts) do
    encoded =
      case Jason.encode(facts) do
        {:ok, json} -> json
        {:error, _} -> inspect(facts)
      end

    "#{tool} facts:\n#{encoded}"
  end

  defp rail_role("user"), do: :user
  defp rail_role(role) when role in ["assistant", "agent"], do: :agent
  defp rail_role(_), do: :agent

  defp normalize_history_role("user"), do: "user"

  defp normalize_history_role(role) do
    if MapSet.member?(@assistant_roles, role), do: "assistant", else: nil
  end

  defp read(%{} = map, key), do: Map.get(map, key)
  defp read(_map, _key), do: nil

  defp utc_now, do: DateTime.utc_now(:second)
end
