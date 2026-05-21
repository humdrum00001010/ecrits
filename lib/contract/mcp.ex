defmodule Contract.MCP do
  @moduledoc """
  MCP resource and tool surface for Contract Studio.

  This module owns the v0.5 MCP contract shape. It delegates durable document
  mutations to `Contract.Runtime` via `Contract.Command` and gates reads through
  owner ACL before exposing projections as MCP resources.
  """

  import Ecto.Query

  alias Contract.Change
  alias Contract.Command
  alias Contract.Context
  alias Contract.Documents
  alias Contract.EvidenceSnapshot
  alias Contract.Gateway
  alias Contract.Providers
  alias Contract.Repo
  alias Contract.RouteRef
  alias Contract.Runtime
  alias Contract.SourceClaim
  alias Contract.SourceDocument

  def expanded_tool_descriptors do
    agent_doc_tool_descriptors() ++ legacy_expanded_tool_descriptors()
  end

  # Agent-facing tool surface (the 6-tool MVP used by Contract.Agent.RunServer
  # over an authenticated MCP route_ref). These are deliberately opinionated:
  # the model gets short, positional args instead of having to construct full
  # Command JSON via `document.submit_command`. See docs/plans for the
  # full design rationale.
  defp agent_doc_tool_descriptors do
    [
      %{
        "name" => "doc.get",
        "description" =>
          "Returns a presigned HTTPS URL pointing at the agent IR JSON in R2. Fetch the URL via GET to retrieve the document state. URL is valid for ~1 hour. Pin `since_revision` to the last `revision` you received to short-circuit when nothing changed.",
        "inputSchema" =>
          object_schema(
            %{"since_revision" => %{"type" => "integer", "minimum" => 0}},
            []
          )
      },
      %{
        "name" => "doc.edit_text",
        "description" =>
          "Replace a character range inside one paragraph or table cell. `len=0` is pure insert, `text=\"\"` is pure delete, both nonzero is replace. For table cells, pass `cell_path` (controlIndex/cellIndex/cellParaIndex tuples) from doc.get. Pin `base_revision` to the value last seen.",
        "inputSchema" =>
          object_schema(
            %{
              "sec" => %{"type" => "integer", "minimum" => 0},
              "para" => %{"type" => "integer", "minimum" => 0},
              "off" => %{"type" => "integer", "minimum" => 0},
              "len" => %{"type" => "integer", "minimum" => 0},
              "text" => %{"type" => "string"},
              "cell_path" => cell_path_schema(),
              "base_revision" => %{"type" => "integer", "minimum" => 0}
            },
            ["sec", "para", "off", "len", "text"]
          )
      },
      %{
        "name" => "doc.insert_block",
        "description" =>
          "Insert a new block (paragraph, heading, list_item, or table) at sec:para. For heading, pass `level` 1–6. For table, pass `rows`/`cols` (and optional `header_row_count`) instead of `text`.",
        "inputSchema" =>
          object_schema(
            %{
              "sec" => %{"type" => "integer", "minimum" => 0},
              "para" => %{"type" => "integer", "minimum" => 0},
              "kind" => %{
                "type" => "string",
                "enum" => ["paragraph", "heading", "list_item", "table"]
              },
              "text" => %{"type" => "string"},
              "level" => %{"type" => "integer", "minimum" => 1, "maximum" => 6},
              "rows" => %{"type" => "integer", "minimum" => 1},
              "cols" => %{"type" => "integer", "minimum" => 1},
              "header_row_count" => %{"type" => "integer", "minimum" => 0},
              "base_revision" => %{"type" => "integer", "minimum" => 0}
            },
            ["sec", "para", "kind"]
          )
      },
      %{
        "name" => "doc.delete_block",
        "description" =>
          "Delete the block (paragraph, heading, list_item, or table) at sec:para.",
        "inputSchema" =>
          object_schema(
            %{
              "sec" => %{"type" => "integer", "minimum" => 0},
              "para" => %{"type" => "integer", "minimum" => 0},
              "base_revision" => %{"type" => "integer", "minimum" => 0}
            },
            ["sec", "para"]
          )
      },
      %{
        "name" => "doc.edit_table",
        "description" =>
          "Structural table edits: insert or delete a row or column. For cell text edits use doc.edit_text with cell_path instead.",
        "inputSchema" =>
          object_schema(
            %{
              "sec" => %{"type" => "integer", "minimum" => 0},
              "para" => %{"type" => "integer", "minimum" => 0},
              "control_index" => %{"type" => "integer", "minimum" => 0},
              "op" => %{
                "type" => "string",
                "enum" => ["row_insert", "row_delete", "col_insert", "col_delete"]
              },
              "at_row" => %{"type" => "integer", "minimum" => 0},
              "at_col" => %{"type" => "integer", "minimum" => 0},
              "base_revision" => %{"type" => "integer", "minimum" => 0}
            },
            ["sec", "para", "op"]
          )
      },
      %{
        "name" => "doc.set_field_value",
        "description" =>
          "Set the value of a tracked field (slot) by its field id from doc.get's `f` list. Server lowers to the right text edit using the field's tracked position.",
        "inputSchema" =>
          object_schema(
            %{
              "id" => string_schema(),
              "value" => %{"type" => "string"},
              "base_revision" => %{"type" => "integer", "minimum" => 0}
            },
            ["id", "value"]
          )
      }
    ]
  end

  defp cell_path_schema do
    %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "controlIndex" => %{"type" => "integer", "minimum" => 0},
          "cellIndex" => %{"type" => "integer", "minimum" => 0},
          "cellParaIndex" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["controlIndex", "cellIndex", "cellParaIndex"]
      }
    }
  end

  defp legacy_expanded_tool_descriptors do
    [
      %{
        "name" => "document.open",
        "description" => "Open a document and return its current state projection.",
        "inputSchema" => object_schema(%{"document_id" => string_schema()}, ["document_id"])
      },
      %{
        "name" => "document.read",
        "description" =>
          "Read a document MCP resource such as state, outline, nodes, fields, changes, revokes, or marks.",
        "inputSchema" =>
          object_schema(%{"document_id" => string_schema(), "resource" => string_schema()}, [
            "document_id"
          ])
      },
      %{
        "name" => "document.search",
        "description" => "Search documents visible to the current owner scope.",
        "inputSchema" =>
          object_schema(%{"query" => string_schema(), "limit" => integer_schema(1, 100)}, [
            "query"
          ])
      },
      %{
        "name" => "document.submit_command",
        "description" =>
          "Normalize arguments into a Contract.Command and submit through Runtime.",
        "inputSchema" => object_schema(%{"command" => %{"type" => "object"}}, ["command"])
      },
      %{
        "name" => "document.revoke_change",
        "description" => "Emit a revoke_change Command for a document change.",
        "inputSchema" =>
          object_schema(%{"document_id" => string_schema(), "change_id" => string_schema()}, [
            "document_id",
            "change_id"
          ])
      },
      %{
        "name" => "source_document.read",
        "description" => "Read an owner-scoped source document resource.",
        "inputSchema" =>
          object_schema(%{"source_document_id" => string_schema()}, ["source_document_id"])
      },
      %{
        "name" => "source_document.search_regions",
        "description" => "Search parsed source document regions by text.",
        "inputSchema" =>
          object_schema(%{"source_document_id" => string_schema(), "query" => string_schema()}, [
            "source_document_id",
            "query"
          ])
      },
      %{
        "name" => "source_document.propose_claims",
        "description" =>
          "Request source-claim proposal for a source document when the source pipeline is available.",
        "inputSchema" =>
          object_schema(%{"source_document_id" => string_schema()}, ["source_document_id"])
      },
      source_claim_tool(
        "source_document.confirm_claim",
        "Confirm a proposed source claim.",
        "source_claim_confirm"
      ),
      source_claim_tool(
        "source_document.correct_claim",
        "Correct a proposed source claim.",
        "source_claim_correct"
      ),
      source_claim_tool(
        "source_document.reject_claim",
        "Reject a proposed source claim.",
        "source_claim_reject"
      ),
      source_claim_tool(
        "source_document.link_claim_to_document",
        "Link a source claim to a working document.",
        "source_claim_link_to_document"
      ),
      %{
        "name" => "law.search",
        "description" => "Search legal provider records.",
        "inputSchema" =>
          object_schema(%{"query" => string_schema(), "limit" => integer_schema(1, 50)}, ["query"])
      },
      %{
        "name" => "law.get_text",
        "description" => "Fetch full law text from the legal provider.",
        "inputSchema" => object_schema(%{"law_ref" => string_schema()}, ["law_ref"])
      },
      %{
        "name" => "law.search_precedents",
        "description" => "Search precedent records through the legal provider.",
        "inputSchema" =>
          object_schema(%{"query" => string_schema(), "limit" => integer_schema(1, 50)}, ["query"])
      },
      %{
        "name" => "law.verify_citation",
        "description" => "Verify legal citations through the legal provider.",
        "inputSchema" => object_schema(%{"citation" => string_schema()}, ["citation"])
      },
      %{
        "name" => "evidence.attach_mark",
        "description" =>
          "Attach a mark to a legal evidence snapshot by emitting an add_mark Command.",
        "inputSchema" =>
          object_schema(
            %{
              "evidence_id" => string_schema(),
              "document_id" => string_schema(),
              "text" => string_schema()
            },
            ["evidence_id", "text"]
          )
      },
      %{
        "name" => "collab.ask_user",
        "description" =>
          "Request user clarification through a collaboration channel when available.",
        "inputSchema" => object_schema(%{"prompt" => string_schema()}, ["prompt"])
      },
      %{
        "name" => "collab.fetch_slack_context",
        "description" => "Fetch Slack thread context when Slack integration is available.",
        "inputSchema" => object_schema(%{"thread_id" => string_schema()}, ["thread_id"])
      }
    ]
  end

  @document_resource_kinds ["state", "outline", "nodes", "fields", "changes", "revokes", "marks"]

  @doc "Returns the MCP initialize result payload."
  def initialize(_payload) do
    %{
      "protocolVersion" => "2024-11-05",
      "serverInfo" => %{"name" => "contract-studio", "version" => "0.5.0"},
      "capabilities" => %{
        "tools" => %{"listChanged" => false},
        "resources" => %{"listChanged" => false}
      }
    }
  end

  @doc "Expanded v0.5 tool names."
  def expanded_tool_names, do: Enum.map(expanded_tool_descriptors(), & &1["name"])

  @doc "Returns the complete MCP tools/list payload."
  def list_tools(_ctx, _route_ref), do: %{"tools" => Gateway.tools_descriptor()}

  @doc "Returns concrete resources visible to the current owner scope."
  def list_resources(%Context{} = ctx, _route_ref) do
    resources =
      document_resources(ctx) ++ source_document_resources(ctx) ++ evidence_resources(ctx)

    %{"resources" => resources}
  end

  def list_resources(_ctx, _route_ref), do: %{"resources" => []}

  @doc "Reads a concrete MCP resource URI."
  def read_resource(%Context{} = ctx, route_ref, uri) when is_binary(uri) do
    cond do
      String.starts_with?(uri, "source_document://") ->
        with {:ok, id, path} <- parse_custom_uri(uri, "source_document://") do
          read_source_resource(ctx, route_ref, id, path, uri)
        end

      String.starts_with?(uri, "chat_thread://") ->
        {:error, {:not_available, "chat_thread resources are not implemented yet"}}

      String.starts_with?(uri, "tool_call://") ->
        {:error, {:not_available, "tool_call resources are not implemented yet"}}

      true ->
        case URI.parse(uri) do
          %URI{scheme: "document", host: document_id, path: path} when is_binary(document_id) ->
            read_document_resource(ctx, route_ref, document_id, normalize_path(path), uri)

          %URI{scheme: "evidence", host: evidence_id, path: path} when is_binary(evidence_id) ->
            read_evidence_resource(ctx, route_ref, evidence_id, normalize_path(path), uri)

          %URI{scheme: "export"} ->
            {:error, {:not_available, "export resources are not implemented yet"}}

          _ ->
            {:error, :invalid_uri}
        end
    end
  end

  def read_resource(_ctx, _route_ref, _uri), do: {:error, :invalid_uri}

  @doc "Calls an MCP tool by name. Mutating document tools emit Commands."

  # --- agent-facing doc.* tools (6-tool MVP) --------------------------------
  # Real handlers for doc.get + doc.edit_text land in #116 (the vertical
  # slice). The remaining four stay stubbed until #120.
  def call_tool(%Context{} = ctx, route_ref, "doc.get" = tool, args) do
    route_ref = resolve_agent_run_id(route_ref)

    instrumented(route_ref, tool, args, fn ->
      with :ok <- authorize_doc_mcp(route_ref),
           {:ok, document_id} <- resolve_document_id(route_ref, args),
           :ok <- authorize_route_ref_strict(route_ref, document_id),
           :ok <- Gateway.authorize_document(ctx, document_id),
           {:ok, %Runtime.State{} = state} <- Runtime.load(ctx, document_id) do
        since = Map.get(args, "since_revision") || Map.get(args, :since_revision)

        cond do
          is_integer(since) and since >= state.revision ->
            {:ok, %{"ok" => true, "unchanged" => true, "revision" => state.revision}}

          true ->
            compact =
              state
              |> Contract.MCP.Projection.to_agent_ir()
              |> Contract.Agent.Prompt.IRRenderer.compact_map()

            # Splice revision so the agent can pin base_revision on follow-up edits.
            {:ok, Map.put(compact, "revision", state.revision)}
        end
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.get", _args), do: {:error, :forbidden}

  def call_tool(%Context{} = ctx, route_ref, "doc.edit_text" = tool, args) do
    # Task #139 — resolve the per-turn run id from the scope registry
    # since the route_ref bearer no longer carries it. The resolved id
    # is splatted onto the struct (in-memory only, never re-signed) so
    # downstream helpers (instrumented/4, build_command/3) see a
    # uniform shape regardless of whether they're called by an agent
    # turn or by a legacy non-agent caller.
    route_ref = resolve_agent_run_id(route_ref)

    instrumented(route_ref, tool, args, fn ->
      with :ok <- authorize_doc_mcp(route_ref),
           {:ok, document_id} <- resolve_document_id(route_ref, args),
           :ok <- authorize_route_ref_strict(route_ref, document_id),
           {:ok, ops} <- edit_text_ops(args) do
        run_id = route_ref && Map.get(route_ref, :agent_run_id)

        command_args = %{
          "kind" => "edit_text",
          "document_id" => document_id,
          "actor_type" => actor_type_for(route_ref),
          "actor_id" => user_id(ctx) || (route_ref && Map.get(route_ref, :user_id)),
          "agent_run_id" => run_id,
          "base_revision" => Map.get(args, "base_revision") || Map.get(args, :base_revision),
          "idempotency_key" => mcp_idempotency_key(run_id, "edit_text", args),
          "payload" => %{"ops" => ops}
        }

        with {:ok, command} <- build_command(ctx, route_ref, command_args),
             :ok <- authorize_command(ctx, route_ref, command),
             {:ok, %Contract.Change{} = change} <- Runtime.apply(ctx, command) do
          {:ok,
           %{
             "ok" => true,
             "revision" => change.result_revision,
             "applied" => "edit_text",
             "change_id" => change.id
           }}
        end
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.edit_text", _args), do: {:error, :forbidden}

  def call_tool(%Context{} = ctx, route_ref, "doc.insert_block" = tool, args) do
    route_ref = resolve_agent_run_id(route_ref)

    instrumented(route_ref, tool, args, fn ->
      with :ok <- authorize_doc_mcp(route_ref),
           {:ok, document_id} <- resolve_document_id(route_ref, args),
           :ok <- authorize_route_ref_strict(route_ref, document_id),
           {:ok, ops} <- insert_block_ops(args) do
        submit_edit_text(ctx, route_ref, document_id, args, ops, "insert_block")
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.insert_block", _args), do: {:error, :forbidden}

  def call_tool(%Context{} = ctx, route_ref, "doc.delete_block" = tool, args) do
    route_ref = resolve_agent_run_id(route_ref)

    instrumented(route_ref, tool, args, fn ->
      with :ok <- authorize_doc_mcp(route_ref),
           {:ok, document_id} <- resolve_document_id(route_ref, args),
           :ok <- authorize_route_ref_strict(route_ref, document_id),
           {:ok, ops} <- delete_block_ops(args) do
        submit_edit_text(ctx, route_ref, document_id, args, ops, "delete_block")
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.delete_block", _args), do: {:error, :forbidden}

  def call_tool(%Context{} = ctx, route_ref, "doc.edit_table" = tool, args) do
    route_ref = resolve_agent_run_id(route_ref)

    instrumented(route_ref, tool, args, fn ->
      with :ok <- authorize_doc_mcp(route_ref),
           {:ok, document_id} <- resolve_document_id(route_ref, args),
           :ok <- authorize_route_ref_strict(route_ref, document_id),
           {:ok, ops} <- edit_table_ops(args) do
        submit_edit_text(ctx, route_ref, document_id, args, ops, "edit_table")
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.edit_table", _args), do: {:error, :forbidden}

  def call_tool(%Context{} = ctx, route_ref, "doc.set_field_value" = tool, args) do
    route_ref = resolve_agent_run_id(route_ref)

    instrumented(route_ref, tool, args, fn ->
      with :ok <- authorize_doc_mcp(route_ref),
           {:ok, document_id} <- resolve_document_id(route_ref, args),
           :ok <- authorize_route_ref_strict(route_ref, document_id),
           :ok <- Gateway.authorize_document(ctx, document_id),
           {:ok, %Runtime.State{} = state} <- Runtime.load(ctx, document_id),
           {:ok, ops} <- set_field_value_ops(args, state) do
        submit_edit_text(ctx, route_ref, document_id, args, ops, "set_field_value")
      end
    end)
  end

  def call_tool(_ctx, _route_ref, "doc.set_field_value", _args), do: {:error, :forbidden}

  def call_tool(ctx, route_ref, "document.open", args),
    do: call_tool(ctx, route_ref, "document.read", args)

  def call_tool(ctx, route_ref, "document.read", args) do
    with {:ok, document_id} <- fetch_arg(args, "document_id"),
         resource <- Map.get(args, "resource") || Map.get(args, :resource) || "state" do
      read_resource(ctx, route_ref, "document://#{document_id}/#{resource}")
    end
  end

  def call_tool(%Context{} = ctx, _route_ref, "document.search", args) do
    query = Map.get(args, "query") || Map.get(args, :query)
    limit = normalize_limit(Map.get(args, "limit") || Map.get(args, :limit), 20)

    if is_binary(query) and query != "" do
      results =
        ctx
        |> Documents.search(query, limit)
        |> Enum.map(fn doc ->
          %{
            "document_id" => doc.id,
            "title" => doc.title,
            "type_key" => doc.type_key,
            "status" => atom_to_string(doc.status),
            "latest_revision" => doc.latest_revision
          }
        end)

      {:ok, %{"query" => query, "count" => length(results), "results" => results}}
    else
      {:error, :invalid_query}
    end
  end

  def call_tool(%Context{} = ctx, route_ref, "document.submit_command", args) do
    raw = Map.get(args, "command") || Map.get(args, :command) || args

    with {:ok, command} <- build_command(ctx, route_ref, raw),
         :ok <- authorize_command(ctx, route_ref, command),
         {:ok, result} <- Runtime.apply(ctx, command) do
      {:ok, render_result(result)}
    end
  end

  def call_tool(ctx, route_ref, "document.revoke_change", args) do
    raw =
      args
      |> Map.put_new("kind", "revoke_change")
      |> Map.put_new("command", nil)

    command_args = Map.get(args, "command") || Map.get(args, :command) || raw
    call_tool(ctx, route_ref, "document.submit_command", %{"command" => command_args})
  end

  def call_tool(ctx, route_ref, "source_document.read", args) do
    with {:ok, id} <- fetch_arg(args, "source_document_id") do
      read_resource(ctx, route_ref, "source_document://#{id}")
    end
  end

  def call_tool(%Context{} = ctx, route_ref, "source_document.search_regions", args) do
    with {:ok, id} <- fetch_arg(args, "source_document_id"),
         {:ok, %SourceDocument{} = source} <- get_source_document(ctx, route_ref, id) do
      query = String.downcase(to_string(Map.get(args, "query") || Map.get(args, :query) || ""))

      regions =
        source.regions
        |> List.wrap()
        |> Enum.filter(fn region ->
          query == "" or String.contains?(String.downcase(inspect(region)), query)
        end)

      {:ok, %{"source_document_id" => id, "regions" => regions}}
    end
  end

  def call_tool(ctx, route_ref, "source_document.propose_claims", args) do
    with {:ok, id} <- fetch_arg(args, "source_document_id"),
         {:ok, _source} <- get_source_document(ctx, route_ref, id) do
      {:ok,
       not_available(
         "source_document.propose_claims",
         "source interpretation pipeline is not available yet"
       )}
    end
  end

  def call_tool(ctx, route_ref, tool, args)
      when tool in [
             "source_document.confirm_claim",
             "source_document.correct_claim",
             "source_document.reject_claim",
             "source_document.link_claim_to_document"
           ] do
    kind =
      case tool do
        "source_document.confirm_claim" -> "source_claim_confirm"
        "source_document.correct_claim" -> "source_claim_correct"
        "source_document.reject_claim" -> "source_claim_reject"
        "source_document.link_claim_to_document" -> "source_claim_link_to_document"
      end

    raw = args |> Map.put("kind", kind)

    with {:ok, command} <- build_command(ctx, route_ref, raw),
         :ok <- authorize_command(ctx, route_ref, command),
         {:ok, result} <- Runtime.apply(ctx, command) do
      {:ok, render_result(result)}
    end
  end

  def call_tool(ctx, _route_ref, "law.search", args) do
    with {:ok, query} <- fetch_arg(args, "query") do
      limit = normalize_limit(Map.get(args, "limit") || Map.get(args, :limit), 10)
      Providers.search_law(ctx, query, limit: limit)
    end
  end

  def call_tool(ctx, _route_ref, "law.get_text", args) do
    with {:ok, law_ref} <- fetch_arg(args, "law_ref") do
      Providers.get_law_text(ctx, law_ref, [])
    end
  end

  def call_tool(ctx, _route_ref, "law.search_precedents", args) do
    with {:ok, query} <- fetch_arg(args, "query") do
      limit = normalize_limit(Map.get(args, "limit") || Map.get(args, :limit), 10)
      Providers.search_precedents(ctx, query, limit: limit)
    end
  end

  def call_tool(ctx, _route_ref, "law.verify_citation", args) do
    citation = Map.get(args, "citation") || Map.get(args, :citation) || Map.get(args, "text")

    if is_binary(citation) and citation != "" do
      Providers.verify_citation(ctx, citation, [])
    else
      {:error, :invalid_text}
    end
  end

  def call_tool(%Context{} = ctx, route_ref, "evidence.attach_mark", args) do
    with {:ok, evidence_id} <- fetch_arg(args, "evidence_id"),
         {:ok, %EvidenceSnapshot{} = evidence} <- get_evidence(ctx, route_ref, evidence_id) do
      document_id =
        Map.get(args, "document_id") || Map.get(args, :document_id) || evidence.document_id

      text = Map.get(args, "text") || Map.get(args, :text) || "Evidence note"

      command_args = %{
        "kind" => "add_mark",
        "document_id" => document_id,
        "base_revision" => Map.get(args, "base_revision") || Map.get(args, :base_revision),
        "idempotency_key" =>
          Map.get(args, "idempotency_key") || "mcp-evidence-mark-#{evidence_id}",
        "payload" => %{
          "target_type" => "evidence",
          "target_id" => evidence_id,
          "intent" => Map.get(args, "intent") || "link",
          "text" => text,
          "data" => %{"evidence_id" => evidence_id}
        }
      }

      call_tool(ctx, route_ref, "document.submit_command", %{"command" => command_args})
    end
  end

  def call_tool(_ctx, _route_ref, "collab.ask_user", _args),
    do:
      {:ok,
       not_available("collab.ask_user", "collaboration prompt delivery is not available yet")}

  def call_tool(_ctx, _route_ref, "collab.fetch_slack_context", _args),
    do: {:ok, not_available("collab.fetch_slack_context", "Slack context is not available yet")}

  def call_tool(_ctx, _route_ref, tool, _args), do: {:error, {:unknown_tool, tool}}

  defp read_document_resource(ctx, route_ref, document_id, kind, uri)
       when kind in @document_resource_kinds do
    with :ok <- authorize_route_ref(route_ref, document_id),
         :ok <- Gateway.authorize_document(ctx, document_id),
         {:ok, state} <- Runtime.load(ctx, document_id),
         {:ok, body} <- document_resource_body(ctx, state, kind) do
      {:ok, resource_contents(uri, body)}
    end
  end

  defp read_document_resource(_ctx, _route_ref, _document_id, _kind, _uri),
    do: {:error, :invalid_uri}

  defp document_resource_body(_ctx, %Runtime.State{} = state, "state") do
    {:ok,
     %{
       "document_id" => state.document_id,
       "revision" => state.revision,
       "projection" => state.projection
     }}
  end

  defp document_resource_body(_ctx, %Runtime.State{} = state, "outline"),
    do:
      {:ok,
       %{"document_id" => state.document_id, "outline" => get_projection(state, :outline, [])}}

  defp document_resource_body(_ctx, %Runtime.State{} = state, "nodes"),
    do: {:ok, %{"document_id" => state.document_id, "nodes" => get_projection(state, :nodes, [])}}

  defp document_resource_body(_ctx, %Runtime.State{} = state, "fields"),
    do:
      {:ok,
       %{"document_id" => state.document_id, "fields" => get_projection(state, :fields, %{})}}

  defp document_resource_body(_ctx, %Runtime.State{} = state, "marks") do
    marks = state.projection |> Map.get(:marks, %{}) |> map_values()
    {:ok, %{"document_id" => state.document_id, "marks" => marks}}
  end

  defp document_resource_body(ctx, %Runtime.State{} = state, "changes") do
    with {:ok, changes} <- Runtime.sync_since(ctx, state.document_id, 0) do
      {:ok,
       %{"document_id" => state.document_id, "changes" => Enum.map(changes, &render_change/1)}}
    end
  end

  defp document_resource_body(ctx, %Runtime.State{} = state, "revokes") do
    with {:ok, changes} <- Runtime.sync_since(ctx, state.document_id, 0) do
      revokes =
        Enum.filter(
          changes,
          &(&1.status in [:revoked, :partially_revoked] or
              &1.command_kind in ["revoke_change", "resolve_revoke"])
        )

      {:ok,
       %{"document_id" => state.document_id, "revokes" => Enum.map(revokes, &render_change/1)}}
    end
  end

  defp read_source_resource(ctx, route_ref, id, kind, uri) do
    with {:ok, source} <- get_source_document(ctx, route_ref, id),
         {:ok, body} <- source_resource_body(source, kind) do
      {:ok, resource_contents(uri, body)}
    end
  end

  defp source_resource_body(%SourceDocument{} = source, "") do
    {:ok,
     %{
       "id" => source.id,
       "document_id" => source.document_id,
       "chat_thread_id" => source.chat_thread_id,
       "mime_type" => source.mime_type,
       "original_filename" => source.original_filename,
       "status" => source.status,
       "regions" => source.regions
     }}
  end

  defp source_resource_body(%SourceDocument{} = source, "regions"),
    do: {:ok, %{"source_document_id" => source.id, "regions" => source.regions || []}}

  defp source_resource_body(%SourceDocument{} = source, "claims") do
    claims = Repo.all(from c in SourceClaim, where: c.source_document_id == ^source.id)

    {:ok,
     %{"source_document_id" => source.id, "claims" => Enum.map(claims, &render_source_claim/1)}}
  rescue
    _ -> {:ok, %{"source_document_id" => source.id, "claims" => []}}
  end

  defp source_resource_body(%SourceDocument{} = source, "links") do
    claims =
      Repo.all(
        from c in SourceClaim,
          where: c.source_document_id == ^source.id and not is_nil(c.linked_document_id)
      )

    {:ok,
     %{"source_document_id" => source.id, "links" => Enum.map(claims, &render_source_claim/1)}}
  rescue
    _ -> {:ok, %{"source_document_id" => source.id, "links" => []}}
  end

  defp source_resource_body(_source, _kind), do: {:error, :invalid_uri}

  defp read_evidence_resource(ctx, route_ref, id, kind, uri) do
    with {:ok, evidence} <- get_evidence(ctx, route_ref, id),
         {:ok, body} <- evidence_resource_body(evidence, kind) do
      {:ok, resource_contents(uri, body)}
    end
  end

  defp evidence_resource_body(%EvidenceSnapshot{} = evidence, "") do
    {:ok,
     %{
       "id" => evidence.id,
       "document_id" => evidence.document_id,
       "source_document_id" => evidence.source_document_id,
       "provider" => evidence.provider,
       "query" => evidence.query,
       "result" => evidence.result,
       "captured_at" => evidence.captured_at
     }}
  end

  defp evidence_resource_body(%EvidenceSnapshot{} = evidence, "raw"),
    do: {:ok, %{"evidence_id" => evidence.id, "result" => evidence.result}}

  defp evidence_resource_body(%EvidenceSnapshot{} = evidence, "citation"),
    do:
      {:ok,
       %{"evidence_id" => evidence.id, "citation" => Map.get(evidence.result || %{}, "citation")}}

  defp evidence_resource_body(%EvidenceSnapshot{} = evidence, "links") do
    {:ok,
     %{
       "evidence_id" => evidence.id,
       "document_id" => evidence.document_id,
       "source_document_id" => evidence.source_document_id,
       "chat_thread_id" => evidence.chat_thread_id
     }}
  end

  defp evidence_resource_body(_evidence, _kind), do: {:error, :invalid_uri}

  defp document_resources(%Context{} = ctx) do
    ctx
    |> Documents.list_recent_for_scope(limit: 50)
    |> Enum.flat_map(fn doc ->
      Enum.map(@document_resource_kinds, fn kind ->
        %{
          "uri" => "document://#{doc.id}/#{kind}",
          "name" => "#{doc.title || doc.id} #{kind}",
          "description" => "Document #{kind} resource",
          "mimeType" => "application/json"
        }
      end)
    end)
  end

  defp source_document_resources(%Context{user: %{id: owner_id}}) do
    Repo.all(from s in SourceDocument, where: s.owner_id == ^owner_id, limit: 50)
    |> Enum.flat_map(fn source ->
      base = %{
        "uri" => "source_document://#{source.id}",
        "name" => source.original_filename || source.id,
        "description" => "Source document",
        "mimeType" => "application/json"
      }

      children =
        Enum.map(["regions", "claims", "links"], fn kind ->
          %{
            "uri" => "source_document://#{source.id}/#{kind}",
            "name" => "#{source.original_filename || source.id} #{kind}",
            "description" => "Source document #{kind}",
            "mimeType" => "application/json"
          }
        end)

      [base | children]
    end)
  rescue
    _ -> []
  end

  defp source_document_resources(_ctx), do: []

  defp evidence_resources(%Context{user: %{id: owner_id}}) do
    Repo.all(from e in EvidenceSnapshot, where: e.owner_id == ^owner_id, limit: 50)
    |> Enum.flat_map(fn evidence ->
      base = %{
        "uri" => "evidence://#{evidence.id}",
        "name" => "Evidence #{evidence.provider || evidence.id}",
        "description" => "Evidence snapshot",
        "mimeType" => "application/json"
      }

      children =
        Enum.map(["raw", "citation", "links"], fn kind ->
          %{
            "uri" => "evidence://#{evidence.id}/#{kind}",
            "name" => "Evidence #{kind}",
            "description" => "Evidence #{kind}",
            "mimeType" => "application/json"
          }
        end)

      [base | children]
    end)
  rescue
    _ -> []
  end

  defp evidence_resources(_ctx), do: []

  defp get_source_document(%Context{user: %{id: owner_id}}, route_ref, id) do
    case Repo.get(SourceDocument, id) do
      %SourceDocument{owner_id: ^owner_id} = source ->
        with :ok <- authorize_route_ref(route_ref, source.document_id) do
          {:ok, source}
        end

      %SourceDocument{} ->
        {:error, :forbidden}

      nil ->
        {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp get_source_document(_ctx, _route_ref, _id), do: {:error, :forbidden}

  defp get_evidence(%Context{user: %{id: owner_id}}, route_ref, id) do
    case Repo.get(EvidenceSnapshot, id) do
      %EvidenceSnapshot{owner_id: ^owner_id} = evidence ->
        with :ok <- authorize_route_ref(route_ref, evidence.document_id) do
          {:ok, evidence}
        end

      %EvidenceSnapshot{} ->
        {:error, :forbidden}

      nil ->
        {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp get_evidence(_ctx, _route_ref, _id), do: {:error, :forbidden}

  defp authorize_route_ref(nil, _document_id), do: :ok
  defp authorize_route_ref(%RouteRef{document_id: nil}, _document_id), do: :ok
  defp authorize_route_ref(%RouteRef{document_id: document_id}, document_id), do: :ok
  defp authorize_route_ref(%RouteRef{}, _document_id), do: {:error, :forbidden}

  defp authorize_command(ctx, route_ref, %Command{document_id: document_id})
       when is_binary(document_id) do
    with :ok <- authorize_route_ref(route_ref, document_id),
         do: Gateway.authorize_document(ctx, document_id)
  end

  defp authorize_command(ctx, route_ref, %Command{source_claim_id: claim_id})
       when is_binary(claim_id) do
    with {:ok, claim} <- get_source_claim(ctx, claim_id),
         {:ok, _source} <- get_source_document(ctx, route_ref, claim.source_document_id) do
      :ok
    end
  end

  defp authorize_command(_ctx, _route_ref, %Command{}), do: :ok

  defp get_source_claim(%Context{user: %{id: owner_id}}, claim_id) do
    case Repo.one(
           from c in SourceClaim,
             join: s in SourceDocument,
             on: s.id == c.source_document_id,
             where: c.id == ^claim_id and s.owner_id == ^owner_id
         ) do
      %SourceClaim{} = claim -> {:ok, claim}
      nil -> {:error, :forbidden}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp get_source_claim(_ctx, _claim_id), do: {:error, :forbidden}

  defp build_command(%Context{} = ctx, nil, raw), do: build_command(ctx, %RouteRef{}, raw)

  defp build_command(%Context{} = ctx, route_ref, raw) when is_map(raw) do
    attrs = %{
      kind: parse_command_kind(Map.get(raw, "kind") || Map.get(raw, :kind)),
      document_id:
        Map.get(raw, "document_id") || Map.get(raw, :document_id) || route_ref.document_id,
      chat_thread_id:
        Map.get(raw, "chat_thread_id") || Map.get(raw, :chat_thread_id) ||
          route_ref.chat_thread_id,
      source_document_id: Map.get(raw, "source_document_id") || Map.get(raw, :source_document_id),
      source_claim_id: Map.get(raw, "source_claim_id") || Map.get(raw, :source_claim_id),
      change_id: Map.get(raw, "change_id") || Map.get(raw, :change_id),
      agent_run_id:
        Map.get(raw, "agent_run_id") || Map.get(raw, :agent_run_id) || route_ref.agent_run_id,
      actor_type:
        parse_actor_type(Map.get(raw, "actor_type") || Map.get(raw, :actor_type) || "user"),
      actor_id: Map.get(raw, "actor_id") || Map.get(raw, :actor_id) || user_id(ctx),
      base_revision:
        Map.get(raw, "base_revision") || Map.get(raw, :base_revision) || route_ref.base_revision,
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

  defp build_command(_ctx, _route_ref, _raw), do: {:error, :invalid_action_payload}

  defp parse_command_kind(value), do: parse_enum(value, Ecto.Enum.values(Command, :kind))
  defp parse_actor_type(value), do: parse_enum(value, Ecto.Enum.values(Command, :actor_type))

  defp parse_enum(value, allowed) when is_atom(value) do
    if value in allowed, do: value
  end

  defp parse_enum(value, allowed) when is_binary(value) do
    Enum.find(allowed, fn atom -> Atom.to_string(atom) == value end)
  end

  defp parse_enum(_value, _allowed), do: nil

  defp fetch_arg(args, key) do
    case Map.get(args, key) || Map.get(args, String.to_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_params}
    end
  end

  defp normalize_limit(limit, _default) when is_integer(limit) and limit > 0 and limit <= 100,
    do: limit

  defp normalize_limit(limit, default) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 and n <= 100 -> n
      _ -> default
    end
  end

  defp normalize_limit(_, default), do: default

  defp resource_contents(uri, body) do
    %{
      "contents" => [
        %{
          "uri" => uri,
          "mimeType" => "application/json",
          "text" => Jason.encode!(json_safe(body))
        }
      ]
    }
  end

  defp render_result(%Change{} = change), do: render_change(change)

  defp render_result(%Runtime.State{} = state),
    do: %{
      "document_id" => state.document_id,
      "revision" => state.revision,
      "projection" => state.projection
    }

  defp render_result(other), do: json_safe(other)

  defp render_change(%Change{} = change) do
    %{
      "id" => change.id,
      "document_id" => change.document_id,
      "command_kind" => change.command_kind,
      "base_revision" => change.base_revision,
      "result_revision" => change.result_revision,
      "status" => atom_to_string(change.status),
      "actor_type" => atom_to_string(change.actor_type),
      "actor_id" => change.actor_id,
      "message" => change.message,
      "inserted_at" => change.inserted_at
    }
  end

  defp render_source_claim(%SourceClaim{} = claim) do
    %{
      "id" => claim.id,
      "source_document_id" => claim.source_document_id,
      "region_id" => claim.region_id,
      "proposed_kind" => claim.proposed_kind,
      "proposed_value" => claim.proposed_value,
      "status" => claim.status,
      "linked_document_id" => claim.linked_document_id,
      "linked_node_id" => claim.linked_node_id
    }
  end

  defp not_available(feature, reason),
    do: %{"status" => "not_available", "feature" => feature, "reason" => reason}

  # --- agent doc.* helpers --------------------------------------------------

  # Wraps a doc.* handler invocation with two PubSub broadcasts on
  # `agent:#{run_id}`: a :tool_call_started before the handler runs, and a
  # :tool_call_completed (or :tool_call_failed) after. This is what the
  # chat-rail consumes to render tool_call cards — independent of OpenAI's
  # SSE event vocabulary (which varies across model versions).
  defp instrumented(route_ref, tool, args, fun) when is_function(fun, 0) do
    run_id = route_ref && Map.get(route_ref, :agent_run_id)
    thread_id = route_ref && Map.get(route_ref, :chat_thread_id)
    tool_id = "#{tool}-#{System.unique_integer([:positive])}"

    if is_binary(run_id) do
      Phoenix.PubSub.broadcast(
        Contract.PubSub,
        "agent:#{run_id}",
        {:tool_call_started, run_id,
         %{
           id: tool_id,
           name: tool,
           server_label: "contract-doc",
           arguments: args
         }}
      )
    end

    result =
      try do
        fun.()
      rescue
        e -> {:error, {:exception, Exception.message(e)}}
      end

    {status, payload, summary} =
      case result do
        {:ok, output} -> {"completed", output, tool_call_summary(output)}
        {:error, reason} -> {"failed", %{"error" => inspect(reason)}, short_error(reason)}
      end

    # Build the persistent operation record (same shape the rail's
    # `operation_block` consumes; survives page reload via chat_threads).
    operation = %{
      "id" => tool_id,
      "type" => "tool_call",
      "name" => tool,
      "tool_name" => tool,
      "raw_name" => tool,
      "server_label" => "contract-doc",
      "title" => tool,
      "status" => status,
      "summary" => summary,
      "agent_run_id" => run_id,
      "details" => %{
        "arguments" => args,
        "output" => payload
      }
    }

    # PubSub for live UI.
    if is_binary(run_id) do
      tag = if status == "completed", do: :tool_call_completed, else: :tool_call_failed
      payload_msg = Map.merge(operation, %{"output" => payload, "reason" => payload["error"]})

      Phoenix.PubSub.broadcast(
        Contract.PubSub,
        "agent:#{run_id}",
        {tag, run_id, tool_id, payload_msg}
      )
    end

    # Durable: write to chat_thread so the bubble re-renders on reload.
    Contract.ChatThreads.append_tool_call_message(thread_id, operation)

    result
  end

  defp tool_call_summary(%{"revision" => rev}) when is_integer(rev), do: "rev #{rev}"
  defp tool_call_summary(%{"unchanged" => true, "revision" => rev}), do: "rev #{rev} (no change)"
  defp tool_call_summary(%{"ok" => false, "error" => err}), do: to_string(err)
  defp tool_call_summary(_), do: "ok"

  defp short_error({:forbidden, reason}), do: "forbidden: #{reason}"
  defp short_error({code, _}) when is_atom(code), do: Atom.to_string(code)
  defp short_error(code) when is_atom(code), do: Atom.to_string(code)
  defp short_error(_), do: "error"

  # Strict gate for doc.* tools. Caller MUST hold a route_ref that:
  #   (a) carries scope "agent_doc" (blocks slack/api tokens from escalating)
  #   (b) refers to an agent_run that is still alive (token revocation —
  #       once the RunServer GenServer terminates, the token stops being
  #       honored even within its TTL). Tokens without agent_run_id (e.g.
  #       hand-minted test tokens) skip the liveness check.
  defp authorize_doc_mcp(%RouteRef{scopes: scopes} = ref) when is_list(scopes) do
    with :ok <- check_agent_doc_scope(scopes),
         :ok <- check_run_alive(ref) do
      :ok
    end
  end

  defp authorize_doc_mcp(_route_ref), do: {:error, {:forbidden, :no_route_ref}}

  defp check_agent_doc_scope(scopes) do
    if "agent_doc" in Enum.map(scopes, &to_string/1) do
      :ok
    else
      {:error, {:forbidden, :missing_scope_agent_doc}}
    end
  end

  # Task #139 — when the bearer is deterministic per (user, doc,
  # thread) it no longer carries an `agent_run_id`. `resolve_agent_run_id/1`
  # (called once at the head of every doc.* handler) splats the run id
  # onto the struct if a RunServer is alive for the (user_id,
  # document_id) scope. If the splat populated `agent_run_id`, we
  # require the lookup result to still be valid (covers token
  # revocation when a run completes); if it didn't, the bearer is
  # treated as a non-agent caller — the change gets stamped
  # `actor_type: :user` by `actor_type_for/1` and the audit trail
  # stays truthful. Hand-minted test tokens that never had an
  # `agent_run_id` skip the check the same way they used to.
  defp check_run_alive(%RouteRef{agent_run_id: nil}), do: :ok

  defp check_run_alive(%RouteRef{agent_run_id: run_id}) when is_binary(run_id) do
    case Contract.Agent.RunServer.whereis(run_id) do
      pid when is_pid(pid) -> :ok
      _ -> {:error, {:forbidden, :run_not_active}}
    end
  end

  # Stricter sibling of authorize_route_ref/2: refuses tokens that lack a
  # document_id binding (the legacy clause treats `nil → :ok` as a god
  # token; we never want that for doc.* mutation tools).
  defp authorize_route_ref_strict(%RouteRef{document_id: doc_id}, doc_id)
       when is_binary(doc_id),
       do: :ok

  defp authorize_route_ref_strict(%RouteRef{}, _doc_id),
    do: {:error, {:forbidden, :route_ref_doc_mismatch}}

  defp authorize_route_ref_strict(_route_ref, _doc_id),
    do: {:error, {:forbidden, :no_route_ref}}

  defp resolve_document_id(route_ref, args) do
    explicit = Map.get(args, "document_id") || Map.get(args, :document_id)

    cond do
      is_binary(explicit) and explicit != "" ->
        {:ok, explicit}

      match?(%RouteRef{document_id: id} when is_binary(id), route_ref) ->
        {:ok, route_ref.document_id}

      true ->
        {:error, :missing_document_id}
    end
  end

  defp actor_type_for(%RouteRef{agent_run_id: id}) when is_binary(id), do: "agent"
  defp actor_type_for(_), do: "user"

  # Task #139 — the route_ref bearer is deterministic per (user, doc,
  # thread) and intentionally carries no agent_run_id (so OpenAI's
  # hosted MCP tools/list caches across turns). Resolve the per-turn
  # run id from the scope registry and splat it onto the struct so the
  # rest of the MCP pipeline (instrumented/4, build_command/3) keeps
  # the same shape it always had. The route_ref struct mutation here
  # is purely in-memory — the signed token is never re-issued.
  #
  # When the ref doesn't carry user_id + document_id (eg hand-minted
  # test tokens or non-agent purposes), or no run is active for that
  # scope, leave the struct untouched: the actor_type_for/1 fallback
  # then stamps :user, and downstream auth gates handle the rest.
  defp resolve_agent_run_id(%RouteRef{agent_run_id: id} = ref) when is_binary(id), do: ref

  defp resolve_agent_run_id(%RouteRef{user_id: user_id, document_id: doc_id} = ref)
       when is_binary(user_id) and is_binary(doc_id) do
    case Contract.Agent.RunServer.whereis_for_scope(user_id, doc_id) do
      {run_id, _pid} when is_binary(run_id) -> %{ref | agent_run_id: run_id}
      _ -> ref
    end
  end

  defp resolve_agent_run_id(other), do: other

  defp mcp_idempotency_key(nil, tool, args) do
    "mcp-#{tool}-#{:erlang.phash2(args)}-#{System.unique_integer([:positive])}"
  end

  defp mcp_idempotency_key(run_id, tool, args) do
    "mcp:#{run_id}:#{tool}:#{:erlang.phash2(args)}"
  end

  defp edit_text_ops(args) do
    sec = fetch_int(args, "sec")
    para = fetch_int(args, "para")
    off = fetch_int(args, "off")
    len = fetch_int(args, "len")
    text = Map.get(args, "text") || Map.get(args, :text) || ""
    cell_path = Map.get(args, "cell_path") || Map.get(args, :cell_path)

    cond do
      is_nil(sec) or is_nil(para) or is_nil(off) or is_nil(len) ->
        {:error, {:invalid_params, "sec, para, off, len are required"}}

      len < 0 ->
        {:error, {:invalid_params, "len must be >= 0"}}

      not is_binary(text) ->
        {:error, {:invalid_params, "text must be a string"}}

      true ->
        ops =
          []
          |> maybe_prepend_delete(sec, para, off, len, cell_path)
          |> maybe_prepend_insert(sec, para, off, text, cell_path)
          |> Enum.reverse()

        {:ok, ops}
    end
  end

  defp maybe_prepend_delete(ops, _sec, _para, _off, 0, _cell_path), do: ops

  defp maybe_prepend_delete(ops, sec, para, off, len, cell_path) do
    [
      compact(%{
        "kind" => "delete_text",
        "sec" => sec,
        "para" => para,
        "off" => off,
        "len" => len,
        "cell_path" => cell_path
      })
      | ops
    ]
  end

  defp maybe_prepend_insert(ops, _sec, _para, _off, "", _cell_path), do: ops

  defp maybe_prepend_insert(ops, sec, para, off, text, cell_path) do
    [
      compact(%{
        "kind" => "insert_text",
        "sec" => sec,
        "para" => para,
        "off" => off,
        "text" => text,
        "cell_path" => cell_path
      })
      | ops
    ]
  end

  defp compact(map) when is_map(map),
    do: :maps.filter(fn _k, v -> not is_nil(v) end, map)

  defp fetch_int(args, key) do
    case Map.get(args, key) || Map.get(args, String.to_atom(key)) do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  # All four doc.* mutation tools below ride the same :edit_text Command kind —
  # the Reducer streams every rhwp text op (insert_text/delete_text/
  # insert_paragraph/merge_paragraph/table_row_insert/table_row_delete/
  # table_column_insert/table_column_delete/table_delete) through the same
  # payload shape. Only `applied` in the return envelope differs so the
  # agent UI can tell tools apart.
  defp submit_edit_text(ctx, route_ref, document_id, args, ops, applied) do
    run_id = route_ref && Map.get(route_ref, :agent_run_id)

    command_args = %{
      "kind" => "edit_text",
      "document_id" => document_id,
      "actor_type" => actor_type_for(route_ref),
      "actor_id" => user_id(ctx) || (route_ref && Map.get(route_ref, :user_id)),
      "agent_run_id" => run_id,
      "base_revision" => Map.get(args, "base_revision") || Map.get(args, :base_revision),
      "idempotency_key" => mcp_idempotency_key(run_id, applied, args),
      "payload" => %{"ops" => ops}
    }

    with {:ok, command} <- build_command(ctx, route_ref, command_args),
         :ok <- authorize_command(ctx, route_ref, command),
         {:ok, %Contract.Change{} = change} <- Runtime.apply(ctx, command) do
      {:ok,
       %{
         "ok" => true,
         "revision" => change.result_revision,
         "applied" => applied,
         "change_id" => change.id
       }}
    end
  end

  defp insert_block_ops(args) do
    sec = fetch_int(args, "sec")
    para = fetch_int(args, "para")
    kind = Map.get(args, "kind") || Map.get(args, :kind)
    text = Map.get(args, "text") || Map.get(args, :text) || ""
    cell_path = Map.get(args, "cell_path") || Map.get(args, :cell_path)
    parent_para = fetch_int(args, "parent_para")

    cond do
      is_nil(sec) or is_nil(para) ->
        {:error, {:invalid_params, "sec, para are required"}}

      kind not in ["paragraph", "heading", "list_item", "table"] ->
        {:error, {:invalid_params, "kind must be paragraph|heading|list_item|table"}}

      kind == "table" ->
        # rhwp text-op kind for creating a *new* table from nothing does not
        # exist yet (see @text_op_kinds in Contract.Session.Reducer — only
        # row/column/table_delete are wired). Block this case until the IR
        # pipeline gains a `TableInserted` event.
        {:error, {:not_supported, "doc.insert_block kind=table not wired (no rhwp table-create op)"}}

      not is_binary(text) ->
        {:error, {:invalid_params, "text must be a string"}}

      true ->
        # `:insert_paragraph` splits the paragraph at `(sec, para, 0)` —
        # producing a fresh empty paragraph in front. If the caller supplied
        # `text`, follow with `:insert_text` at off=0 of the new paragraph.
        split_op =
          compact(%{
            "kind" => "insert_paragraph",
            "sec" => sec,
            "para" => para,
            "off" => 0,
            "parent_para" => parent_para,
            "cell_path" => cell_path
          })

        insert_op =
          if text == "" do
            nil
          else
            compact(%{
              "kind" => "insert_text",
              "sec" => sec,
              "para" => para,
              "off" => 0,
              "text" => text,
              "cell_path" => cell_path
            })
          end

        {:ok, Enum.reject([split_op, insert_op], &is_nil/1)}
    end
  end

  defp delete_block_ops(args) do
    sec = fetch_int(args, "sec")
    para = fetch_int(args, "para")
    parent_para = fetch_int(args, "parent_para")
    cell_path = Map.get(args, "cell_path") || Map.get(args, :cell_path)

    cond do
      is_nil(sec) or is_nil(para) ->
        {:error, {:invalid_params, "sec, para are required"}}

      # Merging paragraph N back into N-1 effectively deletes paragraph N —
      # that's the rhwp primitive available today. Para 0 has no
      # predecessor, so refuse rather than emit a no-op.
      para == 0 ->
        {:error, {:invalid_params, "cannot delete the first paragraph in a section"}}

      true ->
        op =
          compact(%{
            "kind" => "merge_paragraph",
            "sec" => sec,
            "para" => para,
            "parent_para" => parent_para,
            "cell_path" => cell_path
          })

        {:ok, [op]}
    end
  end

  defp edit_table_ops(args) do
    sec = fetch_int(args, "sec")
    parent_para = fetch_int(args, "para") || fetch_int(args, "parent_para")
    control_index = fetch_int(args, "control_index")
    at_row = fetch_int(args, "at_row")
    at_col = fetch_int(args, "at_col")
    op = Map.get(args, "op") || Map.get(args, :op)

    cond do
      is_nil(sec) or is_nil(parent_para) ->
        {:error, {:invalid_params, "sec, para are required"}}

      op not in ["row_insert", "row_delete", "col_insert", "col_delete"] ->
        {:error, {:invalid_params, "op must be row_insert|row_delete|col_insert|col_delete"}}

      op in ["row_insert", "row_delete"] and is_nil(at_row) ->
        {:error, {:invalid_params, "at_row is required for row_insert/row_delete"}}

      op in ["col_insert", "col_delete"] and is_nil(at_col) ->
        {:error, {:invalid_params, "at_col is required for col_insert/col_delete"}}

      true ->
        kind =
          case op do
            "row_insert" -> "table_row_insert"
            "row_delete" -> "table_row_delete"
            "col_insert" -> "table_column_insert"
            "col_delete" -> "table_column_delete"
          end

        text_op =
          compact(%{
            "kind" => kind,
            "sec" => sec,
            "parent_para" => parent_para,
            "control_index" => control_index,
            "at_row" => at_row,
            "at_col" => at_col
          })

        {:ok, [text_op]}
    end
  end

  defp set_field_value_ops(args, %Runtime.State{} = state) do
    id = Map.get(args, "id") || Map.get(args, :id)
    value = Map.get(args, "value") || Map.get(args, :value)

    cond do
      not is_binary(id) or id == "" ->
        {:error, {:invalid_params, "id is required"}}

      not is_binary(value) ->
        {:error, {:invalid_params, "value must be a string"}}

      true ->
        case lookup_field_position(state, id) do
          {:ok, pos} ->
            {:ok, field_position_to_edit_ops(pos, value)}

          :error ->
            {:error, {:not_found, "field #{id} not found in projection"}}
        end
    end
  end

  # Resolve a field id against the agent IR. We project here (vs. peeking at
  # state.projection.fields directly) because the snapshot path is the only
  # one carrying `position` info — the legacy create_node path produces empty
  # positions, in which case we cannot synthesize a text edit and return :error.
  defp lookup_field_position(%Runtime.State{} = state, id) do
    ir = Contract.MCP.Projection.to_agent_ir(state)

    case Enum.find(Map.get(ir, "fields", []) || [], fn f -> Map.get(f, "id") == id end) do
      nil ->
        :error

      %{"position" => pos} when is_map(pos) and map_size(pos) > 0 ->
        {:ok, pos}

      _ ->
        :error
    end
  end

  defp field_position_to_edit_ops(pos, value) do
    sec = Map.get(pos, "sec") || Map.get(pos, :sec)

    para =
      Map.get(pos, "parent_para") || Map.get(pos, :parent_para) ||
        Map.get(pos, "para") || Map.get(pos, :para)

    off_start = Map.get(pos, "off_start") || Map.get(pos, :off_start) || 0
    off_end = Map.get(pos, "off_end") || Map.get(pos, :off_end) || off_start
    cell_path = Map.get(pos, "cell_path") || Map.get(pos, :cell_path)
    len = max(off_end - off_start, 0)

    []
    |> maybe_prepend_delete(sec, para, off_start, len, cell_path)
    |> maybe_prepend_insert(sec, para, off_start, value, cell_path)
    |> Enum.reverse()
  end

  defp parse_custom_uri(uri, prefix) do
    rest = String.replace_prefix(uri, prefix, "")

    case String.split(rest, "/", parts: 2) do
      [id] when id != "" -> {:ok, id, ""}
      [id, path] when id != "" -> {:ok, id, normalize_path(path)}
      _ -> {:error, :invalid_uri}
    end
  end

  defp normalize_path(nil), do: ""
  defp normalize_path("/"), do: ""
  defp normalize_path("/" <> rest), do: rest
  defp normalize_path(path), do: path

  defp get_projection(%Runtime.State{projection: projection}, key, default) do
    Map.get(projection || %{}, key) || Map.get(projection || %{}, Atom.to_string(key)) || default
  end

  defp map_values(map) when is_map(map), do: Map.values(map)
  defp map_values(list) when is_list(list), do: list
  defp map_values(_), do: []

  defp user_id(%Context{user: %{id: id}}), do: id
  defp user_id(_ctx), do: nil

  defp atom_to_string(nil), do: nil
  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp atom_to_string(value), do: value

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(%Decimal{} = value), do: Decimal.to_string(value)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(map) when is_map(map),
    do: map |> Map.drop([:__meta__]) |> Map.new(fn {k, v} -> {json_key(k), json_safe(v)} end)

  defp json_safe(value) when is_atom(value), do: atom_to_string(value)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp object_schema(properties, required) do
    %{"type" => "object", "properties" => properties, "required" => required}
  end

  defp string_schema, do: %{"type" => "string"}
  defp integer_schema(min, max), do: %{"type" => "integer", "minimum" => min, "maximum" => max}

  defp source_claim_tool(name, description, kind) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" =>
        object_schema(
          %{
            "source_claim_id" => string_schema(),
            "kind" => %{"type" => "string", "const" => kind},
            "payload" => %{"type" => "object"}
          },
          ["source_claim_id"]
        )
    }
  end
end
