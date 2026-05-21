defmodule Contract.ChatThreads do
  @moduledoc """
  Durable chat-thread operations for Studio.

  Chat threads are owner scoped and may exist without a document. Messages are
  stored as maps so later source/evidence/export workers can append structured
  operation data without another schema migration.
  """

  import Ecto.Query

  alias Contract.ChatThread
  alias Contract.Command
  alias Contract.SourceClaim
  alias Contract.Context
  alias Contract.Repo
  alias Contract.Studio.State

  @assistant_roles MapSet.new(["assistant", "agent"])

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
        message = %{
          "id" => operation["id"] || Ecto.UUID.generate(),
          "role" => "agent",
          "content" => "",
          "agent_run_id" => operation["agent_run_id"],
          "operation" => operation,
          "inserted_at" => DateTime.to_iso8601(utc_now())
        }

        append_message(thread, message)

      nil ->
        {:error, :not_found}
    end
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
        append_message(thread, message)

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
        |> Enum.flat_map(fn message ->
          role = normalize_history_role(read(message, "role") || read(message, :role))

          content =
            read(message, "content") || read(message, :content) || read(message, "body") ||
              read(message, :body)

          if role && is_binary(content) && content != "" do
            [%{role: role, content: content}]
          else
            []
          end
        end)

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

  defp create_thread(owner_id, document_id) do
    %ChatThread{}
    |> ChatThread.changeset(%{
      owner_id: owner_id,
      document_id: document_id,
      title: "Discussion",
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

  defp rehydrate_operation(%Context{} = ctx, %{"type" => "source_claim"} = operation) do
    claim_id = source_claim_id(operation)

    case claim_id && Contract.SourceClaims.get(ctx, claim_id) do
      {:ok, %SourceClaim{} = claim} -> merge_source_claim(operation, claim)
      _ -> operation
    end
  end

  defp rehydrate_operation(%Context{} = ctx, %{type: "source_claim"} = operation) do
    rehydrate_operation(ctx, stringify_keys(operation))
  end

  defp rehydrate_operation(_ctx, operation), do: operation

  defp source_claim_id(%{} = operation) do
    details = read(operation, "details") || read(operation, :details) || %{}

    read(details, "source_claim_id") || read(details, :source_claim_id) || read(operation, "id") ||
      read(operation, :id)
  end

  defp merge_source_claim(operation, %SourceClaim{} = claim) do
    details = read(operation, "details") || %{}

    details =
      Map.merge(details, %{
        "source_claim_id" => claim.id,
        "source_document_id" => claim.source_document_id,
        "proposed_kind" => claim.proposed_kind,
        "proposed_value" => claim.proposed_value,
        "proposed_structured" => claim.proposed_structured || %{},
        "user_value" => claim.user_value,
        "status" => claim.status,
        "linked_document_id" => claim.linked_document_id,
        "linked_node_id" => claim.linked_node_id,
        "confidence" => claim.confidence && Decimal.to_string(claim.confidence)
      })

    operation
    |> Map.put("status", claim.status)
    |> Map.put("details", details)
  end

  defp stringify_keys(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

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
