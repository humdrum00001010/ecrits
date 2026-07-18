defmodule Ecrits.Doc.MCPServer do
  @moduledoc """
  MCP server that exposes `Ecrits.Doc.Tools` (`doc.context/list/open/create/
  read/find/get/set/edit/save` — ten tools) over the Model Context
  Protocol. `doc.read` clarifies one anchor ref from `doc.find`; `doc.get`
  (type + current values + settable property names + children) and `doc.set`
  (universal property setter, incl. char formatting) are the reflective
  property-IR surface.

  This is the ACP-native bridge: rather than a bespoke tool loop, the document
  abstraction is published as a standard MCP server (ex_mcp's core competency)
  and handed to the ACP session via `ExMCP.ACP.Client.new_session(client, cwd,
  mcp_servers: [...])`. The coding agent (codex / claude, over ACP) then
  *discovers* and *calls* these tools itself; ex_mcp routes each call here, we
  delegate to `Ecrits.Doc.Tools.call/3`, and the agent's `tool_call` /
  `tool_call_update` `session/update`s render in the chat-rail tool_call block.

  Served over HTTP via `ExMCP.HttpPlug` (mounted in `EcritsWeb.Endpoint`), so an
  external provider subprocess can reach this in-process BEAM server through a
  streamable-HTTP MCP transport.
  """

  use ExMCP.Server.Handler

  alias Ecrits.Doc.MCPToolPolicy
  alias Ecrits.Doc.Tools
  alias Ecrits.Path, as: WorkspacePath
  alias Ecrits.AcpAgent.Session, as: AgentSession
  alias Ecrits.Workspace.Session, as: WorkspaceSession
  require Logger

  @server_name "ecrits-doc-tools"
  @server_version "0.1.0"

  @impl true
  def init(_args), do: {:ok, %{}}

  @impl true
  def handle_initialize(_params, state) do
    {:ok,
     %{
       protocolVersion: "2025-06-18",
       serverInfo: %{name: @server_name, version: @server_version},
       capabilities: capabilities()
     }, state}
  end

  # `ExMCP.HttpPlug`'s message-processor `initialize` path calls
  # `handler.get_capabilities/0` *directly* (an artifact of the `use ExMCP.Server`
  # DSL style), bypassing the `handle_initialize/2` callback this `Handler`
  # module implements. Without it that path raises `UndefinedFunctionError` and
  # the MCP handshake intermittently fails. Provide it so both initialize paths
  # report the same capability set.
  def get_capabilities, do: capabilities()

  defp capabilities, do: %{tools: %{}}

  @impl true
  def handle_list_tools(_cursor, state) do
    tools =
      Tools.tools()
      |> MCPToolPolicy.restrict_for_vfs(fuse_mode?())
      |> Enum.map(&to_mcp_tool/1)

    {:ok, tools, nil, state}
  end

  defp fuse_mode?, do: Ecrits.Fuse.DocMount.enabled?()

  # Codex's MCP connection manager probes `resources/list` on *every* server
  # right after `initialize` (before it builds the per-turn tool list). The
  # `ExMCP.Server.Handler` default answers it with a JSON-RPC error
  # (`-32603 "Resources not implemented"`), which codex logs as a WARN and which
  # makes the freshly-connected server look partially-broken during the exact
  # window when codex is deciding whether the doc tools are ready for the turn.
  # We expose no resources, so answer the probe cleanly with an empty list — the
  # server then presents as fully healthy the instant `initialize` completes,
  # so codex reliably includes the `doc.*` tools in the turn's tool list.
  @impl true
  def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}

  @impl true
  def handle_call_tool(name, arguments, state) do
    # Strip the protocol `_meta` envelope ex_mcp folds into arguments, and the
    # `_agent_id` the per-agent MCP url's plug splices in (the isolation seam).
    {_meta, args} = Map.pop(arguments || %{}, "_meta")
    {agent_id, args} = Map.pop(args, "_agent_id")

    case resolve_tool_context(agent_id) do
      {:ok, ctx} ->
        run_tool(ctx, name, args, state)

      {:error, reason} ->
        {:ok, %{content: [json_content(reason)], isError: true}, state}
    end
  end

  defp run_tool(ctx, name, args, state) do
    if fuse_mode?() do
      run_vfs_tool(ctx, name, args, state)
    else
      do_run_tool(ctx, name, args, state)
    end
  end

  defp run_vfs_tool(ctx, name, args, state) do
    key = vfs_sequence_key(ctx)

    with {:ok, sequence} <- get_vfs_sequence(ctx, state, key) do
      run_vfs_sequence(ctx, name, args, state, key, sequence)
    else
      {:error, reason} -> vfs_policy_error(reason, state)
    end
  end

  defp run_vfs_sequence(ctx, name, args, state, key, sequence) do
    attempted_sequence = consume_vfs_attempt(sequence, name)

    case put_vfs_sequence(ctx, state, key, attempted_sequence) do
      {:ok, attempted_state} ->
        evidence = vfs_sequence_evidence(ctx, sequence, name, args)

        with :ok <- MCPToolPolicy.authorize_vfs_sequence(name, args, sequence, evidence),
             :ok <- verify_vfs_tool_evidence(ctx, sequence, name, args) do
          prepared_args = MCPToolPolicy.prepare_vfs_call(name, args, sequence)

          result =
            vfs_tool_context(ctx, name)
            |> call_tool(name, prepared_args)
            |> finalize_vfs_result(name, args)

          next_sequence = transition_vfs_sequence(ctx, name, args, sequence, result)

          case put_vfs_sequence(ctx, attempted_state, key, next_sequence) do
            {:ok, next_state} -> tool_response(result, next_state)
            {:error, reason} -> vfs_policy_error(reason, attempted_state)
          end
        else
          {:error, reason} ->
            state_after_error =
              restore_retryable_find(ctx, name, reason, sequence, key, attempted_state)

            vfs_policy_error(reason, state_after_error)
        end

      {:error, reason} ->
        vfs_policy_error(reason, state)
    end
  end

  # A pattern-level find failure (stale or repeated pattern) earns ONE
  # corrected retry: restore the pre-attempt sequence with the retry marked
  # used, instead of leaving the lookup consumed. Commit-evidence and
  # malformed-call failures stay terminal.
  defp restore_retryable_find(ctx, "doc.find", reason, sequence, key, attempted_state) do
    if MCPToolPolicy.retryable_find_error?(reason) and
         Map.get(sequence, :find_retry_used?) != true do
      retry_sequence = Map.put(sequence, :find_retry_used?, true)

      case put_vfs_sequence(ctx, attempted_state, key, retry_sequence) do
        {:ok, restored_state} -> restored_state
        {:error, _reason} -> attempted_state
      end
    else
      attempted_state
    end
  end

  defp restore_retryable_find(_ctx, _name, _reason, _sequence, _key, attempted_state),
    do: attempted_state

  defp consume_vfs_attempt(%{phase: :native_marker_ref_ready} = sequence, "doc.edit"),
    do: MCPToolPolicy.record_vfs_edit(sequence)

  defp consume_vfs_attempt(sequence, "doc.find") do
    sequence = Map.put(sequence, :native_marker_find_spent?, true)

    if Map.get(sequence, :phase) == :acp_primary,
      do: Map.put(sequence, :phase, :native_marker_find_spent),
      else: sequence
  end

  defp consume_vfs_attempt(sequence, _name), do: sequence

  # An ACP/VFS commit is durable before its browser-resync message necessarily
  # reaches the LiveView. A marker lookup issued immediately after that
  # commit must therefore read a fresh server model from the committed file,
  # not race the attached browser model. Keep this authority override scoped to
  # the read-only VFS `doc.find`; ordinary document tools retain normal
  # browser/server ownership routing.
  defp vfs_tool_context(ctx, "doc.find"),
    do: Map.put(ctx, :doc_find_authority, :committed_server)

  defp vfs_tool_context(ctx, _name), do: ctx

  defp finalize_vfs_result(result, "doc.find", args),
    do: MCPToolPolicy.finalize_vfs_find_result(result, args)

  defp finalize_vfs_result(result, _name, _args), do: result

  # The agent may still try a `doc.*` tool from a cached tool list — refuse it
  # and point it at the file, so VFS mode is enforced end-to-end (not just in
  # the advertised list).
  defp vfs_policy_error(reason, state),
    do: {:ok, %{content: [json_content(reason)], isError: true}, state}

  defp verify_vfs_tool_evidence(ctx, sequence, "doc.edit", args) do
    with :ok <- verify_vfs_fallback_mount(ctx, sequence, args),
         :ok <- verify_vfs_picture_source(ctx, args) do
      :ok
    end
  end

  defp verify_vfs_tool_evidence(_ctx, _sequence, _name, _args), do: :ok

  defp verify_vfs_fallback_mount(
         ctx,
         sequence,
         %{"fallback" => %{"mounted_at" => mounted_at, "reason" => "unrepresentable"}}
       )
       when is_binary(mounted_at) do
    with root when is_binary(root) and root != "" <- Map.get(ctx, :session_path),
         mount_root <- Ecrits.Fuse.DocMount.mount_point(root),
         expanded <- Path.expand(mounted_at),
         true <- String.starts_with?(expanded, mount_root <> "/"),
         name when is_binary(name) <-
           Ecrits.Doc.Projection.source_basename(Path.basename(expanded)),
         true <- mounted_at == Map.get(sequence, :mounted_at),
         true <- name == Map.get(sequence, :mount_name),
         true <- Ecrits.Fuse.OpenDocs.member?(root, name),
         true <- File.exists?(expanded) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, vfs_fallback_mount_required_message()}
    end
  end

  defp verify_vfs_fallback_mount(_ctx, _sequence, _args),
    do: {:error, vfs_fallback_mount_required_message()}

  defp verify_vfs_picture_source(ctx, %{"op" => %{"src" => src}}) when is_binary(src) do
    with root when is_binary(root) and root != "" <- Map.get(ctx, :session_path),
         true <- Path.type(src) == :absolute,
         relative <- Path.relative_to(src, root),
         {:ok, normalized} <- WorkspacePath.normalize(relative),
         {:ok, resolved_src} <- WorkspacePath.join(root, normalized),
         true <- resolved_src == Path.expand(src),
         true <- File.regular?(resolved_src) do
      :ok
    else
      _ ->
        {:error,
         %{
           "error" => "workspace_picture_source_required",
           "tool" => "doc.edit",
           "message" =>
             "Use the original supplied image file from this workspace; do not create or use a temporary derivative."
         }}
    end
  end

  defp verify_vfs_picture_source(_ctx, _args),
    do:
      {:error,
       %{
         "error" => "workspace_picture_source_required",
         "tool" => "doc.edit",
         "message" => "Use the original supplied image file from this workspace."
       }}

  defp vfs_fallback_mount_required_message do
    %{
      "error" => "vfs_fallback_mount_required",
      "tool" => "doc.edit",
      "message" =>
        "doc.edit fallback requires the existing open mounted_at path returned by doc.open_doc for this workspace document. If that path is missing, not an open projection, or outside the live mount, report the VFS blocker instead of bypassing it.",
      "required_fallback" => %{"mounted_at" => "open <workspace>/.ecrits/<document>.jsonl"}
    }
  end

  defp do_run_tool(ctx, name, args, state) do
    ctx
    |> call_tool(name, args)
    |> tool_response(state)
  end

  defp call_tool(ctx, name, args) do
    started_at = System.monotonic_time(:millisecond)
    result = Tools.call(ctx, name, args)
    log_tool_timing(ctx, name, result, started_at)
    result
  end

  defp tool_response(result, state) do
    case result do
      # NOTE: doc.render used to attach MCP image content blocks here
      # ("__images__"). That was removed: CLI agents round-trip the whole
      # content array (base64 included) through the ACP text channel, feeding
      # the model raw base64 instead of pixels. Renders now return FILE PATHS
      # the agent views with its native image tool.
      #
      # The same lesson killed `structuredContent`: it duplicated the exact
      # JSON already in the content text block, and the CLI agents echo the
      # WHOLE result envelope into the model context — every doc.* result was
      # paid for twice. One serialized copy is the contract.
      {:ok, result} ->
        {:ok, %{content: [json_content(result)]}, state}

      {:error, %{} = structured} ->
        # Tool-level error the agent should act on (conflict, capability gap):
        # surface as an error *result* (isError), not a protocol error.
        {:ok, %{content: [json_content(structured)], isError: true}, state}

      {:error, reason} ->
        {:ok, %{content: [text_content(format_error(reason))], isError: true}, state}
    end
  end

  defp vfs_sequence_key(ctx) do
    turn = Map.get(ctx, :turn_id) || {:document, Map.get(ctx, :document_path)}
    {Map.get(ctx, :agent_id, :anonymous), turn}
  end

  defp get_vfs_sequence(%{agent_session: pid, turn_id: turn_id}, _state, _key)
       when is_pid(pid) and is_binary(turn_id) do
    case AgentSession.doc_vfs_sequence(pid, turn_id) do
      {:ok, nil} -> {:ok, MCPToolPolicy.new_vfs_sequence()}
      {:ok, %{} = sequence} -> {:ok, sequence}
      {:error, :turn_mismatch} -> {:error, vfs_turn_unavailable_message()}
    end
  end

  defp get_vfs_sequence(%{agent_id: agent_id}, _state, _key) when is_binary(agent_id),
    do: {:error, vfs_turn_unavailable_message()}

  defp get_vfs_sequence(_ctx, state, key) do
    state
    |> Map.get(:vfs_sequences, %{})
    |> Map.get(key, MCPToolPolicy.new_vfs_sequence())
    |> then(&{:ok, &1})
  end

  defp put_vfs_sequence(
         %{agent_session: pid, turn_id: turn_id},
         state,
         _key,
         sequence
       )
       when is_pid(pid) and is_binary(turn_id) do
    case AgentSession.put_doc_vfs_sequence(pid, turn_id, sequence) do
      :ok -> {:ok, state}
      {:error, :turn_mismatch} -> {:error, vfs_turn_unavailable_message()}
    end
  end

  defp put_vfs_sequence(%{agent_id: agent_id}, _state, _key, _sequence)
       when is_binary(agent_id),
       do: {:error, vfs_turn_unavailable_message()}

  defp put_vfs_sequence(_ctx, state, {agent_id, _turn} = key, sequence) do
    sequences =
      state
      |> Map.get(:vfs_sequences, %{})
      |> Enum.reject(fn
        {{^agent_id, _old_turn}, _old_sequence} -> true
        _entry -> false
      end)
      |> Map.new()
      |> Map.put(key, sequence)

    {:ok, Map.put(state, :vfs_sequences, sequences)}
  end

  defp vfs_turn_unavailable_message do
    %{
      "error" => "doc_turn_unavailable",
      "message" => "The document tool sequence is unavailable outside its active agent turn."
    }
  end

  defp vfs_sequence_evidence(ctx, %{phase: :acp_primary} = sequence, "doc.find", args) do
    current = committed_projection(ctx, sequence)
    revision = projection_revision(current)
    pattern = Map.get(args, "pattern")

    %{
      committed_projection?: is_binary(current),
      primary_committed?:
        is_binary(revision) and revision != Map.get(sequence, :baseline_revision) and
          no_vfs_write_failure?(ctx, sequence) and no_vfs_stage?(ctx, sequence),
      exact_count:
        if is_binary(current) and is_binary(pattern) do
          Ecrits.Doc.ProjectionAudit.exact_paragraph_count(current, pattern)
        else
          0
        end
    }
  end

  defp vfs_sequence_evidence(_ctx, _sequence, _name, _args), do: %{}

  defp transition_vfs_sequence(ctx, "doc.open_doc", _args, sequence, {:ok, result}) do
    revision = result |> open_projection(ctx) |> projection_revision()
    MCPToolPolicy.record_vfs_open(sequence, result, revision)
  end

  defp transition_vfs_sequence(_ctx, "doc.find", args, sequence, {:ok, result}),
    do: MCPToolPolicy.record_vfs_find(sequence, result, args)

  defp transition_vfs_sequence(_ctx, "doc.find", args, sequence, _result),
    do: MCPToolPolicy.record_vfs_find(sequence, %{}, args)

  defp transition_vfs_sequence(_ctx, "doc.edit", _args, sequence, _result),
    do: MCPToolPolicy.record_vfs_edit(sequence)

  defp transition_vfs_sequence(_ctx, _name, _args, sequence, _result), do: sequence

  defp open_projection(result, ctx) do
    sequence = %{
      mount_name: Map.get(result, "mount_name"),
      mounted_at: Map.get(result, "mounted_at")
    }

    committed_projection(ctx, sequence)
  end

  defp committed_projection(ctx, sequence) do
    root = Map.get(ctx, :session_path)
    mount_name = Map.get(sequence, :mount_name)

    case {root, mount_name} do
      {root, mount_name} when is_binary(root) and is_binary(mount_name) ->
        case Ecrits.Fuse.OpenDocs.committed(root, mount_name) do
          {:ok, bytes} -> bytes
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp projection_revision(bytes) when is_binary(bytes), do: :crypto.hash(:sha256, bytes)
  defp projection_revision(_bytes), do: nil

  defp no_vfs_write_failure?(ctx, sequence) do
    case Ecrits.Fuse.OpenDocs.write_failure(
           Map.get(ctx, :session_path),
           Map.get(sequence, :mount_name)
         ) do
      :error -> true
      {:ok, _reason} -> false
    end
  end

  defp no_vfs_stage?(ctx, sequence) do
    case Ecrits.Fuse.OpenDocs.staged(
           Map.get(ctx, :session_path),
           Map.get(sequence, :mount_name)
         ) do
      :error -> true
      {:ok, _bytes, _reason} -> false
    end
  end

  defp log_tool_timing(ctx, name, result, started_at) do
    duration_ms = System.monotonic_time(:millisecond) - started_at
    status = tool_status(result)
    agent_id = Map.get(ctx, :agent_id)

    Logger.debug(fn ->
      "[doc_mcp] tool=#{name} status=#{status} duration_ms=#{duration_ms} agent_id=#{inspect(agent_id)}"
    end)
  end

  defp tool_status({:ok, _result}), do: "ok"
  defp tool_status({:error, %{} = error}), do: "error:#{Map.get(error, "error", "structured")}"
  defp tool_status({:error, reason}) when is_atom(reason), do: "error:#{reason}"
  defp tool_status({:error, {reason, _}}) when is_atom(reason), do: "error:#{reason}"
  defp tool_status({:error, _reason}), do: "error"

  # Build the doc.* tool context (design invariant 3). The agent id from the
  # per-agent MCP url resolves — via `Workspace.Session.fetch_agent/1` — to the
  # live agent session; we read ITS doc context (`active_doc` = the doc this agent is
  # bound to) and dispatch the tool there. The result is `%{pool, agent_id,
  # active_doc}`: `doc.context` returns THIS agent's active doc, and
  # `doc.open`/`doc.edit` honour per-agent ownership — never a global
  # `Pool.active`.
  #
  # An absent agent id (legacy bare mount, or a non-agent caller in a test) keeps
  # the prior pool-only context so direct `Tools.call(%{pool: …}, …)` behaviour is
  # preserved. An agent id that does NOT resolve (dead/unknown) is rejected so a
  # tool never silently runs against the wrong context. `document_path` is the
  # UI-selected workspace path and is surfaced by `doc.context.current_document`
  # so agents do not need prompt-embedded document names.
  defp resolve_tool_context(nil), do: {:ok, %{pool: Ecrits.Doc.Pool}}

  defp resolve_tool_context(agent_id) when is_binary(agent_id) do
    case WorkspaceSession.fetch_agent(agent_id) do
      {:ok, pid} ->
        %{active_doc: active_doc, workspace_root: workspace_root} =
          tc = AgentSession.tool_context(pid)

        {:ok,
         %{
           pool: Ecrits.Doc.Pool,
           agent_id: agent_id,
           agent_session: pid,
           active_doc: active_doc,
           # The workspace path that keys this agent's `Ecrits.Workspace.Session`,
           # so the doc.* tools reach Session for per-doc ownership (invariant 2),
           # the human-viewer registry, and the wasm/NIF routing decision — the
           # real home of what Phase 2 parked in the global Pool.
           session_path: workspace_root,
           document_path: Map.get(tc, :document_path),
           instance_id: Map.get(tc, :instance_id),
           turn_id: Map.get(tc, :turn_id),
           # Honour the workspace access-control setting server-side: the doc.*
           # tools run in-process and bypass the agent CLI sandbox, so without
           # this a read-only agent could still write. Defaults false when the
           # tool_context predates this field.
           read_only: Map.get(tc, :read_only, false)
         }}

      :error ->
        {:error, %{"error" => "agent_not_found", "agent_id" => agent_id}}
    end
  end

  defp to_mcp_tool(%{"namespace" => ns, "name" => name} = tool) do
    %{
      name: ns <> "." <> name,
      description: tool["description"],
      inputSchema: tool["inputSchema"] || %{"type" => "object"},
      annotations: tool["annotations"] || %{}
    }
  end

  defp json_content(value) do
    %{type: "text", text: Jason.encode!(value)}
  end

  defp text_content(text) do
    %{type: "text", text: to_string(text)}
  end

  defp format_error({:unknown_tool, name}), do: "Unknown tool: #{name}"
  defp format_error({:invalid_params, message}), do: "Invalid params: #{message}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
