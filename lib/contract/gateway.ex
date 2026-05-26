defmodule Contract.Gateway do
  @moduledoc """
  External ingress façade. Implements the SPEC.md §21 surface:

    * `issue_route_ref/2` — mint a signed, time-bounded route_ref token.
    * `verify_route_ref/2` — decode/validate a token back into a
      `%Contract.RouteRef{}`.
    * `mcp_tool/3` — dispatch an inbound MCP `tools/call` request to the
      matching `studio.*` handler.

  Slack ingress (`slack_event/1`, `slack_action/1`, `slack_command/1`) is
  intentionally NOT implemented in this build — the `/slack/*` HTTP routes
  remain on `ContractWeb.NotImplementedPlug` (501) until the Slack track
  lands. Calling the Slack functions raises with a clear message.

  ## Auth model

  Per SPEC.md §15 invariant 2: a route_ref carries durable binary_ids
  (`document_id`) only — never pids, never session refs.
  Tokens are minted with `Phoenix.Token.sign/4` against
  `ContractWeb.Endpoint` and the salt `"route_ref"`. Default TTL is 1 hour;
  callers may override via `attrs.ttl` (seconds).

  ## MCP tool dispatch

  `mcp_tool/3` is the single entrypoint that the inbound
  `ContractWeb.MCP.MCPPlug` calls. Tool handlers receive a
  `%Contract.Context{}` plus the decoded arguments and return either
  `{:ok, content_payload}` or `{:error, reason}`. The plug wraps the
  `{:ok, ...}` result into MCP `content[]` shape; this module does not
  produce JSON-RPC envelopes itself.
  """

  alias Contract.Command
  alias Contract.Context
  alias Contract.MCP
  alias Contract.RouteRef
  alias Contract.Runtime

  @salt "route_ref"
  @default_ttl 3_600

  @type route_ref_token :: String.t()

  @doc """
  Lists the MCP tool names the inbound gateway exposes. Order is stable so
  tests and external clients can rely on the index.
  """
  @spec tool_names() :: [String.t()]
  def tool_names do
    Enum.map(tools_descriptor(), & &1["name"])
  end

  @doc """
  Returns the canonical MCP `tools/list` payload -- one entry per tool with
  name, description, and JSON-schema `inputSchema`.
  """
  @spec tools_descriptor() :: [map()]
  def tools_descriptor do
    legacy_tools_descriptor() ++ MCP.expanded_tool_descriptors()
  end

  defp legacy_tools_descriptor do
    [
      %{
        "name" => "studio.search_documents",
        "description" =>
          "Search Contract Studio documents whose title or metadata matches a query string.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "studio.get_document",
        "description" => "Return the current projection of a document by id.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"document_id" => %{"type" => "string"}},
          "required" => ["document_id"]
        }
      },
      %{
        "name" => "studio.submit_action",
        "description" =>
          "Submit a Contract.Command to Runtime.apply. Use this to drive Contract Studio from external clients (rename, edit, add_mark, etc.).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "object",
              "properties" => %{
                "kind" => %{"type" => "string"},
                "document_id" => %{"type" => "string"},
                "base_revision" => %{"type" => "integer"},
                "idempotency_key" => %{"type" => "string"},
                "payload" => %{"type" => "object"},
                "message" => %{"type" => "string"}
              },
              "required" => ["kind"]
            }
          },
          "required" => ["action"]
        }
      },
      %{
        "name" => "studio.get_change_history",
        "description" =>
          "Return Changes applied to a document after `since_revision` (inclusive of revisions > since_revision).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "document_id" => %{"type" => "string"},
            "since_revision" => %{"type" => "integer", "minimum" => 0}
          },
          "required" => ["document_id"]
        }
      },
      %{
        "name" => "studio.list_marks",
        "description" => "List soft marks attached to the document's current projection.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"document_id" => %{"type" => "string"}},
          "required" => ["document_id"]
        }
      },
      %{
        "name" => "studio.search_law",
        "description" =>
          "Search Korean law via the upstream korean-law-mcp server. Passthrough wrapper.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "studio.verify_citations",
        "description" =>
          "Verify Korean law citations inside `text` via the upstream korean-law-mcp server.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"text" => %{"type" => "string"}},
          "required" => ["text"]
        }
      }
    ]
  end

  # ----------------------------------------------------------------------------
  # issue_route_ref / verify_route_ref
  # ----------------------------------------------------------------------------

  @doc """
  Mints a signed route_ref token. `attrs` may include:

    * `:document_id` — binary_id (UUID) string or nil
    * `:purpose` — string label (e.g. "slack_thread", "deep_link", "mcp")
    * `:scopes` — list of permission scopes (strings or atoms)
    * `:ttl` — integer seconds; defaults to 3600

  Returns `{:ok, token}`. Returns `{:error, :pid_in_attrs}` if any value in
  the payload is a pid or reference (regression guard for SPEC.md §15.2 —
  route_refs MUST carry only durable binary_ids).
  """
  @spec issue_route_ref(Context.t() | nil, map()) :: {:ok, route_ref_token()} | {:error, term()}
  def issue_route_ref(ctx, attrs) when is_map(attrs) do
    document_id = fetch_id(attrs, :document_id)
    purpose = Map.get(attrs, :purpose) || Map.get(attrs, "purpose") || "generic"
    scopes = Map.get(attrs, :scopes) || Map.get(attrs, "scopes") || []
    ttl = Map.get(attrs, :ttl) || Map.get(attrs, "ttl") || @default_ttl
    user_id = Map.get(attrs, :user_id) || Map.get(attrs, "user_id") || user_id(ctx)
    chat_thread_id = Map.get(attrs, :chat_thread_id) || Map.get(attrs, "chat_thread_id")
    base_revision = Map.get(attrs, :base_revision) || Map.get(attrs, "base_revision")
    agent_run_id = Map.get(attrs, :agent_run_id) || Map.get(attrs, "agent_run_id")

    bind_agent_run_id? =
      truthy?(Map.get(attrs, :bind_agent_run_id) || Map.get(attrs, "bind_agent_run_id"))

    cond do
      contains_pid_or_ref?(document_id) or contains_pid_or_ref?(agent_run_id) or
        contains_pid_or_ref?(purpose) or
          contains_pid_or_ref?(scopes) ->
        {:error, :pid_in_attrs}

      not is_integer(ttl) or ttl <= 0 ->
        {:error, :invalid_ttl}

      true ->
        with :ok <- authorize_route_ref_issue(ctx, document_id) do
          # NOTE: by default `agent_run_id`, `issued_at`, and the live wall-clock
          # `expires_at` are intentionally NOT part of the signed payload.
          # The bearer must be deterministic per
          # (user_id, document_id, chat_thread_id) so OpenAI's hosted MCP
          # `tools/list` cache (keyed by bearer) hits across agent turns
          # instead of rebuilding the catalog every first message of the
          # turn (~700ms). A nil-run bearer is not rebound to a later
          # active attempt; doc.* handlers only accept an explicit run id
          # after proving it is the active `Contract.Agent.Document`
          # attempt for the route_ref's (user, doc) scope. See
          # `Contract.RouteRef` for the design write-up.
          #
          # `Phoenix.Token.sign` normally embeds `signed_at` into the
          # token (its key-derivation nonce), which would alone defeat
          # determinism. We pin it to 0 and pin verify's max_age to
          # :infinity. Expiry is enforced by our own day-aligned
          # `expires_at` in the payload so the bearer is stable across
          # turns within the same UTC day.
          now = DateTime.utc_now()
          expires_at = day_aligned_expiry(now, ttl)

          payload =
            %{
              document_id: document_id,
              user_id: user_id,
              chat_thread_id: chat_thread_id,
              base_revision: base_revision,
              purpose: to_string(purpose),
              expires_at: DateTime.to_iso8601(expires_at),
              scopes: Enum.map(scopes, &to_string/1)
            }
            |> maybe_put_bound_agent_run_id(agent_run_id, bind_agent_run_id?)

          token = Phoenix.Token.sign(endpoint(), @salt, payload, signed_at: 0)
          {:ok, token}
        end
    end
  end

  # Round expiry up to a day boundary >= `now + ttl` so two mints of the
  # same (user, doc, thread) within the same UTC day produce byte-equal
  # tokens. For default ttl=3600 the bucket is "end of today UTC"; for
  # ttl > 86400 we keep rounding to the day after `now + ttl`.
  defp day_aligned_expiry(%DateTime{} = now, ttl) when is_integer(ttl) and ttl > 0 do
    target = DateTime.add(now, ttl, :second)

    {:ok, midnight} =
      target
      |> DateTime.to_date()
      |> Date.add(1)
      |> DateTime.new(~T[00:00:00], "Etc/UTC")

    midnight
  end

  @doc """
  Verifies a route_ref token. Returns:

    * `{:ok, %Contract.RouteRef{}}` on success.
    * `{:error, :missing}` for `nil` or empty input.
    * `{:error, :expired}` for an expired token.
    * `{:error, :invalid}` for a tampered, malformed, or otherwise invalid
      token.
  """
  @spec verify_route_ref(Context.t() | nil, route_ref_token() | nil) ::
          {:ok, RouteRef.t()} | {:error, :missing | :expired | :invalid}
  def verify_route_ref(_ctx, nil), do: {:error, :missing}
  def verify_route_ref(_ctx, ""), do: {:error, :missing}

  def verify_route_ref(_ctx, token) when is_binary(token) do
    # `max_age: :infinity` because the bearer's `signed_at` is pinned to 0
    # for determinism (see `issue_route_ref/2` notes). Expiration is
    # enforced explicitly via the payload's `expires_at` below.
    case Phoenix.Token.verify(endpoint(), @salt, token, max_age: :infinity) do
      {:ok, %{} = payload} ->
        with {:ok, expires_at} <- parse_iso(Map.get(payload, :expires_at)) do
          if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
            {:error, :expired}
          else
            {:ok,
             %RouteRef{
               document_id: Map.get(payload, :document_id),
               user_id: Map.get(payload, :user_id),
               chat_thread_id: Map.get(payload, :chat_thread_id),
               agent_run_id: Map.get(payload, :agent_run_id),
               agent_run_id_source:
                 if(is_binary(Map.get(payload, :agent_run_id)), do: :route_ref, else: nil),
               base_revision: Map.get(payload, :base_revision),
               purpose: Map.get(payload, :purpose),
               # `issued_at` is no longer in the payload; we backfill
               # with `expires_at - 1 day` so any consumer reading the
               # field still gets a sensible DateTime.
               issued_at: DateTime.add(expires_at, -86_400, :second),
               expires_at: expires_at,
               scopes: Map.get(payload, :scopes, [])
             }}
          end
        else
          _ -> {:error, :invalid}
        end

      {:error, :expired} ->
        {:error, :expired}

      {:error, _} ->
        {:error, :invalid}
    end
  end

  def verify_route_ref(_ctx, _), do: {:error, :invalid}

  defp maybe_put_bound_agent_run_id(payload, agent_run_id, true) when is_binary(agent_run_id) do
    Map.put(payload, :agent_run_id, agent_run_id)
  end

  defp maybe_put_bound_agent_run_id(payload, _agent_run_id, _bind?), do: payload

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  # ----------------------------------------------------------------------------
  # mcp_tool/3
  # ----------------------------------------------------------------------------

  @doc """
  Dispatches an inbound MCP `tools/call` to the matching `studio.*` handler.

  `ctx` is the request-scoped `%Contract.Context{}` (with `:matter` and
  `:perms` already populated from the bearer). `args` is the decoded JSON
  arguments map.

  Returns `{:ok, content_payload}` on success — the caller wraps the payload
  into the MCP `%{content: [%{type: "text", text: rendered}]}` shape.
  """
  @spec mcp_tool(Context.t() | nil, String.t(), map()) :: {:ok, term()} | {:error, term()}
  def mcp_tool(ctx, "studio.search_documents", args) do
    query = Map.get(args, "query") || Map.get(args, :query)
    limit = normalize_limit(Map.get(args, "limit") || Map.get(args, :limit), 20)

    if is_binary(query) and query != "" do
      {:ok, search_documents(ctx, query, limit)}
    else
      {:error, :invalid_query}
    end
  end

  def mcp_tool(ctx, "studio.get_document", args) do
    case fetch_doc_id(args) do
      {:ok, doc_id} ->
        with :ok <- authorize_document(ctx, doc_id),
             {:ok, state} <- Runtime.load(ctx, doc_id) do
          {:ok, render_projection(state)}
        end

      :error ->
        {:error, :missing_document_id}
    end
  end

  def mcp_tool(ctx, "studio.submit_action", args) do
    raw = Map.get(args, "action") || Map.get(args, :action) || args

    with {:ok, action} <- build_action(raw),
         :ok <- authorize_document(ctx, action.document_id) do
      case Runtime.apply(ctx, action) do
        {:ok, result} -> {:ok, render_action_result(result)}
        {:error, _} = err -> err
      end
    end
  end

  def mcp_tool(ctx, "studio.get_change_history", args) do
    case fetch_doc_id(args) do
      {:ok, doc_id} ->
        with :ok <- authorize_document(ctx, doc_id) do
          since = Map.get(args, "since_revision") || Map.get(args, :since_revision) || 0

          case Runtime.sync_since(ctx, doc_id, since) do
            {:ok, changes} ->
              {:ok, %{document_id: doc_id, changes: Enum.map(changes, &render_change/1)}}

            {:error, _} = err ->
              err
          end
        end

      :error ->
        {:error, :missing_document_id}
    end
  end

  def mcp_tool(ctx, "studio.list_marks", args) do
    case fetch_doc_id(args) do
      {:ok, doc_id} ->
        with :ok <- authorize_document(ctx, doc_id),
             {:ok, state} <- Runtime.load(ctx, doc_id) do
          marks =
            state.projection
            |> Map.get(:marks, %{})
            |> Map.values()

          {:ok, %{document_id: doc_id, marks: marks}}
        end

      :error ->
        {:error, :missing_document_id}
    end
  end

  def mcp_tool(ctx, "studio.search_law", args) do
    query = Map.get(args, "query") || Map.get(args, :query)
    limit = Map.get(args, "limit") || Map.get(args, :limit)
    opts = if is_integer(limit), do: [limit: limit], else: []

    if is_binary(query) and query != "" do
      Contract.Providers.search_law(ctx, query, opts)
    else
      {:error, :invalid_query}
    end
  end

  def mcp_tool(ctx, "studio.verify_citations", args) do
    text = Map.get(args, "text") || Map.get(args, :text)

    if is_binary(text) and text != "" do
      Contract.Providers.verify_citation(ctx, text, [])
    else
      {:error, :invalid_text}
    end
  end

  def mcp_tool(ctx, tool, args) do
    if tool in MCP.expanded_tool_names() do
      route_ref = ctx && Map.get(ctx.perms || %{}, :route_ref)
      MCP.call_tool(ctx, route_ref, tool, args)
    else
      {:error, {:unknown_tool, tool}}
    end
  end

  # ----------------------------------------------------------------------------
  # Slack — explicitly not implemented in this build
  # ----------------------------------------------------------------------------

  @spec slack_event(map()) :: no_return()
  def slack_event(_payload),
    do: raise("Contract.Gateway.slack_event/1: Slack ingress is out of scope for this build")

  @spec slack_action(map()) :: no_return()
  def slack_action(_payload),
    do: raise("Contract.Gateway.slack_action/1: Slack ingress is out of scope for this build")

  @spec slack_command(map()) :: no_return()
  def slack_command(_payload),
    do: raise("Contract.Gateway.slack_command/1: Slack ingress is out of scope for this build")

  # ----------------------------------------------------------------------------
  # internals
  # ----------------------------------------------------------------------------

  defp endpoint, do: ContractWeb.Endpoint

  defp user_id(%Context{user: %{id: id}}), do: id
  defp user_id(_ctx), do: nil

  defp fetch_id(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp authorize_route_ref_issue(_ctx, nil), do: :ok

  defp authorize_route_ref_issue(%Context{} = ctx, document_id) when is_binary(document_id) do
    case Contract.Documents.get(ctx, document_id) do
      {:ok, _doc} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_route_ref_issue(_ctx, _document_id), do: {:error, :forbidden}

  defp parse_iso(nil), do: {:error, :missing}

  defp parse_iso(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      {:error, _} -> {:error, :invalid}
    end
  end

  defp parse_iso(_), do: {:error, :invalid}

  defp contains_pid_or_ref?(value)
  defp contains_pid_or_ref?(pid) when is_pid(pid), do: true
  defp contains_pid_or_ref?(ref) when is_reference(ref), do: true
  defp contains_pid_or_ref?(port) when is_port(port), do: true
  defp contains_pid_or_ref?(fun) when is_function(fun), do: true

  defp contains_pid_or_ref?(list) when is_list(list),
    do: Enum.any?(list, &contains_pid_or_ref?/1)

  defp contains_pid_or_ref?(map) when is_map(map) do
    Enum.any?(map, fn {k, v} -> contains_pid_or_ref?(k) or contains_pid_or_ref?(v) end)
  end

  defp contains_pid_or_ref?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&contains_pid_or_ref?/1)

  defp contains_pid_or_ref?(_), do: false

  defp normalize_limit(limit, _default) when is_integer(limit) and limit > 0 and limit <= 100,
    do: limit

  defp normalize_limit(limit, default) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 and n <= 100 -> n
      _ -> default
    end
  end

  defp normalize_limit(_, default), do: default

  defp fetch_doc_id(args) do
    case Map.get(args, "document_id") || Map.get(args, :document_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> :error
    end
  end

  # ---- scope enforcement -----------------------------------------------------

  @doc false
  @spec authorize_document(Context.t() | nil, binary() | nil) :: :ok | {:error, :forbidden}
  def authorize_document(_ctx, nil), do: {:error, :forbidden}

  def authorize_document(%Context{} = ctx, doc_id) when is_binary(doc_id) do
    case Map.get(ctx.perms || %{}, :route_ref) do
      %RouteRef{document_id: nil} ->
        authorize_visible_document(ctx, doc_id)

      %RouteRef{document_id: ^doc_id} ->
        authorize_pinned_document(ctx, doc_id)

      %RouteRef{} ->
        {:error, :forbidden}

      _ ->
        case ctx.user do
          nil ->
            {:error, :forbidden}

          _ ->
            case Contract.Documents.get(ctx, doc_id) do
              {:ok, _doc} -> :ok
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  def authorize_document(_ctx, _doc_id), do: {:error, :forbidden}

  defp authorize_visible_document(%Context{} = ctx, doc_id) do
    case Contract.Documents.get(ctx, doc_id) do
      {:ok, _doc} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_pinned_document(%Context{} = ctx, doc_id),
    do: authorize_visible_document(ctx, doc_id)

  # ---- search ----------------------------------------------------------------

  defp search_documents(ctx, query, limit) do
    matches =
      ctx
      |> Contract.Documents.search(query, limit)
      |> Enum.map(fn doc ->
        %{document_id: doc.id, title: doc.title, revision: doc.latest_revision}
      end)

    %{query: query, count: length(matches), results: matches}
  end

  defp render_projection(%Contract.Runtime.State{} = state) do
    %{
      document_id: state.document_id,
      revision: state.revision,
      projection: state.projection
    }
  end

  defp render_change(%Contract.Change{} = c) do
    %{
      id: c.id,
      document_id: c.document_id,
      command_kind: c.command_kind,
      base_revision: c.base_revision,
      result_revision: c.result_revision,
      status: c.status,
      actor_type: c.actor_type,
      actor_id: c.actor_id,
      message: c.message,
      inserted_at: c.inserted_at
    }
  end

  defp render_action_result(%Contract.Change{} = c), do: render_change(c)
  defp render_action_result(%Contract.Runtime.State{} = s), do: render_projection(s)
  defp render_action_result(other), do: %{result: inspect(other)}

  defp build_action(raw) when is_map(raw) do
    attrs = %{
      kind: parse_atom(Map.get(raw, "kind") || Map.get(raw, :kind), valid_command_kinds()),
      document_id: Map.get(raw, "document_id") || Map.get(raw, :document_id),
      change_id: Map.get(raw, "change_id") || Map.get(raw, :change_id),
      agent_run_id: Map.get(raw, "agent_run_id") || Map.get(raw, :agent_run_id),
      actor_type:
        parse_atom(
          Map.get(raw, "actor_type") || Map.get(raw, :actor_type) || "user",
          [:user, :agent, :lawyer, :slack, :system]
        ),
      actor_id: Map.get(raw, "actor_id") || Map.get(raw, :actor_id),
      base_revision: Map.get(raw, "base_revision") || Map.get(raw, :base_revision),
      idempotency_key:
        Map.get(raw, "idempotency_key") || Map.get(raw, :idempotency_key) ||
          "mcp-#{System.unique_integer([:positive])}",
      payload: Map.get(raw, "payload") || Map.get(raw, :payload) || %{},
      message: Map.get(raw, "message") || Map.get(raw, :message)
    }

    changeset = Command.changeset(%Command{}, attrs)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, {:invalid_action, errors_on(changeset)}}
    end
  end

  defp build_action(_), do: {:error, :invalid_action_payload}

  defp parse_atom(value, allowed) when is_atom(value) do
    if value in allowed, do: value, else: nil
  end

  defp parse_atom(value, allowed) when is_binary(value) do
    Enum.find(allowed, fn a -> Atom.to_string(a) == value end)
  end

  defp parse_atom(_, _), do: nil

  defp valid_command_kinds do
    [
      :open_document,
      :create_document,
      :upload_document,
      :duplicate_document,
      :archive_document,
      :restore_document,
      :rename_document,
      :update_metadata,
      :set_contract_type,
      :edit_document,
      :add_mark,
      :update_mark,
      :start_type_conversion,
      :set_field_migration_strategy,
      :create_converted_variant,
      :chat_message,
      :agent_change,
      :revoke_change,
      :resolve_revoke,
      :request_export
    ]
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
