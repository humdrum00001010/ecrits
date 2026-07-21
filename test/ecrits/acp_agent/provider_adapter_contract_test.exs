defmodule Ecrits.AcpAgent.ProviderAdapterContractTest do
  use ExUnit.Case, async: true

  alias Ecrits.AcpAgent
  alias Ecrits.AcpAgent.AcpStream
  alias Ecrits.AcpAgent.ClaudeAdapter
  alias Ecrits.AcpAgent.CodexAdapter
  alias EcritsWeb.FakeAcpAdapter

  @behaviour ExMCP.ACP.Adapter

  describe "provider wrapper selection" do
    test "routes every provider through an Ecrits-owned wrapper" do
      assert {:ok, %{exmcp_adapter: CodexAdapter}} = AcpAgent.fetch_provider("codex")
      assert {:ok, %{exmcp_adapter: ClaudeAdapter}} = AcpAgent.fetch_provider("claude")
    end
  end

  describe "official ExMCP adapter callback contract" do
    test "Codex wrapper exposes the callbacks Ecrits uses" do
      assert_callbacks(CodexAdapter,
        required: [init: 1, command: 1, translate_outbound: 2, translate_inbound: 2],
        optional: [
          capabilities: 0,
          post_connect: 1,
          modes: 0,
          config_options: 0,
          auth_methods: 1
        ]
      )
    end

    test "Codex receives the Ecrits doc server as an explicit HTTP MCP server" do
      {:ok, state} = CodexAdapter.init([])
      [%{"url" => doc_url} = doc_server] = AcpAgent.mcp_servers("agent-1")

      message = %{
        "method" => "session/new",
        "id" => 2,
        "params" => %{
          "cwd" => "/tmp/project",
          "mcpServers" => [doc_server]
        }
      }

      assert {:ok, data, _state} = CodexAdapter.translate_outbound(message, state)
      wire = Jason.decode!(data)

      assert get_in(wire, ["params", "config", "mcp_servers", "doc", "url"]) ==
               doc_url
    end

    @tag :tmp_dir
    test "Codex prefers a stable installed CLI over a transient package-runner shim", %{
      tmp_dir: tmp_dir
    } do
      transient_dir = Path.join([tmp_dir, "bunx-cache", "node_modules", ".bin"])
      stable_dir = Path.join(tmp_dir, "stable-bin")
      transient = put_fake_executable!(transient_dir, "codex")
      stable = put_fake_executable!(stable_dir, "codex")
      search_path = Enum.join([transient_dir, stable_dir], ":")

      assert CodexAdapter.command(codex_search_path: search_path) ==
               {stable, ["app-server"]}

      assert CodexAdapter.command(codex_search_path: transient_dir) ==
               {transient, ["app-server"]}
    end

    test "Claude wrapper exposes the callbacks Ecrits uses" do
      assert_callbacks(ClaudeAdapter,
        required: [init: 1, command: 1, translate_outbound: 2, translate_inbound: 2],
        optional: [
          env: 1,
          capabilities: 0,
          post_connect: 1,
          modes: 0,
          config_options: 0,
          auth_methods: 1,
          auth_methods: 2,
          list_sessions: 2,
          fork_session: 2
        ]
      )
    end

    test "Claude wrapper keys Ecrits MCP descriptors without changing permission mode" do
      {_command, args} =
        ClaudeAdapter.command(
          mcp_servers: [
            %{
              "name" => "doc",
              "url" => "http://127.0.0.1:4000/mcp/doc-tools/agent-1"
            }
          ],
          permission_mode: "dontAsk"
        )

      mcp_config = args |> option_value("--mcp-config") |> Jason.decode!()

      assert mcp_config == %{
               "mcpServers" => %{
                 "doc" => %{
                   "type" => "http",
                   "url" => "http://127.0.0.1:4000/mcp/doc-tools/agent-1"
                 }
               }
             }

      assert option_value(args, "--permission-mode") == "dontAsk"
    end
  end

  describe "official adapter results" do
    test "fake lifecycle requests reply with ACP session result maps" do
      {:ok, state} = FakeAcpAdapter.init([])

      assert {:reply, %{"sessionId" => new_session_id}, state} =
               FakeAcpAdapter.translate_outbound(%{"method" => "session/new"}, state)

      assert is_binary(new_session_id)
      assert new_session_id != ""

      for method <- ["session/load", "session/resume"] do
        session_id = "remembered-#{method}"

        assert {:reply, %{"sessionId" => ^session_id}, _state} =
                 FakeAcpAdapter.translate_outbound(
                   %{"method" => method, "params" => %{"sessionId" => session_id}},
                   state
                 )
      end
    end
  end

  describe "official completion semantics" do
    test "drops an official final message after its deltas were already emitted" do
      delta = %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => "Contract complete."}
      }

      final = %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => "Contract complete."},
        "_meta" => %{"ex_mcp" => %{"final" => true}}
      }

      assert {:event, %{type: :text_delta, delta: "Contract complete."}, state} =
               AcpStream.map_session_update(delta, AcpStream.update_state())

      assert {:skip, ^state} = AcpStream.map_session_update(final, state)
    end

    test "a refusal stop reason fails the turn" do
      turn = %{input: "Fill the contract", workspace_root: File.cwd!()}

      assert_raise RuntimeError, ~r/refusal/i, fn ->
        __MODULE__
        |> AcpStream.turn_stream(turn,
          timeout: 1_000,
          initial_activity_timeout: 1_000
        )
        |> Enum.to_list()
      end
    end
  end

  defp assert_callbacks(adapter, groups) do
    _ = Code.ensure_loaded(adapter)

    missing =
      groups
      |> Keyword.values()
      |> List.flatten()
      |> Enum.reject(fn {name, arity} -> function_exported?(adapter, name, arity) end)

    assert missing == [], "#{inspect(adapter)} is missing callbacks: #{inspect(missing)}"
  end

  defp option_value(args, option) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^option, value] -> value
      _pair -> nil
    end)
  end

  defp put_fake_executable!(dir, name) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  # Minimal refusal-only adapter used to exercise the real AcpStream prompt
  # completion boundary without widening the shared fake adapter during RED.
  @impl true
  def init(_opts), do: {:ok, %{session_id: "refusal-session"}}

  @impl true
  def command(_opts), do: :one_shot

  @impl true
  def capabilities, do: %{}

  @impl true
  def translate_outbound(%{"method" => "session/new"}, state) do
    {:reply, %{"sessionId" => state.session_id}, state}
  end

  def translate_outbound(%{"method" => "session/prompt", "id" => id}, state) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "sessionId" => state.session_id,
        "stopReason" => "refusal"
      }
    }

    {:one_shot, fn -> {:ok, [Jason.encode!(response)]} end, state}
  end

  def translate_outbound(_message, state), do: {:ok, :skip, state}

  @impl true
  def translate_inbound(_line, state), do: {:skip, state}
end
