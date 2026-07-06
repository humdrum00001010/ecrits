defmodule EcritsWeb.LocalEhwpRuntimeStub do
  def available?, do: true

  def open(path, opts) when is_binary(path) do
    handle = %{
      path: path,
      page_count: Keyword.get(opts, :page_count, 2),
      owner: Keyword.get(opts, :owner),
      block_page: Keyword.get(opts, :block_page),
      error_page: Keyword.get(opts, :error_page)
    }

    {:ok, handle, %{page_count: handle.page_count}}
  end

  def page_count(handle), do: handle.page_count
  def profile(handle), do: %{page_count: handle.page_count}

  def render_page_svg(%{error_page: page_index}, page_index), do: {:error, :test_error}

  def render_page_svg(%{owner: owner, block_page: page_index}, page_index) when is_pid(owner) do
    send(owner, {:ehwp_render_blocked, self(), page_index})

    receive do
      :continue_ehwp_render -> :ok
    end

    render_page(page_index)
  end

  def render_page_svg(_handle, page_index), do: render_page(page_index)

  defp render_page(page_index) do
    svg =
      ~s(<svg data-ehwp-test-page="#{page_index}" viewBox="0 0 10 10"><text>#{page_index + 1}</text></svg>)

    {:ok, svg, %{page_index: page_index}}
  end

  def read(_handle, opts), do: {:ok, {:read, opts}}
  def find(_handle, pattern, opts), do: {:ok, {:find, pattern, opts}}

  def write(%{owner: owner, path: path}, op, opts) when is_pid(owner) do
    send(owner, {:ehwp_write, path, op, opts})
    {:ok, {:write, op, opts}}
  end

  def write(_handle, op, opts), do: {:ok, {:write, op, opts}}

  def input(%{owner: owner, path: path}, event, opts) when is_pid(owner) do
    send(owner, {:ehwp_input, path, event, opts})
    {:ok, {:input, event, opts}}
  end

  def input(_handle, event, opts), do: {:ok, {:input, event, opts}}

  def close(%{owner: owner, path: path}) when is_pid(owner) do
    send(owner, {:ehwp_closed, path})
    :ok
  end

  def close(_handle), do: :ok
end

defmodule EcritsWeb.Local.MountWorkspaceLiveTest do
  use EcritsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecrits.Local.AcpAgent
  alias Ecrits.Local.AcpAgent.Session, as: AgentSession
  alias Ecrits.Local.Document
  alias Ecrits.Local.WorkspaceHandoff
  alias EcritsWeb.LocalDirectoryPickerStub
  alias EcritsWeb.LocalWorkspaceAdapterStub

  setup %{conn: conn} do
    previous = Application.get_env(:ecrits, :local_workspace_adapter)
    previous_directory_picker = Application.get_env(:ecrits, :local_directory_picker)
    previous_directory_picker_stub = Application.get_env(:ecrits, :local_directory_picker_stub)
    previous_agent = Application.get_env(:ecrits, :local_agent)
    previous_agent_ui = Application.get_env(:ecrits, :local_agent_ui)
    previous_local_ehwp_opts = Application.get_env(:ecrits, :local_ehwp_opts)
    Application.put_env(:ecrits, :local_workspace_adapter, LocalWorkspaceAdapterStub)
    Application.put_env(:ecrits, :local_directory_picker, LocalDirectoryPickerStub)
    Application.put_env(:ecrits, :local_ehwp_opts, runtime: EcritsWeb.LocalEhwpRuntimeStub)

    Application.put_env(
      :ecrits,
      :local_directory_picker_stub,
      {:ok, LocalDirectoryPickerStub.valid_path()}
    )

    prepare_local_workspace_fixture()

    # The foreground agent is now owned by the path-keyed `Ecrits.Workspace.Session`
    # (durable, shared across tests at the same `valid_path()`). Clear any Session
    # left over from a prior test so each test starts with a fresh agent — without
    # this, a leaked in-flight turn / provider thread bleeds across tests.
    stop_workspace_session(LocalWorkspaceAdapterStub.valid_path())

    live_session_id = "mount-workspace-test-#{System.unique_integer([:positive])}"

    :ok =
      WorkspaceHandoff.put_workspace_path(live_session_id, LocalWorkspaceAdapterStub.valid_path())

    conn = Phoenix.ConnTest.init_test_session(conn, %{local_live_session_id: live_session_id})

    on_exit(fn ->
      stop_workspace_session(LocalWorkspaceAdapterStub.valid_path())
      cleanup_local_workspace_fixture()

      if previous do
        Application.put_env(:ecrits, :local_workspace_adapter, previous)
      else
        Application.delete_env(:ecrits, :local_workspace_adapter)
      end

      if previous_directory_picker do
        Application.put_env(:ecrits, :local_directory_picker, previous_directory_picker)
      else
        Application.delete_env(:ecrits, :local_directory_picker)
      end

      if previous_directory_picker_stub do
        Application.put_env(
          :ecrits,
          :local_directory_picker_stub,
          previous_directory_picker_stub
        )
      else
        Application.delete_env(:ecrits, :local_directory_picker_stub)
      end

      if previous_agent_ui do
        Application.put_env(:ecrits, :local_agent_ui, previous_agent_ui)
      else
        Application.delete_env(:ecrits, :local_agent_ui)
      end

      if previous_agent do
        Application.put_env(:ecrits, :local_agent, previous_agent)
      else
        Application.delete_env(:ecrits, :local_agent)
      end

      if previous_local_ehwp_opts do
        Application.put_env(:ecrits, :local_ehwp_opts, previous_local_ehwp_opts)
      else
        Application.delete_env(:ecrits, :local_ehwp_opts)
      end
    end)

    {:ok, conn: conn, local_live_session_id: live_session_id}
  end

  test "root renders unauthenticated mount screen", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/")

    assert has_element?(lv, "#local-mount-root")
    assert has_element?(lv, "a[aria-label='Ecrits'][href='/']")
    assert has_element?(lv, "#local-native-directory-picker[data-role='native-directory-picker']")
    assert has_element?(lv, "#local-mount-picker-surface[data-role='mount-picker-surface']")
    assert has_element?(lv, "#local-mount-control-row[data-role='mount-control-row']")
    assert has_element?(lv, "#local-mount-control-row #local-mount-choose", "Open folder")
    assert has_element?(lv, "#local-mount-control-row #local-path-form[phx-submit='open_path']")

    assert has_element?(
             lv,
             "#local-mount-control-row #local-path-input[name='local_path[path]']"
           )

    assert has_element?(
             lv,
             "#local-mount-control-row #local-path-submit[type='submit'][aria-label='Open path'][title='Open this path']"
           )

    assert has_element?(lv, "#local-path-submit", "Open")
    refute has_element?(lv, "#local-manual-path-picker")
    refute has_element?(lv, "#local-provider-picker")
    refute has_element?(lv, "#local-agent-provider-picker")
    refute has_element?(lv, "#local-directory-picker[data-role='directory-picker']")
    refute has_element?(lv, "#local-mount-submit")
    refute has_element?(lv, "#local-mount-form")
    refute has_element?(lv, "#local-mount-path")
    refute html =~ "data-picker-path"
    refute html =~ "You must log in"
  end

  test "provider favicons are served from static assets", %{conn: conn} do
    conn = get(conn, "/images/icons/openai-blossom.svg")

    assert response(conn, 200) =~ "<svg"
    assert get_resp_header(conn, "content-type") == ["image/svg+xml"]

    conn = get(recycle(conn), "/images/icons/claude-favicon.ico")

    assert byte_size(response(conn, 200)) > 0
    assert get_resp_header(conn, "content-type") != []
  end

  test "agent provider setup page renders login and install commands", %{conn: conn} do
    put_provider_integrations!([
      %{
        id: "claude",
        label: "Claude CLI/ACP",
        status: :login_required,
        detail: "Run claude auth login"
      }
    ])

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/local/agent-providers/claude/setup?#{[return_to: "/workspace"]}"
      )

    assert has_element?(
             lv,
             "#local-agent-provider-setup[data-provider='claude'][data-status='login_required']"
           )

    assert has_element?(lv, "#local-agent-provider-current-status", "Login required")

    assert has_element?(
             lv,
             "#local-agent-provider-install-command",
             "curl -fsSL https://claude.ai/install.sh | bash"
           )

    assert has_element?(lv, "#local-agent-provider-login-command", "claude auth login")
    assert has_element?(lv, "#local-agent-provider-check-command", "claude auth status")

    assert has_element?(lv, "a#local-agent-provider-return[href]", "Workspace")
  end

  test "invalid mount path renders inline error", %{conn: conn} do
    Application.put_env(:ecrits, :local_directory_picker_stub, {:ok, "/not-here"})

    {:ok, lv, _html} = live(conn, ~p"/")

    lv
    |> element("#local-mount-choose")
    |> render_click()

    render_async(lv)

    assert has_element?(lv, "#local-mount-error", "Workspace path does not exist.")
    assert has_element?(lv, "#local-mount-picker-surface")
  end

  test "workspace path query is ignored in favor of the session handoff", %{conn: conn} do
    file_path = Path.join(LocalWorkspaceAdapterStub.valid_path(), "not-a-directory.txt")
    File.write!(file_path, "not a directory")

    {:ok, lv, _html} = live(conn, ~p"/workspace?#{[path: file_path]}")

    assert has_element?(lv, "#local-workspace-grid")
    refute has_element?(lv, "#local-mount-error")
  end

  test "native picker unavailable renders inline error", %{conn: conn} do
    Application.put_env(:ecrits, :local_directory_picker_stub, {
      :error,
      {:native_picker_unavailable, "Native folder picker is unavailable on this OS."}
    })

    {:ok, lv, _html} = live(conn, ~p"/")

    lv
    |> element("#local-mount-choose")
    |> render_click()

    render_async(lv)

    assert has_element?(
             lv,
             "#local-mount-error",
             "Native folder picker is unavailable on this OS."
           )
  end

  test "native picker runs asynchronously while the mount screen stays responsive", %{conn: conn} do
    Application.put_env(:ecrits, :local_directory_picker_stub, {
      :await,
      self(),
      {:error, :cancelled}
    })

    {:ok, lv, _html} = live(conn, ~p"/")

    lv
    |> element("#local-mount-choose")
    |> render_click()

    assert_receive {:directory_picker_started, picker_pid}
    assert has_element?(lv, "#local-mount-choose[disabled][data-busy='true']", "Opening picker")

    send(picker_pid, :release_directory_picker)
    render_async(lv)

    assert has_element?(lv, "#local-mount-error", "Folder selection canceled.")
    assert has_element?(lv, "#local-mount-choose[data-busy='false']", "Open folder")
  end

  test "manual path form submits through LiveView without URL state", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")

    assert has_element?(
             lv,
             "#local-path-form[phx-submit='open_path'] #local-path-input[name='local_path[path]']"
           )
  end

  test "valid mount path navigates to workspace shell", %{conn: conn} do
    put_provider_integrations!(ready_provider_integrations())

    Application.put_env(:ecrits, :local_directory_picker_stub, {
      :await,
      self(),
      {:ok, LocalDirectoryPickerStub.valid_path()}
    })

    {:ok, lv, _html} = live(conn, ~p"/")

    lv
    |> element("#local-mount-choose")
    |> render_click()

    assert_receive {:directory_picker_started, picker_pid}
    assert has_element?(lv, "#local-mount-choose[disabled][data-busy='true']", "Opening picker")
    send(picker_pid, :release_directory_picker)

    assert_redirect(lv, ~p"/workspace")

    {:ok, workspace_lv, _html} = live(conn, ~p"/workspace")

    assert has_element?(workspace_lv, "#local-workspace-root")
    assert has_element?(workspace_lv, "a[aria-label='Ecrits'][href='/workspace']")
    assert has_element?(workspace_lv, "#local-workspace-root[class*='overflow-hidden']")
    assert has_element?(workspace_lv, "#local-workspace-grid[phx-hook='LocalChatRailResizer']")
    assert has_element?(workspace_lv, "#local-workspace-grid[data-office-asset-version]")
    assert has_element?(workspace_lv, "#local-workspace-grid[class*='h-full']")
    assert has_element?(workspace_lv, "#local-workspace-grid[class*='isolate']")
    assert has_element?(workspace_lv, "#local-workspace-grid[style*='--local-editor-z']")
    assert has_element?(workspace_lv, "#local-workspace-grid[style*='--local-agent-rail-z']")
    assert has_element?(workspace_lv, "#local-workspace-grid[class*='overflow-hidden']")
    refute has_element?(workspace_lv, "#local-workspace-grid[class*='max-lg:']")

    assert has_element?(
             workspace_lv,
             "#local-workspace-grid[class*='--local-chat-rail-width']"
           )

    assert has_element?(
             workspace_lv,
             "#local-workspace-grid[class*='--local-file-tree-width']"
           )

    assert has_element?(
             workspace_lv,
             "#local-file-tree-panel[data-component='repo-browser'][data-local-file-tree-panel='true'][data-collapsed='false'][class*='overflow-hidden']"
           )

    assert has_element?(
             workspace_lv,
             "#local-editor-shell[data-local-editor-shell='true'][class*='z-[var(--local-editor-z)]']"
           )

    assert has_element?(workspace_lv, "#local-file-tree-panel [data-role='repo-browser-header']")

    assert has_element?(
             workspace_lv,
             "#local-file-tree-panel > #local-file-tree-content:first-child > div:first-child[data-role='repo-browser-header'][data-action='collapse-file-tree']"
           )

    assert has_element?(workspace_lv, "#local-file-tree-content[data-role='file-tree-content']")

    assert has_element?(
             workspace_lv,
             ~s(button#local-file-node-template-hwp[data-role="repo-browser-row"][phx-click="open_file"][phx-value-path="template.hwp"])
           )

    refute has_element?(workspace_lv, ~s(button#local-file-node-template-hwp[data-phx-link]))
    refute has_element?(workspace_lv, ~s(button#local-file-node-template-hwp[href]))

    assert has_element?(
             workspace_lv,
             ~s(#local-file-tree-resizer[data-role="file-tree-resizer"][aria-label="Resize file tree"][class*="block"])
           )

    assert has_element?(
             workspace_lv,
             ~s(#local-file-tree-hide[data-role="file-tree-hide"][aria-label="Hide file tree"][aria-controls="local-file-tree-content"][aria-expanded="true"])
           )

    assert has_element?(
             workspace_lv,
             ~s(#local-file-tree-restore[data-role="file-tree-restore"][class*="hidden"])
           )

    assert has_element?(
             workspace_lv,
             ~s(#local-file-tree-show[data-role="file-tree-show"][aria-label="Show file tree"][aria-controls="local-file-tree-content"][aria-expanded="false"])
           )

    refute has_element?(workspace_lv, "#local-file-tree-breadcrumb")
    assert has_element?(workspace_lv, "#local-agent-sidebar[data-default-visible='true']")
    assert has_element?(workspace_lv, "#local-agent-sidebar[class*='relative']")

    assert has_element?(
             workspace_lv,
             "#local-agent-sidebar[class*='z-[var(--local-agent-rail-z)]']"
           )

    assert has_element?(workspace_lv, "#local-agent-sidebar[class*='overflow-visible']")

    assert has_element?(
             workspace_lv,
             "#local-agent-rail-resizer[data-role='chat-rail-resizer'][aria-label='Resize chat rail'][class*='block']"
           )

    assert has_element?(workspace_lv, "#local-agent-sidebar[data-agent-status='idle']")

    assert has_element?(
             workspace_lv,
             "#local-agent-sidebar [data-role='chat-rail-body'][class*='overflow-visible']"
           )

    assert has_element?(workspace_lv, "#local-agent-thread[class*='overflow-y-auto']")

    assert has_element?(
             workspace_lv,
             "form#local-agent-provider-options[data-role='provider-options']"
           )

    assert has_element?(
             workspace_lv,
             "form#local-agent-provider-options[data-selected-provider='codex'][data-selected-model='gpt-5.5'][data-selected-reasoning='medium'][data-selected-access='read-only'] details#local-agent-model-select[data-role='agent-model-select'][data-selected-provider='codex'][data-selected-model='gpt-5.5']",
             "GPT-5.5"
           )

    assert has_element?(
             workspace_lv,
             "#local-agent-model-select[class*='max-w-32'] > summary[class*='max-w-32']"
           )

    refute has_element?(workspace_lv, "#local-agent-model-select > summary[class*='w-full']")

    refute has_element?(workspace_lv, "#local-agent-model-select option")
    refute has_element?(workspace_lv, "#local-agent-provider-options option[value='fake']")
    refute has_element?(workspace_lv, "#local-agent-provider-options option[value='external']")

    assert has_element?(
             workspace_lv,
             "form#local-agent-provider-options details#local-agent-reasoning-select[data-role='provider-reasoning-select'][data-selected-reasoning='medium'] button#local-agent-inline-reasoning-medium[data-selected='true']",
             "Medium - balanced reasoning/tokens"
           )

    assert has_element?(
             workspace_lv,
             "form#local-agent-provider-options details#local-agent-reasoning-select [class*='right-0']"
           )

    assert has_element?(
             workspace_lv,
             "form#local-agent-provider-options details#local-agent-access-select[data-role='agent-access-control'][data-selected-access='read-only'] button#local-agent-inline-access-read-only[data-selected='true']",
             "Read only"
           )

    refute has_element?(workspace_lv, "select#local-agent-reasoning-select")
    refute has_element?(workspace_lv, "select#local-agent-access-select")

    refute has_element?(workspace_lv, "#local-agent-provider-picker")
    refute has_element?(workspace_lv, "#local-agent-provider-integrations")
    refute has_element?(workspace_lv, "#local-agent-modal-reasoning-select")
    refute has_element?(workspace_lv, "#local-agent-modal-access-control")

    refute has_element?(workspace_lv, "#local-agent-model-modal")

    assert has_element?(
             workspace_lv,
             "#local-agent-model-select button#local-agent-inline-model-gpt-5\\.5[data-role='agent-model-option'][data-provider='codex'][data-selected='true']",
             "GPT-5.5"
           )

    assert has_element?(
             workspace_lv,
             "#local-agent-model-select [data-role='agent-model-menu'][class*='left-0'][class*='overflow-y-auto']"
           )

    assert has_element?(
             workspace_lv,
             "#local-agent-model-select [data-role='agent-model-option-label'][class*='whitespace-normal']",
             "GPT-5.3 Codex Spark"
           )

    assert has_element?(
             workspace_lv,
             "#local-agent-model-select button#local-agent-inline-model-gpt-5\\.3-codex-spark[data-role='agent-model-option'][data-provider='codex']",
             "GPT-5.3 Codex Spark"
           )

    refute has_element?(
             workspace_lv,
             "#local-agent-model-select button#local-agent-inline-model-claude-opus-4-7"
           )

    assert has_element?(
             workspace_lv,
             "#local-agent-model-select button#local-agent-go-to-provider[phx-click='local_agent_model_modal.open'][data-role='agent-provider-config-open']",
             "Go to provider"
           )

    workspace_lv
    |> element("#local-agent-go-to-provider")
    |> render_click()

    assert has_element?(
             workspace_lv,
             "#local-agent-model-modal[role='dialog'][aria-modal='true'] #local-agent-model-detail-codex[data-provider='codex'][data-selected='true']",
             "Codex"
           )

    assert has_element?(
             workspace_lv,
             "#local-agent-model-modal #local-agent-model-detail-claude[data-provider='claude']",
             "Claude"
           )

    assert has_element?(
             workspace_lv,
             ~s(#local-agent-model-modal #local-agent-model-detail-claude img[src="/images/icons/claude-favicon.ico"])
           )

    assert has_element?(
             workspace_lv,
             "#local-agent-model-modal button#local-agent-model-detail-claude[phx-click='select_local_agent_provider'][phx-value-provider='claude']"
           )

    refute has_element?(workspace_lv, "#local-agent-model-modal [data-provider='fake']")
    refute has_element?(workspace_lv, "#local-agent-model-modal #local-agent-modal-options-form")
    refute has_element?(workspace_lv, "#local-agent-model-modal #local-agent-modal-model-select")

    refute has_element?(
             workspace_lv,
             "#local-agent-model-modal #local-agent-modal-reasoning-select"
           )

    refute has_element?(
             workspace_lv,
             "#local-agent-model-modal #local-agent-modal-access-control"
           )

    refute has_element?(
             workspace_lv,
             "#local-agent-model-modal button[data-role='provider-reasoning-option']"
           )

    refute has_element?(
             workspace_lv,
             "#local-agent-model-modal button[data-role='agent-access-option']"
           )

    refute has_element?(workspace_lv, "#local-agent-model-modal button[data-provider='fake']")
    refute has_element?(workspace_lv, "#local-agent-model-modal button[data-provider='external']")

    workspace_lv
    |> element("#local-agent-model-modal-close")
    |> render_click()

    refute has_element?(workspace_lv, "#local-agent-model-modal")

    assert has_element?(workspace_lv, "form#local-agent-form[data-role='chat-form']")

    assert has_element?(
             workspace_lv,
             "form#local-agent-form #local-agent-input[name='agent[message]']"
           )

    refute has_element?(workspace_lv, "form#local-agent-form #local-agent-model-select")
    refute has_element?(workspace_lv, "form#local-agent-form #local-agent-reasoning-select")
    refute has_element?(workspace_lv, "form#local-agent-form #local-agent-access-select")
    assert has_element?(workspace_lv, "#local-agent-upload[data-role='chat-upload']")

    assert has_element?(
             workspace_lv,
             ~s(#local-agent-provider-options input[type="file"][name="local_document_import"][data-role="local-document-upload-file-input"])
           )

    assert has_element?(workspace_lv, "#local-agent-submit", "Send")
  end

  test "workspace chat rail reasoning option is selectable", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    assert has_element?(
             lv,
             "#local-agent-provider-options #local-agent-reasoning-select button#local-agent-inline-reasoning-minimal",
             "Minimal - fastest, least tokens"
           )

    assert has_element?(
             lv,
             "#local-agent-provider-options #local-agent-reasoning-select button#local-agent-inline-reasoning-low",
             "Low - light reasoning, lower tokens"
           )

    assert has_element?(
             lv,
             "#local-agent-provider-options #local-agent-reasoning-select button#local-agent-inline-reasoning-medium[data-selected='true']",
             "Medium - balanced reasoning/tokens"
           )

    assert has_element?(
             lv,
             "#local-agent-provider-options #local-agent-reasoning-select button#local-agent-inline-reasoning-xhigh",
             "XHigh - maximum reasoning/tokens"
           )

    lv
    |> element("#local-agent-inline-reasoning-high")
    |> render_click()

    # #42: reasoning persists in the durable session, NOT the URL — the click
    # does NOT push_patch; it updates the bound config in place (the selection is
    # reflected in the re-rendered control below).
    assert has_element?(
             lv,
             "#local-agent-provider-options #local-agent-reasoning-select[data-selected-reasoning='high'] button#local-agent-inline-reasoning-high[data-selected='true']",
             "High - deeper reasoning, more tokens"
           )
  end

  test "workspace chat rail provider detail switches provider", %{conn: conn} do
    put_provider_integrations!(ready_provider_integrations())

    {:ok, lv, _html} = open_workspace(conn)

    lv
    |> element("#local-agent-go-to-provider")
    |> render_click()

    lv
    |> element("#local-agent-model-detail-claude")
    |> render_click()

    assert has_element?(
             lv,
             "#local-agent-provider-options[data-selected-provider='claude'][data-selected-model='default'] #local-agent-model-select[data-selected-provider='claude'][data-selected-model='default']",
             "Default"
           )

    refute has_element?(
             lv,
             "#local-agent-model-select button[data-role='agent-model-option'][data-provider='codex']"
           )

    refute has_element?(lv, "#local-agent-model-select option")
  end

  test "workspace provider detail opens setup tab when provider is not configured", %{conn: conn} do
    put_provider_integrations!([
      %{
        id: "codex",
        label: "Codex CLI/ACP",
        status: :ready,
        detail: "codex at /bin/codex"
      },
      %{
        id: "claude",
        label: "Claude CLI/ACP",
        status: :missing,
        detail: "Install claude"
      }
    ])

    {:ok, lv, _html} = open_workspace(conn)

    lv
    |> element("#local-agent-go-to-provider")
    |> render_click()

    assert has_element?(
             lv,
             "#local-agent-model-modal button#local-agent-model-detail-codex[data-role='agent-provider-select'][data-status='ready'][phx-click='select_local_agent_provider']"
           )

    assert has_element?(
             lv,
             ~s(#local-agent-model-modal a#local-agent-model-detail-claude[data-role="agent-provider-setup"][data-status="missing"][target="_blank"][href*="/local/agent-providers/claude/setup"]),
             "install"
           )

    refute has_element?(
             lv,
             "#local-agent-model-modal button#local-agent-model-detail-claude[phx-click='select_local_agent_provider']"
           )
  end

  test "workspace chat rail submits selected inline options to the local agent", %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [echo_opts: true])

    {:ok, lv, _html} = open_workspace(conn)

    assert has_element?(
             lv,
             "form#local-agent-provider-options details#local-agent-model-select[data-role='agent-model-select']"
           )

    assert has_element?(
             lv,
             "form#local-agent-provider-options details#local-agent-reasoning-select[data-role='provider-reasoning-select']"
           )

    assert has_element?(
             lv,
             "form#local-agent-provider-options details#local-agent-access-select[data-role='agent-access-control']"
           )

    refute has_element?(lv, "select#local-agent-reasoning-select")
    refute has_element?(lv, "select#local-agent-access-select")

    refute has_element?(lv, "form#local-agent-provider-options option[value='fake']")
    refute has_element?(lv, "form#local-agent-provider-options option[value='external']")

    lv
    |> element(~s([id="local-agent-inline-model-gpt-5.3-codex-spark"]))
    |> render_click()

    assert has_element?(
             lv,
             "#local-agent-provider-options[data-selected-provider='codex'][data-selected-model='gpt-5.3-codex-spark']"
           )

    # reasoning + access select into the durable SESSION (no URL patch); the
    # submit below proves they were forwarded to the adapter (echoed back).
    lv
    |> element("#local-agent-inline-reasoning-xhigh")
    |> render_click()

    lv
    |> element("#local-agent-inline-access-full-workspace")
    |> render_click()

    session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "selected rail opts"})
    |> render_submit()

    assert_receive {:local_agent_event,
                    %{
                      type: :turn_completed,
                      session_id: ^session_id,
                      text: text
                    }},
                   1_000

    # The selected inline options are forwarded through to the ACP adapter_opts;
    # the fake ex_mcp adapter echoes them back so we can assert the wiring.
    assert text =~ "selected rail opts"
    assert text =~ "model=gpt-5.3-codex-spark"
    assert text =~ "reasoning=xhigh"
    assert text =~ "sandbox=workspace-write"
    assert text =~ "permission=dontAsk"

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="agent"][data-message-status="sent"]),
             "model=gpt-5.3-codex-spark"
           )
  end

  test "workspace chat rail ignores fake provider URL state", %{conn: conn} do
    root = LocalWorkspaceAdapterStub.valid_path()

    {:ok, lv, _html} = live(conn, ~p"/workspace?#{[path: root, provider: "fake"]}")

    assert has_element?(lv, "#local-agent-provider-options[data-selected-provider='codex']")
    assert has_element?(lv, "#local-workspace-grid")
  end

  test "file tree supports expansion, row-open, and format affordances", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    assert has_element?(lv, "#local-file-tree")
    assert has_element?(lv, ~s(#local-file-tree ul[role="tree"]))
    refute has_element?(lv, ~s([data-node-path=".ecrits"]))
    assert has_element?(lv, ~s([data-node-path="Assignment #2"][data-expanded="false"]))
    assert has_element?(lv, ~s([data-node-path="drafts"][data-expanded="false"]))

    assert has_element?(
             lv,
             ~s(button[data-role="repo-browser-row"][data-node-path="template.hwp"][data-openable="true"][data-file-extension="hwp"][phx-click="open_file"])
           )

    assert has_element?(
             lv,
             "#local-file-node-template-hwp[data-bytes-url*='document=template.hwp']"
           )

    refute has_element?(lv, "#local-file-node-template-hwp[href]")
    refute has_element?(lv, ~s(#local-file-node-template-hwp[data-phx-link]))
    refute has_element?(lv, ~s([id^="open-file-"]))
    refute has_element?(lv, "#local-file-tree [data-role='file-extension']")
    refute has_element?(lv, "#disabled-file-Antigravity-dmg")
    refute has_element?(lv, ~s([data-node-path="Antigravity.dmg"]))
    refute has_element?(lv, ~s([data-node-path="drafts/service.hwpx"]))

    lv
    |> element("#toggle-dir-Assignment-2")
    |> render_click()

    assert has_element?(lv, "#local-file-node-Assignment-2[data-expanded='true']")
    refute has_element?(lv, "#local-file-node-Assignment-2 + ul[role='group']")

    lv
    |> element("#toggle-dir-drafts")
    |> render_click()

    assert has_element?(lv, ~s([data-node-path="drafts"][data-expanded="true"]))

    assert has_element?(
             lv,
             ~s(button[data-node-path="drafts/service.hwpx"][data-openable="true"][phx-click="open_file"][data-bytes-url*="document=drafts%2Fservice.hwpx"])
           )

    refute has_element?(lv, "#open-file-drafts-service-hwpx")
    refute has_element?(lv, ~s([id^="open-file-"]))
    refute has_element?(lv, "#preview-file-drafts-reference-docx")
    refute has_element?(lv, "#disabled-file-drafts-notes-xyz")

    assert has_element?(
             lv,
             ~s(button[data-node-path="drafts/reference.docx"][data-openable="true"][data-file-extension="docx"][phx-click="open_file"][data-bytes-url*="document=drafts%2Freference.docx"])
           )

    assert has_element?(
             lv,
             ~s(button[data-node-path="drafts/ledger.xlsx"][data-openable="true"][data-file-extension="xlsx"][phx-click="open_file"][data-bytes-url*="document=drafts%2Fledger.xlsx"])
           )

    lv
    |> element("#toggle-dir-rulebook-md")
    |> render_click()

    assert has_element?(lv, ~s([data-node-path="rulebook.md"][data-expanded="true"]))

    lv
    |> element("#toggle-dir-rulebook-md-acceptance-certificate")
    |> render_click()

    assert has_element?(
             lv,
             "#local-file-node-rulebook-md-acceptance-certificate[data-tree-depth='1']"
           )

    assert has_element?(
             lv,
             "#local-file-node-rulebook-md-acceptance-certificate-acceptance-certificate-md[data-tree-depth='2'][data-openable='true'][phx-click='open_file']"
           )

    refute has_element?(
             lv,
             "#local-file-node-rulebook-md-acceptance-certificate #local-file-node-rulebook-md-acceptance-certificate-acceptance-certificate-md"
           )

    refute has_element?(lv, "#local-rhwp-shell")
    refute has_element?(lv, "#local-rhwp-error")

    open_document(lv, "drafts/service.hwpx")

    assert has_element?(lv, ~s([data-node-path="drafts/service.hwpx"][data-selected="true"]))
    assert has_element?(lv, ~s([data-node-path="drafts/service.hwpx"][class*="bg-base-300/70"]))
    assert has_element?(lv, "#studio-document-tab-drafts-service-hwpx[data-active='true']")
    refute has_element?(lv, "#local-file-tree-breadcrumb")

    sync_liveview(lv)
    assert has_element?(lv, "#local-rhwp-save-state", "Loaded -")

    open_document(lv, "template.hwp")

    refute has_element?(lv, "#local-file-tree-breadcrumb")
  end

  test "document query reopens a local HWPX in the EHWP shell without SaaS upload UI", %{
    conn: conn
  } do
    {:ok, lv, _html} = open_workspace(conn, document: "drafts/service.hwpx")

    assert has_element?(lv, "#local-rhwp-shell")
    assert has_element?(lv, "#local-rhwp-toolbar")
    assert has_element?(lv, "#studio-root[data-component='studio-document-surface']")
    assert has_element?(lv, "#studio-document-header")
    refute has_element?(lv, "#local-file-tree-breadcrumb")
    assert has_element?(lv, "#studio-document-tabs[data-role='document-tabs']")
    assert has_element?(lv, "#studio-document-tab-drafts-service-hwpx[data-active='true']")

    assert has_element?(
             lv,
             "#studio-document-tab-drafts-service-hwpx > button[data-role='document-tab-switch'].h-full"
           )

    assert has_element?(lv, "#studio-document-tab-drafts-service-hwpx", "service.hwpx")
    refute has_element?(lv, "#studio-document-header details")
    refute has_element?(lv, "#studio-document-header summary")
    refute has_element?(lv, "#studio-document-header [data-role='document-picker']")
    refute has_element?(lv, "#document-type-badge")
    refute has_element?(lv, "#studio-export-picker")
    refute has_element?(lv, ~s([data-role="export-picker"]))
    refute has_element?(lv, ~s([data-role="rhwp-export-pdf"]))
    refute has_element?(lv, ~s([data-role="rhwp-export-hwpx"]))
    refute has_element?(lv, ~s([data-role="rhwp-prev-edit-target"]))
    refute has_element?(lv, ~s([data-role="rhwp-next-edit-target"]))
    assert has_element?(lv, "#local-rhwp-fullscreen[data-role='toggle-chat-rail']")
    assert has_element?(lv, "#local-rhwp-save-state", "Loaded -")
    refute has_element?(lv, "#local-rhwp-checkpoint")
    refute has_element?(lv, "#local-rhwp-save")
    refute has_element?(lv, ~s([data-role="rhwp-local-checkpoint"]))
    refute has_element?(lv, ~s([data-role="rhwp-local-save"]))
    assert has_element?(lv, "#local-rhwp-editor-frame.contents")

    assert has_element?(
             lv,
             ~s([data-role="local-hwp-editor"][data-renderer="rhwp-wasm"][data-local-document-format="hwpx"])
           )

    assert has_element?(
             lv,
             ~s([data-role="local-hwp-editor"][phx-hook="WasmHwpEditor"])
           )

    # The browser-WASM hook owns the page-stack DOM (phx-update="ignore") and
    # builds the per-page <canvas> nodes client-side from the streamed bytes, so
    # the server-rendered stack is an empty, hook-owned container.
    assert has_element?(lv, ~s([data-role="local-hwp-pages"][phx-update="ignore"]))
    assert has_element?(lv, ~s([data-role="local-hwp-pages"].ehwp-document-stack--local))

    # The hook fetches the document's raw bytes from the gated read-only route.
    assert has_element?(lv, ~s([data-role="local-hwp-editor"][data-bytes-url]))

    refute render(lv) =~ ~s(phx-hook="Rhwp")
    refute has_element?(lv, ~s([data-role="local-hwp-editor"][data-editable-spec-candidates]))

    refute has_element?(lv, ~s([data-role="canvas-empty-upload-action"]))
    refute has_element?(lv, "#document-direct-upload-input")
    refute has_element?(lv, ~s([phx-hook="DirectR2Upload"]))
  end

  test "local HWP opens the browser-WASM shell and pushes the bytes URL to load", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn, document: "drafts/service.hwpx")

    render_async(lv, 2_000)
    _ = render_local_hwp_editor_html(lv)

    # HWP/HWPX render entirely in the browser now: the server stands up the
    # WasmHwpEditor shell (no server-side SVG stream) and tells the hook where to
    # fetch the document's raw bytes for `new HwpDocument(bytes)`.
    assert has_element?(lv, "#local-rhwp-shell")
    assert has_element?(lv, ~s([data-role="local-hwp-editor"][data-renderer="rhwp-wasm"]))
    assert has_element?(lv, ~s([data-role="local-hwp-editor"][phx-hook="WasmHwpEditor"]))

    # The bytes URL points at the gated read-only route with the workspace +
    # document path, and the server pushes it as `hwp_wasm_load` on open.
    bytes_url =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="local-hwp-editor"]))
      |> LazyHTML.attribute("data-bytes-url")
      |> List.first()

    assert is_binary(bytes_url)
    assert bytes_url =~ "/local/document-bytes?"
    assert bytes_url =~ "document=drafts%2Fservice.hwpx"

    # No server-side page rasterization happens; the hook builds the canvases.
    assert has_element?(lv, ~s([data-role="local-hwp-pages"][phx-update="ignore"]))
  end

  test "document query opens a local DOCX through the client WASM office editor", %{
    conn: conn
  } do
    {:ok, lv, _html} = open_workspace(conn, document: "drafts/reference.docx")

    assert has_element?(lv, "#local-rhwp-shell")
    assert has_element?(lv, "#studio-document-tab-drafts-reference-docx[data-active='true']")
    assert has_element?(lv, "#studio-document-tab-drafts-reference-docx", "reference.docx")

    # Office documents render SOLELY through the in-browser LibreOffice WASM
    # editor (the `WasmOfficeEditor` hook); there is no server-side LOK tile
    # render path.
    assert has_element?(
             lv,
             ~s([data-role="office-wasm-viewer"][data-renderer="libreoffice-wasm"][phx-hook="WasmOfficeEditor"][data-local-document-format="docx"])
           )

    refute has_element?(lv, ~s([data-renderer="libreofficex-png-tiles"]))
    refute has_element?(lv, ~s([data-renderer="libreofficex-lok-edit"]))
    refute has_element?(lv, ~s([data-role="local-hwp-editor"]))
  end

  test "VFS semantic edits replay into the visible active office WASM editor", %{conn: conn} do
    root = LocalWorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "drafts/reference.docx")

    assert_has_element_after_open_sync(
      lv,
      ~s([data-role="office-wasm-viewer"][data-document-path="drafts/reference.docx"])
    )

    assert_push_event(lv, "office_wasm_load", %{url: initial_url}, 1_000)
    refute initial_url =~ "&v="

    op = %{"op" => "replace_text", "query" => "개인신청", "replacement" => "개인 신청"}

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         path: Path.join(root, "drafts/reference.docx"),
         doc: "reference.docx",
         applied: 1,
         highlights: [
           %{
             "kind" => "text",
             "op" => "replace_text",
             "ref" => "p1",
             "text" => "개인 신청"
           }
         ],
         ops: [op]
       }}
    )

    assert_push_event(
      lv,
      "doc.apply_edit",
      %{document_id: document_id, verb: "edit", payload: %{ops: [pushed_op]}},
      1_000
    )

    assert is_binary(document_id)
    assert pushed_op == op
    refute_push_event(lv, "office_wasm_load", %{document_id: ^document_id}, 200)

    sync_liveview(lv)

    bytes_url =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="office-wasm-viewer"]))
      |> LazyHTML.attribute("data-bytes-url")
      |> List.first()

    assert bytes_url == initial_url
  end

  test "VFS edits without semantic ops reload the visible active office WASM editor", %{
    conn: conn
  } do
    root = LocalWorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "drafts/reference.docx")

    assert_has_element_after_open_sync(
      lv,
      ~s([data-role="office-wasm-viewer"][data-document-path="drafts/reference.docx"])
    )

    assert_push_event(lv, "office_wasm_load", %{url: initial_url}, 1_000)
    refute initial_url =~ "&v="

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         path: Path.join(root, "drafts/reference.docx"),
         doc: "reference.docx",
         applied: 1,
         highlights: []
       }}
    )

    assert_push_event(
      lv,
      "office_wasm_load",
      %{document_id: document_id, url: url},
      1_000
    )

    assert is_binary(document_id)
    assert url =~ "/local/document-bytes?"
    assert url =~ "document=drafts%2Freference.docx"
    assert url =~ "&v="

    sync_liveview(lv)

    bytes_url =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="office-wasm-viewer"]))
      |> LazyHTML.attribute("data-bytes-url")
      |> List.first()

    assert bytes_url == url
  end

  test "workspace session restores open document tabs and persisted viewport on remount", %{
    conn: conn
  } do
    root = LocalWorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "document-restore-session", root)

    {:ok, lv, _html} = open_workspace(conn, root, document: "drafts/reference.docx")

    assert_has_element_after_open_sync(
      lv,
      ~s([data-role="office-wasm-viewer"][data-document-path="drafts/reference.docx"])
    )

    render_hook(lv, "local_document.viewport_changed", %{
      "document_path" => "drafts/reference.docx",
      "top" => "321",
      "left" => "7"
    })

    sync_workspace_session(root)
    stop_pid(lv.pid)
    sync_workspace_session(root)

    {:ok, restored_lv, _html} = open_workspace(conn, root)
    render_async(restored_lv, 2_000)
    sync_liveview(restored_lv)

    assert has_element?(
             restored_lv,
             "#studio-document-tab-drafts-reference-docx[data-active='true']"
           )

    assert has_element?(
             restored_lv,
             ~s([data-role="office-wasm-viewer"][data-document-path="drafts/reference.docx"][data-scroll-top="321"][data-scroll-left="7"])
           )
  end

  test "document query opens a local XLSX through the client WASM office editor", %{
    conn: conn
  } do
    {:ok, lv, _html} = open_workspace(conn, document: "drafts/ledger.xlsx")

    assert has_element?(lv, "#local-rhwp-shell")
    assert has_element?(lv, "#studio-document-tab-drafts-ledger-xlsx[data-active='true']")
    assert has_element?(lv, "#studio-document-tab-drafts-ledger-xlsx", "ledger.xlsx")

    assert has_element?(
             lv,
             ~s([data-role="office-wasm-viewer"][data-renderer="libreoffice-wasm"][phx-hook="WasmOfficeEditor"][data-local-document-format="xlsx"])
           )

    refute has_element?(lv, ~s([data-renderer="libreofficex-png-tiles"]))
    refute has_element?(lv, ~s([data-renderer="libreofficex-lok-edit"]))
    refute has_element?(lv, ~s([data-role="local-hwp-editor"]))
  end

  test "file tree open event gives XLSX its own active document tab", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn, document: "drafts/reference.docx")

    assert_has_element_after_open_sync(
      lv,
      ~s([data-role="office-wasm-viewer"][data-local-document-format="docx"])
    )

    assert has_element?(lv, "#studio-document-tab-drafts-reference-docx[data-active='true']")

    render_hook(lv, "open_file", %{"path" => "drafts/ledger.xlsx"})
    render_async(lv)

    assert has_element?(lv, "#studio-document-tab-drafts-reference-docx")
    assert has_element?(lv, "#studio-document-tab-drafts-ledger-xlsx[data-active='true']")
    assert has_element?(lv, "#studio-document-tab-drafts-ledger-xlsx", "ledger.xlsx")

    assert_has_element_after_open_sync(
      lv,
      ~s([data-role="office-wasm-viewer"][data-local-document-format="xlsx"])
    )
  end

  test "document query binds XLSX as the current doc MCP handle on send", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [{:text_delta, "done"}],
        test_pid: self(),
        wait_for: :release_xlsx_context_probe
      ]
    )

    {:ok, lv, _html} = open_workspace(conn, document: "drafts/ledger.xlsx")

    sync_liveview(lv)

    assert_has_element_after_open_sync(
      lv,
      ~s([data-role="office-wasm-viewer"][data-local-document-format="xlsx"])
    )

    session_id = subscribe_agent(lv)
    session_pid = AcpAgent.whereis(session_id)
    assert is_pid(session_pid)

    lv
    |> form("#local-agent-form", agent: %{message: "read this workbook"})
    |> render_submit()

    assert_receive {:local_agent_adapter_waiting, task_pid}, 2_000

    assert %{active_doc: active_doc, document_path: path} = AgentSession.tool_context(session_pid)
    assert is_binary(active_doc) and String.starts_with?(active_doc, "d_xlsx_")
    assert is_binary(path) and String.ends_with?(path, "drafts/ledger.xlsx")

    send(task_pid, :release_xlsx_context_probe)
    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^session_id}}, 2_000
  end

  test "local composer upload imports a selected HWPX into the workspace and opens it", %{
    conn: conn
  } do
    root = LocalWorkspaceAdapterStub.valid_path()
    upload_name = "imported-service.hwpx"
    upload_path = Path.join(root, upload_name)
    upload_bytes = File.read!("test/fixtures/hwpx/real_contract.hwpx")

    refute File.exists?(upload_path)

    {:ok, lv, _html} = open_workspace(conn, root)

    upload =
      file_input(lv, "#local-agent-provider-options", :local_document_import, [
        %{
          name: upload_name,
          content: upload_bytes,
          size: byte_size(upload_bytes),
          type: "application/vnd.hancom.hwpx",
          last_modified: 1_720_000_000_000
        }
      ])

    render_upload(upload, upload_name)

    assert File.read!(upload_path) == upload_bytes
    assert has_element?(lv, "#local-rhwp-shell")

    assert has_element?(
             lv,
             ~s([data-role="local-hwp-editor"][data-local-document-format="hwpx"][data-document-path="#{upload_name}"])
           )

    refute has_element?(lv, "#document-direct-upload-input")
    refute has_element?(lv, ~s([phx-hook="DirectR2Upload"]))
  end

  test "document query opens a local HWP with the same Studio editor surface", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn, document: "template.hwp")

    assert_has_element_after_open_sync(
      lv,
      "#local-rhwp-shell[data-component='studio-local-document-surface']"
    )

    assert_has_element_after_open_sync(lv, "#studio-root[data-local-document-id]")
    assert has_element?(lv, "#studio-document-header")
    refute has_element?(lv, "#local-file-tree-breadcrumb")
    assert has_element?(lv, "#studio-document-tabs[data-role='document-tabs']")
    assert has_element?(lv, "#studio-document-tab-template-hwp[data-active='true']")
    assert has_element?(lv, "#studio-document-tab-template-hwp", "template.hwp")
    refute has_element?(lv, "#studio-document-header details")
    refute has_element?(lv, "#studio-document-header summary")
    refute has_element?(lv, "#studio-document-header [data-role='document-picker']")
    refute has_element?(lv, "#document-type-badge")
    refute has_element?(lv, "#studio-export-picker")
    assert has_element?(lv, "#local-rhwp-fullscreen[data-role='toggle-chat-rail']")

    assert has_element?(
             lv,
             ~s([data-role="local-hwp-editor"][data-local-document-format="hwp"][data-document-path="template.hwp"])
           )
  end

  test "header picker + fullscreen buttons are desktop controls without responsive gates", %{
    conn: conn
  } do
    {:ok, lv, _html} = open_workspace(conn, document: "template.hwp")

    html = render(lv)

    picker_class = header_action_class(html, "#local-document-element-picker")
    assert picker_class =~ "inline-flex"
    refute picker_class =~ "md:inline-flex"
    refute picker_class =~ "lg:inline-flex"

    fullscreen_class = header_action_class(html, "#local-rhwp-fullscreen")
    assert fullscreen_class =~ "inline-flex"
    refute fullscreen_class =~ "md:inline-flex"
    refute fullscreen_class =~ "lg:inline-flex"

    fullscreen_click =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#local-rhwp-fullscreen")
      |> LazyHTML.attribute("phx-click")
      |> List.first()

    assert fullscreen_click =~ "col-span-3"
    refute fullscreen_click =~ "md:col-span-2"
    refute fullscreen_click =~ "lg:col-span-3"
  end

  test "document element picker mode is stored in the workspace session", %{conn: conn} do
    root = LocalWorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwp")

    assert has_element?(lv, "#local-document-element-picker[aria-pressed='false']")

    lv
    |> element("#local-document-element-picker")
    |> render_click()

    assert_push_event(lv, "document_element_picker:set", %{enabled: true}, 1_000)

    assert has_element?(
             lv,
             "#local-document-element-picker[aria-pressed='true'][data-active='true']"
           )

    {:ok, lv2, _html} = open_workspace(conn, root)
    render_async(lv2, 2_000)
    sync_liveview(lv2)

    assert_has_element_after_open_sync(lv2, "#local-document-element-picker[aria-pressed='true']")
    assert has_element?(lv2, "#local-document-element-picker[data-active='true']")
  end

  defp header_action_class(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> List.first()
  end

  test "local employment standard HWP exposes editable specs to the editor", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn, document: "employment_v1.hwp")

    assert has_element?(
             lv,
             ~s([data-role="local-hwp-editor"][data-local-document-format="hwp"][data-document-path="employment_v1.hwp"][data-contract-type-key="employment_v1"])
           )

    refute has_element?(lv, ~s([data-role="local-hwp-editor"][data-editable-spec-candidates]))
  end

  test "copied local employment standard HWP does not expose editable specs to the editor", %{
    conn: conn
  } do
    {:ok, lv, _html} = open_workspace(conn, document: "employment_v1 (1).hwp")

    assert has_element?(
             lv,
             ~s|[data-role="local-hwp-editor"][data-local-document-format="hwp"][data-document-path="employment_v1 (1).hwp"][data-contract-type-key="employment_v1"]|
           )

    refute has_element?(lv, ~s([data-role="local-hwp-editor"][data-editable-spec-candidates]))
  end

  test "local rhwp events load bytes, checkpoint, save, and reload saved bytes", %{conn: conn} do
    root = LocalWorkspaceAdapterStub.valid_path()
    relative_path = "drafts/service.hwpx"
    path = Path.join(root, relative_path)
    original = File.read!(path)

    {:ok, lv, _html} = open_workspace(conn, root, document: relative_path)

    render_async(lv, 2_000)
    _ = render_local_hwp_editor_html(lv)

    document_id = local_rhwp_document_id(lv)

    render_hook(lv, "rhwp.local.load", %{"document_id" => document_id})
    assert has_element?(lv, "#local-rhwp-save-state", "Loaded -")

    render_hook(lv, "rhwp.local.snapshot.checkpoint", %{
      "document_id" => document_id,
      "bytes_base64" => Base.encode64(original),
      "format" => "hwpx"
    })

    assert File.read!(path) == original
    assert has_element?(lv, "#local-rhwp-save-state", "Checkpointed - canonical file unchanged")

    saved = File.read!("test/fixtures/hwpx/real_contract.hwpx")

    render_hook(lv, "rhwp.local.snapshot.save", %{
      "document_id" => document_id,
      "bytes_base64" => Base.encode64(saved),
      "format" => "hwpx"
    })

    assert File.read!(path) == saved
    assert has_element?(lv, "#local-rhwp-save-state", "Saved -")

    {:ok, reloaded_lv, _html} = open_workspace(conn, root, document: relative_path)

    render_async(reloaded_lv, 2_000)
    _ = render_local_hwp_editor_html(reloaded_lv)

    assert has_element?(
             reloaded_lv,
             ~s([data-role="local-hwp-editor"][data-local-document-format="hwpx"])
           )
  end

  test "local rhwp text mutation is acknowledged and does not remount", %{conn: conn} do
    root = LocalWorkspaceAdapterStub.valid_path()

    {:ok, lv, _html} = open_workspace(conn, root, document: "drafts/service.hwpx")

    assert_has_element_after_open_sync(
      lv,
      ~s([data-role="local-hwp-editor"][data-local-document-format="hwpx"][data-document-path="drafts/service.hwpx"])
    )

    pid = lv.pid
    document_id = local_rhwp_document_id(lv)

    render_hook(lv, "rhwp.text.mutated", %{
      "documentId" => document_id,
      "eventId" => "local-edit-1",
      "siteId" => "local",
      "lamport" => 11,
      "body" => %{
        "type" => "TextDeleted",
        "sectionIndex" => 0,
        "paragraphIndex" => 1,
        "charOffset" => 3,
        "count" => 1
      }
    })

    _ = :sys.get_state(pid)
    assert lv.pid == pid

    assert has_element?(
             lv,
             ~s([data-role="local-hwp-editor"][data-local-document-id="#{document_id}"])
           )

    assert {:ok, %Document{id: ^document_id}} = Document.document(document_id)
  end

  test "agent form reports real provider unavailable without fake response", %{conn: conn} do
    missing = "ecrits-codex-missing-#{Ecto.UUID.generate()}"

    Application.put_env(:ecrits, :local_agent_ui,
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        fail_with: "executable_not_found: #{missing}"
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "hello local"})
    |> render_submit()

    assert_receive {:local_agent_event,
                    %{
                      type: :turn_failed,
                      session_id: ^session_id
                    }},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "hello local"
           )

    assert has_element?(
             lv,
             ~s([id^="local-agent-user-"][data-chat-role="chat-message"] [data-role="chat-message-body"]),
             "hello local"
           )

    assert has_element?(lv, "#local-agent-sidebar[data-agent-status='failed']")
    assert has_element?(lv, "#local-agent-error", "Codex ACP unavailable")
    refute render(lv) =~ "Fake response"
  end

  test "agent turn freezes the active local document context", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [{:text_delta, "done"}],
        test_pid: self(),
        wait_for: :release_context_probe
      ]
    )

    root = LocalWorkspaceAdapterStub.valid_path()

    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwp")

    session_id = subscribe_agent(lv)
    session_pid = AcpAgent.whereis(session_id)
    assert is_pid(session_pid)

    lv
    |> form("#local-agent-form", agent: %{message: "read this document"})
    |> render_submit()

    assert_receive {:local_agent_adapter_waiting, task_pid}, 2_000

    # The agent binds doc.* context at send time — the UNIFIED document handle
    # points at what's on screen without relying on idle session mutation.
    assert %{active_doc: active_doc, document_path: path} = AgentSession.tool_context(session_pid)
    assert is_binary(active_doc) and String.starts_with?(active_doc, "d_hwp_")
    assert is_binary(path) and String.ends_with?(path, "template.hwp")

    send(task_pid, :release_context_probe)
    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^session_id}}, 2_000
  end

  test "ordinary document prompt uses VFS mount when available without embedding selected path",
       %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [{:text_delta, "done"}],
        report_prompts: true,
        test_pid: self()
      ]
    )

    root = LocalWorkspaceAdapterStub.valid_path()

    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwp")

    session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "read this document"})
    |> render_submit()

    assert_receive {:fake_acp_prompt, _sid, prompt}, 1_000
    mount_status = Ecrits.Fuse.DocMount.status()
    mounted? = Ecrits.Fuse.DocMount.mounted?(root)
    normalized_prompt = String.replace(prompt, ~r/\s+/, " ")

    cond do
      mount_status.enabled? and mounted? ->
        assert prompt =~ "#{doc_vfs_backend_mode_label(mount_status)} mode"
        assert prompt =~ "The ONLY MCP tool to call is `doc.open_doc"
        assert prompt =~ "doc.open_doc"
        assert prompt =~ "Do not call `doc.close_doc` in normal edit turns"
        assert prompt =~ "NEVER type `doc.open_doc` in the shell"
        assert prompt =~ "resource/tool discovery only to surface `doc.open_doc`"
        assert prompt =~ "Do not use discovery as a substitute for editing"
        assert prompt =~ ".ecrits/mount/<name>.jsonl"
        assert prompt =~ "The JSONL file itself is IR-only"
        assert prompt =~ "does NOT contain `mounted_at`"
        assert prompt =~ "Never treat a missing `mounted_at` field inside"
        assert prompt =~ "NEVER create, copy, or edit a JSONL projection anywhere else"
        assert prompt =~ "/tmp/<name>.jsonl"
        assert prompt =~ "does NOT route to the document"
        assert prompt =~ "[ [ [ payload_node"
        assert prompt =~ "Positional HWPX refs are NOT payload fields"
        assert prompt =~ "The nested list position"
        assert prompt =~ "inside an existing paragraph list"
        assert prompt =~ "not as a metadata object"

        assert normalized_prompt =~
                 "create the temp file inside the same `.ecrits/mount/` directory"

        assert prompt =~ "validate the temp with `jq -c . \"$tmp\"`"
        assert prompt =~ "only if JSON validation succeeds"

        assert normalized_prompt =~
                 "Do NOT use `mktemp`, `dd`, or any temp path outside the mount"

        assert prompt =~ "VFS `create`/`write`/`rename` path"
        assert prompt =~ ~s({"type":"table","cells":[["H1","H2"],["A","B"]],"header":true})

        assert prompt =~ ~s({"type":"picture","src":"/abs/img.png"})
        assert prompt =~ "readable default size"
        assert prompt =~ "intentionally resizing in HWPUNIT"

        assert prompt =~ "Move an existing picture by editing"
        assert prompt =~ "resize by editing `width`/`height`"
        assert prompt =~ "Delete a picture by removing that picture payload"
        assert prompt =~ "immediately AFTER that cell payload"
        assert prompt =~ "Do not edit/reuse an existing picture payload"
        assert prompt =~ "Structural inserts are one-shot"
        assert normalized_prompt =~ "picture appears at the intended nested position"
        assert prompt =~ "ref.cellPath"
        assert prompt =~ "`src` is only embed input"
        assert prompt =~ "do not insert another copy"
        assert prompt =~ "Verify with shell exactly once"

        assert normalized_prompt =~
                 "Do not reopen editor previews or poll `/local/document-bytes`"

        refute prompt =~ "Positional HWPX refs are lists"
        assert prompt =~ "READ with `cat`/`sed -n`"
        assert prompt =~ "FIND with `grep -n`/`rg`"
        assert prompt =~ "there is no doc.save"
        assert prompt =~ "Read-only questions: cat/grep and answer, do not edit"
        assert prompt =~ "No fabrication"
        assert prompt =~ "There is NO doc.read"
        assert prompt =~ "doc.context"
        refute prompt =~ "current_document.document"

      mount_status.enabled? ->
        assert prompt =~ "Doc VFS backend is available, but this workspace is not mounted"
        assert prompt =~ mount_status.message
        assert prompt =~ "doc.open_doc"
        assert prompt =~ "mounted_at"
        assert prompt =~ "mount_status"
        assert prompt =~ "mount_error"
        assert prompt =~ "Do not use `.md`"
        assert normalized_prompt =~ "do not shell-read the raw binary document"
        refute prompt =~ "documents are EDITABLE FILES"

      mount_status.backend == :fskit and
          mount_status.reason in [
            :fskit_extension_disabled,
            :fskit_extension_not_registered,
            :fskit_extension_unsigned
          ] ->
        assert prompt =~ "FSKit/VFS is configured but not mountable"
        assert prompt =~ mount_status.message

        if mount_status.settings_url do
          assert prompt =~ Ecrits.Fuse.DocMount.settings_url()
        end

        assert prompt =~ "mounted_at"
        assert prompt =~ "mount_status"
        assert prompt =~ "Use doc MCP tools"
        assert prompt =~ "doc.context"
        assert prompt =~ "current_document.document"
        assert prompt =~ "doc.open_doc"
        refute prompt =~ "documents are EDITABLE FILES"
        assert prompt =~ "Do not use `.md`"

      true ->
        assert prompt =~ "Use doc MCP tools"
        assert prompt =~ "doc.context"
        assert prompt =~ "current_document.document"
        refute prompt =~ "VFS mode"
    end

    refute prompt =~ "template.hwp"
    refute prompt =~ "pass this as `document`"

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)
  end

  test "manual VFS enable subscribes direct VFS edit cards", %{conn: conn} do
    previous_vfs = Application.get_env(:ecrits, :doc_vfs)
    on_exit(fn -> restore_doc_vfs_env(previous_vfs) end)

    root = LocalWorkspaceAdapterStub.valid_path()
    Application.put_env(:ecrits, :doc_vfs, enabled: false)

    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwp")

    assert has_element?(lv, ~s(#fuse-mode-toggle[aria-pressed="false"]))

    Application.put_env(:ecrits, :doc_vfs, enabled: true)

    cond do
      not Ecrits.Fuse.DocMount.status().enabled? ->
        IO.puts("\n[skip] doc VFS backend unavailable; skipping manual VFS subscription check")

      not match?({:ok, _}, Ecrits.Fuse.DocMount.ensure(root)) ->
        IO.puts("\n[skip] doc VFS mount failed; skipping manual VFS subscription check")

      true ->
        lv
        |> element("#fuse-mode-toggle")
        |> render_click()

        sync_liveview(lv)
        assert Ecrits.Fuse.DocMount.mounted?(root)

        Phoenix.PubSub.broadcast(
          Ecrits.PubSub,
          "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root),
          {:vfs_doc_edited,
           %{
             path: Path.join(root, "template.hwp"),
             doc: "template.hwp",
             applied: 1,
             marker: "SYNTHETIC_VFS_CARD",
             highlights: [
               %{
                 "kind" => "text",
                 "op" => "replace_text",
                 "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
                 "text" => "SYNTHETIC_VFS_CARD"
               }
             ]
           }}
        )

        sync_liveview(lv)

        assert has_element?(
                 lv,
                 ~s([data-role="editor-preview"][data-document-path="template.hwp"])
               )

        assert has_element?(
                 lv,
                 ~s([data-role="local-hwp-editor"][data-editor-mirror="true"][data-preview-text=""][data-preview-highlights*="SYNTHETIC_VFS_CARD"])
               )

        refute has_element?(lv, ~s([data-role="doc-edit-card"]))
    end
  end

  test "VFS property writes are pushed to the open HWP browser editor", %{conn: conn} do
    root = LocalWorkspaceAdapterStub.valid_path()

    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwp")

    assert_has_element_after_open_sync(
      lv,
      ~s([data-role="local-hwp-editor"][data-local-document-format="hwp"][data-document-path="template.hwp"])
    )

    ref = %{
      "section" => 0,
      "paragraph" => 0,
      "offset" => 0,
      "cell" => %{
        "parentParaIndex" => 0,
        "controlIndex" => 0,
        "cellIndex" => 0,
        "cellParaIndex" => 0
      }
    }

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         path: Path.join(root, "template.hwp"),
         doc: "template.hwp",
         applied: 1,
         highlights: [%{"kind" => "set", "ref" => ref, "type" => "cell"}],
         sets: [
           %{
             "ref" => ref,
             "props" => %{"kind" => "cell", "BackgroundColor" => "#CFFAFE"}
           }
         ]
       }}
    )

    assert_push_event(
      lv,
      "doc.apply_edit",
      %{verb: "set", payload: %{sets: [set_payload]}},
      1_000
    )

    assert set_payload["ref"] == ref
    assert set_payload["props"]["BackgroundColor"] == "#CFFAFE"
  end

  test "reselecting full workspace access reapplies VFS write policy", %{conn: conn} do
    previous_vfs = Application.get_env(:ecrits, :doc_vfs)
    root = LocalWorkspaceAdapterStub.valid_path()

    on_exit(fn ->
      _ = Ecrits.Fuse.DocMount.teardown(root)
      restore_doc_vfs_env(previous_vfs)
    end)

    Application.put_env(:ecrits, :doc_vfs, enabled: true)

    cond do
      not Ecrits.Fuse.DocMount.status().enabled? ->
        IO.puts("\n[skip] doc VFS backend unavailable; skipping VFS write-policy hydration check")

      not match?({:ok, _}, Ecrits.Fuse.DocMount.ensure(root)) ->
        IO.puts("\n[skip] doc VFS mount failed; skipping VFS write-policy hydration check")

      true ->
        {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwp")

        lv
        |> element("#local-agent-inline-access-full-workspace")
        |> render_click()

        sync_liveview(lv)
        assert Ecrits.Fuse.OpenDocs.writable?(root)

        Ecrits.Fuse.OpenDocs.set_writable(root, false)
        refute Ecrits.Fuse.OpenDocs.writable?(root)

        lv
        |> element("#local-agent-inline-access-full-workspace")
        |> render_click()

        sync_liveview(lv)
        assert has_element?(lv, ~s([data-selected-access="full-workspace"]))
        assert Ecrits.Fuse.OpenDocs.writable?(root)
    end
  end

  test "selecting a document preserves the chat-rail conversation and session", %{conn: conn} do
    # Regression for the reset-on-document-select bug: opening/selecting a
    # document must NOT recreate the ACP session or wipe the chat stream. The
    # conversation, the session_id, and the backing Session PID must all survive
    # — exactly like the #54 access-change decoupling.
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "streaming reply"}]])

    {:ok, lv, _html} = open_workspace(conn, document: "template.hwp")

    session_id = subscribe_agent(lv)
    session_pid = AcpAgent.whereis(session_id)
    assert is_pid(session_pid)

    # Build a conversation so there is something to lose.
    lv
    |> form("#local-agent-form", agent: %{message: "first question"})
    |> render_submit()

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "first question"
           )

    # Expand the drafts directory so its documents become selectable.
    lv
    |> element("#toggle-dir-drafts")
    |> render_click()

    # Select a DIFFERENT document — the path that previously reset the chat.
    open_document(lv, "drafts/service.hwpx")

    sync_liveview(lv)

    # Same session_id, same backing PID, conversation intact.
    assert local_agent_session_id(lv) == session_id
    assert AcpAgent.whereis(session_id) == session_pid
    assert Process.alive?(session_pid)

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "first question"
           )

    # Select a SECOND, different document (back to the HWP top-level one) —
    # still preserved.
    open_document(lv, "template.hwp")

    sync_liveview(lv)

    assert local_agent_session_id(lv) == session_id
    assert AcpAgent.whereis(session_id) == session_pid
    assert Process.alive?(session_pid)

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "first question"
           )

    # The live session's per-turn document context must follow the active doc,
    # so the agent's doc.* tools still target what the user is viewing — the
    # `document_path` followed the switch back to template.hwp.
    assert {:ok, %{document_path: path}} = AcpAgent.status(nil, session_id)
    assert is_binary(path) and String.ends_with?(path, "template.hwp")
  end

  test "a browser refresh starts a fresh rail and keeps the old chat in recents",
       %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "ack reply"}]])
    root = LocalWorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "refresh-session", root)

    {:ok, lv, _html} = open_workspace(conn, root)

    session_id = subscribe_agent(lv)
    agent_pid = AcpAgent.whereis(session_id)
    assert is_pid(agent_pid)

    # A turn that completes → builds the transcript AND derives the auto-title.
    lv
    |> form("#local-agent-form", agent: %{message: "한 단어로 확인만"})
    |> render_submit()

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    # The durable agent retained the derived title + transcript.
    assert AcpAgent.title(session_id) == "한 단어로 확인만"
    snapshot = AcpAgent.agent_snapshot(session_id)
    assert [%{user: "한 단어로 확인만"} | _] = snapshot.transcript
    refute snapshot.title_user_edited?
    assert has_element?(lv, "#local-agent-title-label[value='한 단어로 확인만']")

    # --- the "refresh": the old LiveView pid dies, then a new one mounts ---
    stop_pid(lv.pid)
    sync_workspace_session(root)

    {:ok, lv2, _html2} = open_workspace(conn, root)

    sync_liveview(lv2)

    # New active rail: refresh survival is intentionally not required.
    new_session_id = subscribe_agent(lv2)
    refute new_session_id == session_id
    assert AcpAgent.whereis(session_id) == agent_pid
    assert Process.alive?(agent_pid)

    assert has_element?(lv2, "#local-agent-title-label[value='New Chat']")

    refute has_element?(
             lv2,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "한 단어로 확인만"
           )

    assert has_element?(lv2, "#local-agent-rail-picker[data-count='2']")

    lv2
    |> element("#local-agent-rail-picker")
    |> render_click()

    assert has_element?(lv2, "#local-agent-rail-option-#{session_id}", "한 단어로 확인만")

    lv2
    |> element("#local-agent-rail-option-#{session_id}")
    |> render_click()

    sync_liveview(lv2)

    assert local_agent_session_id(lv2) == session_id
    assert has_element?(lv2, "#local-agent-title-label[value='한 단어로 확인만']")

    send(
      lv2.pid,
      {:local_agent_event,
       %{session_id: session_id, type: :title_generated, title: "Provider refined title"}}
    )

    sync_liveview(lv2)

    assert has_element?(lv2, "#local-agent-title-label[value='Provider refined title']")

    assert has_element?(
             lv2,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "한 단어로 확인만"
           )

    # Tear down the durable workspace Session + agent so the shared valid_path()
    # doesn't leak this agent into sibling tests.
    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "same workspace path has isolated chat rails across LiveView pids", %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "isolated reply"}]])

    root = LocalWorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "same-browser-tabs", root)

    {:ok, lv_a, _html} = open_workspace(conn, root)
    {:ok, lv_b, _html} = open_workspace(conn, root)

    session_id_a = subscribe_agent(lv_a)
    session_id_b = subscribe_agent(lv_b)

    refute session_id_a == session_id_b
    refute AcpAgent.whereis(session_id_a) == AcpAgent.whereis(session_id_b)

    lv_a
    |> form("#local-agent-form", agent: %{message: "only rail a"})
    |> render_submit()

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^session_id_a}},
                   1_000

    sync_liveview(lv_a)
    sync_liveview(lv_b)

    assert has_element?(
             lv_a,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "only rail a"
           )

    refute has_element?(
             lv_b,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "only rail a"
           )

    assert [%{user: "only rail a"} | _] = AcpAgent.agent_snapshot(session_id_a).transcript
    assert AcpAgent.agent_snapshot(session_id_b).transcript == []
  end

  test "refresh on an empty chat reuses the active rail instead of adding another blank",
       %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "unused"}]])
    conn = init_workspace_session(conn, "empty-refresh")

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)
    old_pid = AcpAgent.whereis(session_id)
    assert is_pid(old_pid)
    assert AcpAgent.agent_snapshot(session_id).transcript == []
    assert has_element?(lv, "#local-agent-rail-picker[data-count='1']")

    lv
    |> element("#local-agent-refresh")
    |> render_click()

    sync_liveview(lv)

    assert local_agent_session_id(lv) == session_id

    new_pid = AcpAgent.whereis(session_id)
    assert is_pid(new_pid)
    refute new_pid == old_pid
    refute Process.alive?(old_pid)

    assert AcpAgent.agent_snapshot(session_id).transcript == []
    assert has_element?(lv, "#local-agent-title-label[value='New Chat']")
    assert has_element?(lv, "#local-agent-rail-picker[data-count='1']")
    refute has_element?(lv, "#local-agent-rail-picker[data-count='2']")

    on_exit(fn -> stop_workspace_session(LocalWorkspaceAdapterStub.valid_path()) end)
  end

  test "picked elements ride as structured chips: composed prompt + wrapped rail chips + refresh repaint",
       %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [{:text_delta, "done"}],
        report_prompts: true,
        test_pid: self()
      ]
    )

    conn = init_workspace_session(conn, "picks-refresh")

    {:ok, lv, _html} = open_workspace(conn, document: "drafts/service.hwpx")

    on_exit(fn -> stop_workspace_session(LocalWorkspaceAdapterStub.valid_path()) end)

    session_id = subscribe_agent(lv)

    # The picker JS owns this container's children (chips); LiveView renders it
    # once and never morphs the JS-built chips away.
    assert has_element?(lv, "#local-agent-picks[phx-update='ignore'][data-role='composer-picks']")

    picks = [
      %{
        "document" => "drafts/service.hwpx",
        "type" => "cell",
        "ref" => "hwp:body/sec/0/tbl/0/cell/0",
        "text" => "급여 및 수당"
      },
      %{
        "document" => "drafts/service.hwpx",
        "type" => "para",
        "ref" => "hwp:body/sec/0/para/3",
        "text" => "계약 기간"
      },
      # An empty element (no snippet): the chip stays compact — icon + type
      # only, never the document filename blown up into the label.
      %{
        "document" => "drafts/service.hwpx",
        "type" => "paragraph",
        "ref" => "hwp:body/sec/0/para/9",
        "text" => ""
      }
    ]

    # The ChatInput hook pushes {message, picks}; picks never ride inside the
    # textarea value anymore.
    render_hook(lv, "send_local_agent", %{"message" => "여기 고쳐줘", "picks" => picks})

    # The agent-visible prompt keeps the exact legacy block format (typed text
    # followed by the "Selected document elements" JSON block).
    assert_receive {:fake_acp_prompt, _sid, prompt}, 1_000
    assert prompt =~ "여기 고쳐줘"
    assert prompt =~ "Selected document elements (3):"
    assert prompt =~ ~s("ref": "hwp:body/sec/0/tbl/0/cell/0")

    # #32/#34 (path-first): the pick's `document` path IS the tools' document
    # handle — no separate id is stamped, and the turn tells the agent to skip
    # doc.context/doc.find discovery and pass the path directly. VFS turns use
    # the same refs as nested-JSONL target hints instead of doc.edit commands.
    refute prompt =~ "document_id"
    assert prompt =~ "Skip doc.context/doc.find discovery"
    assert prompt =~ "When using doc.* tools"
    assert prompt =~ "When using mounted #{doc_vfs_backend_mode_label()} JSONL"
    assert prompt =~ "picture-control order c"
    assert prompt =~ "`document` value (the file path)"

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    # The rail user bubble shows the typed text plus a WRAPPED chip row — never
    # the raw JSON block.
    assert has_element?(
             lv,
             ~s([data-message-role="user"] [data-role="picked-element-chips"].flex-wrap)
           )

    assert has_element?(lv, ~s([data-role="picked-element-chip"]), "급여 및 수당")
    assert has_element?(lv, ~s([data-role="picked-element-chip"]), "계약 기간")
    assert has_element?(lv, ~s([data-message-role="user"]), "여기 고쳐줘")
    refute render(lv) =~ "Selected document elements"

    # The empty-element chip shows the type alone — no filename fallback.
    assert has_element?(lv, ~s([data-role="picked-element-chip"]), "paragraph")

    refute lv
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(~s([data-role="picked-element-chip"]))
           |> LazyHTML.text()
           |> String.contains?("service.hwpx")

    # A picks-only send (empty text) still starts a turn — it is NOT the empty
    # re-Enter queue-flush gesture.
    render_hook(lv, "send_local_agent", %{"message" => "", "picks" => [hd(picks)]})
    assert_receive {:fake_acp_prompt, _sid, prompt2}, 1_000
    assert prompt2 =~ "Selected document elements (1):"

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    # Refresh starts a fresh active rail; selecting the prior recent chat repaints
    # chips from the durable transcript, not the raw JSON.
    stop_pid(lv.pid)
    sync_workspace_session(LocalWorkspaceAdapterStub.valid_path())

    {:ok, lv2, _html2} = open_workspace(conn)

    sync_liveview(lv2)
    new_session_id = subscribe_agent(lv2)
    refute new_session_id == session_id

    lv2
    |> element("#local-agent-rail-picker")
    |> render_click()

    lv2
    |> element("#local-agent-rail-option-#{session_id}")
    |> render_click()

    sync_liveview(lv2)

    assert local_agent_session_id(lv2) == session_id
    assert has_element?(lv2, ~s([data-role="picked-element-chip"]), "급여 및 수당")
    refute render(lv2) =~ "Selected document elements"
  end

  test "a browser refresh repaints local agent tool-call history", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          {:text_delta, "Before tool."},
          %{
            type: :tool_call_started,
            id: "tool-doc-context",
            name: "doc.context",
            arguments: %{"document" => "active"}
          },
          %{
            type: :tool_call_completed,
            id: "tool-doc-context",
            name: "doc.context",
            result: %{
              "ok" => true,
              "revision" => 7,
              "base_version" => 6,
              "content" => [
                %{
                  "type" => "text",
                  "text" => ~s({"ok":true,"revision":7,"base_version":6})
                }
              ],
              "structuredContent" => %{"ok" => true, "revision" => 7}
            }
          },
          {:text_delta, "After tool."}
        ]
      ]
    )

    conn = init_workspace_session(conn, "tool-refresh")

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)
    agent_pid = AcpAgent.whereis(session_id)

    lv
    |> form("#local-agent-form", agent: %{message: "use one tool"})
    |> render_submit()

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    assert [%{items: items}] = AcpAgent.agent_snapshot(session_id).transcript

    assert tool_item =
             Enum.find(
               items,
               &(Map.get(&1, :role) == :tool and Map.get(&1, :name) == "doc.context" and
                   Map.get(&1, :status) == :completed)
             )

    assert tool_item.input =~ ~s("document": "active")
    assert tool_item.output =~ ~s("ok": true)
    assert tool_item.body =~ "Input:"
    assert tool_item.body =~ "Output:"

    legacy_body =
      Jason.encode!(
        %{
          "_meta" => nil,
          "content" => [
            %{
              "type" => "text",
              "text" => ~s({"ok":true,"revision":3,"base_version":2,"native":[{"revision":3}]})
            }
          ],
          "structuredContent" => %{
            "ok" => true,
            "revision" => 3,
            "base_version" => 2,
            "native" => [%{"revision" => 3}]
          }
        },
        pretty: true
      )

    :sys.replace_state(agent_pid, fn state ->
      Map.put(state, :transcript, [
        %{
          turn_id: "legacy-turn",
          user: "legacy doc tool",
          agent: "",
          items: [
            %{
              role: :tool,
              tool_call_id: "legacy-doc-edit",
              name: "doc.edit",
              status: :completed,
              body: legacy_body
            }
          ]
        }
      ])
    end)

    stop_pid(lv.pid)
    sync_workspace_session(LocalWorkspaceAdapterStub.valid_path())

    {:ok, lv2, _html2} = open_workspace(conn)

    sync_liveview(lv2)
    new_session_id = subscribe_agent(lv2)
    refute new_session_id == session_id

    lv2
    |> element("#local-agent-rail-picker")
    |> render_click()

    lv2
    |> element("#local-agent-rail-option-#{session_id}")
    |> render_click()

    sync_liveview(lv2)

    assert has_element?(
             lv2,
             ~s([data-role="local-agent-tool"][data-message-role="tool"][data-message-status="completed"]),
             "doc.edit"
           )

    details = "#local-agent-tool-legacy-doc-edit-details[hidden][data-role='operation-details']"

    assert has_element?(lv2, details, ~s("ok": true))
    refute has_element?(lv2, details, "revision")
    refute has_element?(lv2, details, "base_version")
    refute has_element?(lv2, details, ~s("version"))
  end

  test "agent rail shows provider logo in model selector for codex route display", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    assert has_element?(
             lv,
             "#local-agent-sidebar[data-component='chat-rail'][data-local-chat-rail='true'][data-provider-key='codex']"
           )

    assert has_element?(
             lv,
             ~s(#local-agent-model-select[data-role="agent-model-select"] [data-role="agent-model-provider-favicon"][src="/images/icons/openai-blossom.svg"])
           )

    refute has_element?(lv, "#local-agent-title [data-role='chat-title-favicon']")

    assert has_element?(
             lv,
             "#local-agent-title-form[phx-change='update_local_agent_title'][data-role='chat-thread-title-form'] input#local-agent-title-label[data-role='chat-thread-title-label'][name='local_agent_title[title]'][type='text'][value='New Chat'][aria-label='Chat title']"
           )

    refute render(lv) =~ "ecrits-local-ui chat"
    refute has_element?(lv, "#local-agent-title-label[disabled]")
    refute has_element?(lv, "#local-agent-title-label[readonly]")
    refute has_element?(lv, "#local-agent-title-label[tabindex='-1']")

    assert has_element?(
             lv,
             "#local-agent-sidebar [data-role='chat-rail-controls'] #local-agent-refresh"
           )

    refute has_element?(lv, "#local-file-tree-refresh")
    refute has_element?(lv, "#local-agent-provider")
    refute has_element?(lv, "#local-agent-provider-icon")
  end

  test "agent rail title is manually editable through the title form", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    lv
    |> form("#local-agent-title-form", local_agent_title: %{title: "Pricing review"})
    |> render_change()

    assert has_element?(
             lv,
             "#local-agent-title-label[value='Pricing review']"
           )

    session_id = local_agent_session_id(lv)

    send(
      lv.pid,
      {:local_agent_event,
       %{session_id: session_id, type: :title_generated, title: "Agent title"}}
    )

    sync_liveview(lv)

    assert AcpAgent.title(session_id) == "Pricing review"
    assert AcpAgent.agent_snapshot(session_id).title_user_edited?

    assert has_element?(
             lv,
             "#local-agent-title-label[value='Pricing review']"
           )
  end

  test "agent generated title replaces the untouched default title", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    session_id = local_agent_session_id(lv)

    send(
      lv.pid,
      {:local_agent_event,
       %{session_id: session_id, type: :title_generated, title: "Employment review"}}
    )

    sync_liveview(lv)

    assert AcpAgent.title(session_id) == "Employment review"
    refute AcpAgent.agent_snapshot(session_id).title_user_edited?

    assert has_element?(
             lv,
             "#local-agent-title-label[value='Employment review']"
           )

    assert has_element?(
             lv,
             "#local-agent-rail-option-#{session_id}",
             "Employment review"
           )
  end

  test "agent new-chat button creates a fresh rail and keeps the old rail selectable", %{
    conn: conn
  } do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "ack reply"}]])
    conn = init_workspace_session(conn, "rail-drawer")

    {:ok, lv, _html} = open_workspace(conn)

    old_session_id = subscribe_agent(lv)
    old_pid = AcpAgent.whereis(old_session_id)

    lv
    |> form("#local-agent-form", agent: %{message: "reset this chat"})
    |> render_submit()

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^old_session_id}},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "reset this chat"
           )

    assert [%{user: "reset this chat"} | _] = AcpAgent.agent_snapshot(old_session_id).transcript

    lv
    |> element("#local-agent-refresh")
    |> render_click()

    sync_liveview(lv)

    # The old rail is preserved; the button creates a distinct fresh rail.
    new_session_id = local_agent_session_id(lv)
    refute new_session_id == old_session_id
    track_agent_session(new_session_id)

    new_pid = AcpAgent.whereis(new_session_id)
    assert is_pid(new_pid)
    refute new_pid == old_pid
    assert AcpAgent.whereis(old_session_id) == old_pid

    assert AcpAgent.agent_snapshot(new_session_id).transcript == []
    assert has_element?(lv, "#local-agent-title-label[value='New Chat']")
    assert has_element?(lv, "#local-agent-sidebar[data-agent-status='idle']")
    assert has_element?(lv, "#local-agent-rail-picker[data-count='2']")

    refute has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "reset this chat"
           )

    lv
    |> element("#local-agent-rail-picker")
    |> render_click()

    assert has_element?(lv, "#local-agent-rail-picker[data-state='open']")

    assert has_element?(
             lv,
             "#local-agent-rail-drawer[data-role='chat-rail-dropdown'][data-state='open']"
           )

    assert has_element?(
             lv,
             "#local-agent-title > #local-agent-rail-drawer[class*='left-0'][class*='right-0']"
           )

    assert has_element?(
             lv,
             "#local-agent-rail-drawer[class*='transition-opacity'][class*='duration-75']"
           )

    refute has_element?(lv, "#local-agent-rail-drawer[class*='w-72']")
    refute has_element?(lv, "#local-agent-rail-drawer[class*='translate-y']")
    refute has_element?(lv, "#local-agent-rail-drawer[class*='scale']")

    assert has_element?(lv, "#local-agent-rail-drawer", "Recent chats")
    assert has_element?(lv, "#local-agent-rail-option-#{old_session_id}", "reset this chat")
    assert has_element?(lv, "#local-agent-rail-option-#{new_session_id}", "New Chat")

    lv
    |> element("#local-agent-rail-picker")
    |> render_click()

    assert has_element?(lv, "#local-agent-rail-picker[data-state='closed']")
    assert has_element?(lv, "#local-agent-rail-drawer[data-state='closed']")
    assert has_element?(lv, "#local-agent-rail-drawer[class*='opacity-0']")

    lv
    |> element("#local-agent-rail-picker")
    |> render_click()

    lv
    |> element("#local-agent-rail-option-#{old_session_id}")
    |> render_click()

    sync_liveview(lv)

    assert local_agent_session_id(lv) == old_session_id
    assert has_element?(lv, "#local-agent-title-label[value='reset this chat']")

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "reset this chat"
           )
  end

  test "agent new-chat button subscribes the live view to the fresh rail stream", %{
    conn: conn
  } do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "ack reply"}]])
    conn = init_workspace_session(conn, "rail-stream")

    {:ok, lv, _html} = open_workspace(conn)

    old_session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "seed old rail"})
    |> render_submit()

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^old_session_id}},
                   1_000

    sync_liveview(lv)

    lv
    |> element("#local-agent-refresh")
    |> render_click()

    sync_liveview(lv)

    new_session_id = local_agent_session_id(lv)
    refute new_session_id == old_session_id
    track_agent_session(new_session_id)
    :ok = AcpAgent.subscribe(new_session_id)

    lv
    |> form("#local-agent-form", agent: %{message: "fresh rail prompt"})
    |> render_submit()

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^new_session_id}},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "fresh rail prompt"
           )

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="agent"]),
             "ack reply"
           )
  end

  test "agent selector supports codex route favicon without provider badge", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    assert has_element?(lv, "#local-agent-sidebar[data-provider-key='codex']")

    assert has_element?(
             lv,
             ~s(#local-agent-model-select[data-role="agent-model-select"] [data-role="agent-model-provider-favicon"][src="/images/icons/openai-blossom.svg"])
           )

    refute has_element?(lv, "#local-agent-title [data-role='chat-title-favicon']")
    refute has_element?(lv, "#local-agent-provider")
    refute has_element?(lv, "#local-agent-provider-icon")
  end

  test "unsupported provider URL state is ignored", %{conn: conn} do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "bogus"]}"
      )

    assert has_element?(lv, "#local-agent-provider-options[data-selected-provider='codex']")
  end

  test "agent status is internal and has no icon or provider badge structure", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    fragment =
      lv
      |> render()
      |> LazyHTML.from_fragment()

    assert has_element?(lv, "#local-agent-status[data-role='local-agent-status']", "Idle")

    assert ["sr-only"] =
             fragment
             |> LazyHTML.query("#local-agent-status")
             |> LazyHTML.attribute("class")

    assert [] =
             fragment
             |> LazyHTML.query(~s([data-role="agent-status"]))
             |> LazyHTML.attribute("data-role")

    assert [] =
             fragment
             |> LazyHTML.query("#local-agent-status img")
             |> LazyHTML.attribute("src")

    assert [] =
             fragment
             |> LazyHTML.query("#local-agent-status [class*='hero-']")
             |> LazyHTML.attribute("class")

    assert [] =
             fragment
             |> LazyHTML.query("#local-agent-status [data-provider-icon]")
             |> LazyHTML.attribute("data-provider-icon")
  end

  test "agent body uses chat rail stream and composer structure", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    assert has_element?(lv, "#local-agent-thread[data-role='chat-stream'][phx-update='stream']")
    assert has_element?(lv, "#local-agent-thread[class*='overflow-x-hidden']")

    refute has_element?(lv, "#local-agent-system")

    assert has_element?(lv, "#local-agent-form[data-role='chat-form']")
    assert has_element?(lv, "#local-agent-input")
    assert has_element?(lv, "#local-agent-upload[data-role='chat-upload']")

    assert has_element?(
             lv,
             ~s(#local-agent-provider-options input[type="file"][name="local_document_import"][class="sr-only"][data-role="local-document-upload-file-input"])
           )

    assert has_element?(lv, "#local-agent-submit[data-role='chat-send'][data-action='send']")
    refute has_element?(lv, "#document-direct-upload-input")
    refute has_element?(lv, ~s([phx-hook="DirectR2Upload"]))
  end

  test "agent sidebar renders provider tool row events", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          %{type: :reasoning_delta, delta: "checking document access"},
          %{
            type: :tool_call_completed,
            id: "tool-ui-json-read",
            name: "doc.read",
            result: %{
              "items" => [
                %{"index" => 1, "text" => "사업주: 주식회사 한빛"}
              ]
            }
          },
          %{
            type: :tool_call_failed,
            id: "tool-ui-read",
            name: "doc.read",
            reason: "missing document session"
          },
          %{
            type: :tool_call_completed,
            id: "tool-ui-find",
            name: "doc.find",
            result: %{
              "matches" => [
                %{"sec" => 0, "para" => 0, "off" => 2, "count" => 3, "text" => "사업주"}
              ]
            }
          },
          {:text_delta, "done"}
        ]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "read"})
    |> render_submit()

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_call_completed,
                      session_id: ^session_id,
                      tool_call_id: "tool-ui-json-read"
                    }},
                   1_000

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_call_failed,
                      session_id: ^session_id,
                      tool_call_id: "tool-ui-read"
                    }},
                   1_000

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_call_completed,
                      session_id: ^session_id,
                      tool_call_id: "tool-ui-find"
                    }},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             "#local-agent-tool-tool-ui-read[data-role='local-agent-tool'][data-message-status='failed']",
             "doc.read"
           )

    assert has_element?(
             lv,
             "#local-agent-tool-tool-ui-read[data-chat-role='chat-message'] [data-role='operation-block']"
           )

    assert has_element?(
             lv,
             "#local-agent-tool-tool-ui-json-read-details[hidden][data-role='operation-details']",
             ~s("items")
           )

    assert has_element?(
             lv,
             "#local-agent-tool-tool-ui-find[data-role='local-agent-tool']",
             "doc.find"
           )

    assert has_element?(
             lv,
             "#local-agent-tool-tool-ui-json-read-details[hidden][data-role='operation-details']",
             ~s("items")
           )

    refute has_element?(
             lv,
             "#local-agent-tool-tool-ui-json-read-details[hidden][data-role='operation-details']",
             "%{"
           )

    refute has_element?(
             lv,
             "#local-agent-tool-tool-ui-json-read-details[hidden][data-role='operation-details']",
             "=>"
           )

    assert has_element?(
             lv,
             "[data-role='local-agent-thinking'] [data-role='operation-block']",
             "Thinking:"
           )

    assert has_element?(
             lv,
             "#local-agent-tool-tool-ui-read-details[hidden][data-role='operation-details']",
             "missing document session"
           )
  end

  test "agent chat rail renders unversioned doc edit and save tool results", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          %{
            type: :tool_call_started,
            id: "tool-edit-no-version",
            name: "doc.edit",
            arguments: %{
              "document" => "service_agreement_v1-4.hwp",
              "base_version" => 12,
              "ops" => [
                %{
                  "ref" => "{\"section\":0,\"paragraph\":422}",
                  "action" => "replace",
                  "text" => "계약 당사자는 다음과 같이 정한다.",
                  "attrs" => %{"char_style" => "body", "para_style" => "normal"}
                }
              ]
            }
          },
          %{
            type: :tool_call_completed,
            id: "tool-edit-no-version",
            name: "doc.edit",
            result: %{
              "ok" => true,
              "revision" => 13,
              "base_version" => 12,
              "current_version" => 13,
              "rebased" => true,
              "invalidated" => [],
              "native" => [%{"ok" => true, "op" => "replace_text", "revision" => 13}],
              "content" => [
                %{
                  "type" => "text",
                  "text" => ~s({"ok":true,"revision":13,"base_version":12,"current_version":13})
                }
              ],
              "structuredContent" => %{
                "ok" => true,
                "revision" => 13,
                "base_version" => 12,
                "current_version" => 13
              }
            }
          },
          %{
            type: :tool_call_started,
            id: "tool-save-no-version",
            name: "doc.save",
            arguments: %{
              "document" => "service_agreement_v1-4.hwp"
            }
          },
          %{
            type: :tool_call_completed,
            id: "tool-save-no-version",
            name: "doc.save",
            result: %{
              "ok" => true
            }
          },
          {:text_delta, "done"}
        ]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "make requested edits"})
    |> render_submit()

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_call_completed,
                      session_id: ^session_id,
                      tool_call_id: "tool-edit-no-version"
                    }},
                   1_000

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_call_completed,
                      session_id: ^session_id,
                      tool_call_id: "tool-save-no-version"
                    }},
                   1_000

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    for {tool_call_id, tool_name} <- [
          {"tool-edit-no-version", "doc.edit"},
          {"tool-save-no-version", "doc.save"}
        ] do
      row = "#local-agent-tool-#{tool_call_id}"
      details = "#{row}-details[hidden][data-role='operation-details']"

      assert has_element?(lv, "#{row}[data-role='local-agent-tool']", tool_name)
      assert has_element?(lv, details, ~s("ok": true))
      assert has_element?(lv, details, "Input:")
      assert has_element?(lv, details, "Output:")

      refute has_element?(lv, details, "base_version")
      refute has_element?(lv, details, "base_revision")
      refute has_element?(lv, details, "revision")
      refute has_element?(lv, details, ~s("version"))
      refute has_element?(lv, details, ~s("current_version"))
      refute has_element?(lv, details, ~s("saved_version"))
      refute has_element?(lv, details, "rebased")
      refute has_element?(lv, details, "stale_version")
    end
  end

  test "agent sidebar appends local token deltas through push events", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          %{type: :reasoning_delta, delta: "checking"},
          {:text_delta, "hello"},
          {:text_delta, " world"}
        ]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    lv
    |> form("#local-agent-form", agent: %{message: "stream"})
    |> render_submit()

    assert_push_event(
      lv,
      "local_agent_reasoning_append",
      %{message_id: reasoning_message_id, piece: "checking"},
      1_000
    )

    assert String.starts_with?(reasoning_message_id, "local-agent-thinking-")

    assert_push_event(
      lv,
      "local_agent_text_append",
      %{message_id: first_message_id, piece: "hello"},
      1_000
    )

    assert String.starts_with?(first_message_id, "local-agent-assistant-")

    assert_push_event(
      lv,
      "local_agent_text_append",
      %{message_id: ^first_message_id, piece: " world"},
      1_000
    )

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="agent"][data-message-status="sent"]),
             "hello world"
           )

    assert has_element?(
             lv,
             ~s([id^="local-agent-assistant-"][data-chat-role="chat-message"][class*="w-full"] [data-role="agent-text"][class*="text-justify"])
           )
  end

  test "agent prose deltas do not create an embedded editor preview for the active document", %{
    conn: conn
  } do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "draft"}]])

    {:ok, lv, _html} = open_workspace(conn, document: "drafts/ledger.xlsx")

    assert_has_element_after_open_sync(
      lv,
      ~s([data-role="office-wasm-viewer"][data-local-document-format="xlsx"])
    )

    lv
    |> form("#local-agent-form", agent: %{message: "edit workbook"})
    |> render_submit()

    assert_push_event(
      lv,
      "local_agent_text_append",
      %{message_id: _message_id, piece: "draft"},
      1_000
    )

    refute_push_event(lv, "editor.preview_delta", %{text: "draft"}, 200)

    sync_liveview(lv)

    refute has_element?(lv, ~s([data-role="editor-preview"]))

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="agent"][data-message-status="sent"]),
             "draft"
           )
  end

  test "waiting indicator shows on the empty placeholder and drops once prose lands",
       %{conn: conn} do
    # Bug A: the bouncing-dots waiting indicator must render on the empty
    # `running` placeholder, and must NOT be present once the assistant bubble
    # carries body text — otherwise the server's debounced re-render re-creates
    # the animated node every ~120ms (status stays `running`) and the CSS
    # `animate-bounce` visibly freezes.
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_local_agent_ui,
        script: [{:text_delta, "streaming reply"}]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "go"})
    |> render_submit()

    assert_receive {:local_agent_adapter_waiting, stream_pid}, 1_000
    sync_liveview(lv)

    # Empty `running` placeholder: the waiting animation IS present.
    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="agent"][data-message-status="running"] [data-role="agent-loading"])
           )

    # Release the turn; deltas stream and the bubble finalizes with body text.
    send(stream_pid, :release_local_agent_ui)

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    # Once the reply carries body text, the waiting indicator must be gone — a
    # bubble that still rendered the dots while showing prose is the freeze bug.
    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="agent"]),
             "streaming reply"
           )

    refute has_element?(lv, ~s([data-role="local-agent-message"] [data-role="agent-loading"]))
  end

  test "agent sidebar renders the streamed reply once when codex re-emits a final full message",
       %{conn: conn} do
    # The real Codex adapter streams the message as deltas AND then re-sends the
    # WHOLE message once as a `final: true` agent_message_chunk. The consumer
    # must drop that terminal chunk (the deltas already produced the full text),
    # otherwise the reply renders twice ("Hi there?Hi there?").
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          {:text_delta, "Hi "},
          {:text_delta, "there?"},
          {:final_message, "Hi there?"}
        ]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "hi"})
    |> render_submit()

    # Only the two streamed deltas should reach the browser as append events —
    # the terminal `final: true` chunk must NOT produce a third append.
    assert_push_event(lv, "local_agent_text_append", %{message_id: msg_id, piece: "Hi "}, 1_000)

    assert_push_event(
      lv,
      "local_agent_text_append",
      %{message_id: ^msg_id, piece: "there?"},
      1_000
    )

    refute_push_event(lv, "local_agent_text_append", %{piece: "Hi there?"}, 200)

    # The accumulated turn text must be the single message, not the doubled one.
    assert_receive {:local_agent_event,
                    %{type: :turn_completed, session_id: ^session_id, text: "Hi there?"}},
                   1_000

    sync_liveview(lv)

    final_body =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        ~s([data-role="local-agent-message"][data-message-role="agent"][data-message-status="sent"])
      )
      |> LazyHTML.text()

    assert final_body =~ "Hi there?"

    # Exactly one occurrence — a doubled emit would render "Hi there?Hi there?".
    occurrences = final_body |> String.split("Hi there?") |> length() |> Kernel.-(1)

    assert occurrences == 1,
           "expected the reply once, got #{occurrences}x in: #{inspect(final_body)}"
  end

  test "agent sidebar does not re-stream earlier text segments as a final bubble",
       %{conn: conn} do
    # Regression: a tool-using turn streams text in SEGMENTS — text before each
    # tool call is flushed as its own bubble at the tool boundary. The session
    # accumulates the WHOLE turn's text (every segment) and reports it as the
    # turn-completed `text`; the Codex prompt result likewise carries that
    # cumulative text. The LiveView must finalize ONLY the trailing (still
    # pending) segment at turn completion — flushing the cumulative text instead
    # overwrites the last bubble with a re-run of every earlier segment
    # (preamble-A + preamble-B reappearing after the tools).
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          {:text_delta, "PREAMBLE-A"},
          %{type: :tool_call_started, id: "t1", name: "doc.context", arguments: %{}},
          %{type: :tool_call_completed, id: "t1", name: "doc.context", result: %{"ok" => true}},
          {:text_delta, "PREAMBLE-B"},
          %{type: :tool_call_started, id: "t2", name: "doc.find", arguments: %{}},
          %{type: :tool_call_completed, id: "t2", name: "doc.find", result: %{"ok" => true}},
          {:text_delta, "FINAL-ANSWER"}
        ]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "summarize"})
    |> render_submit()

    assert_receive {:local_agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    body =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        ~s([data-role="local-agent-message"][data-message-role="agent"][data-message-status="sent"])
      )
      |> LazyHTML.text()

    count = fn haystack, needle -> haystack |> String.split(needle) |> length() |> Kernel.-(1) end

    # Each segment text must appear exactly ONCE across all bubbles. The cumulative
    # final flush re-emitted the preamble segments, so the buggy render had
    # "PREAMBLE-A"/"PREAMBLE-B" appearing twice (their own bubble + the cumulative
    # final bubble). `LazyHTML.text/1` concatenates the separate bubbles, so the
    # correct render reads "PREAMBLE-APREAMBLE-BFINAL-ANSWER" — each token once.
    assert count.(body, "PREAMBLE-A") == 1, "preamble A duplicated in: #{inspect(body)}"
    assert count.(body, "PREAMBLE-B") == 1, "preamble B duplicated in: #{inspect(body)}"
    assert count.(body, "FINAL-ANSWER") == 1, "final answer duplicated in: #{inspect(body)}"

    # No SINGLE bubble may carry the cumulative whole-turn text (segment A directly
    # followed by segment B inside one element) — that is the overwrite signature.
    sent_bubble =
      ~s([data-role="local-agent-message"][data-message-role="agent"][data-message-status="sent"])

    refute has_element?(lv, sent_bubble, "PREAMBLE-APREAMBLE-B"),
           "earlier segments were re-streamed as one cumulative bubble"

    # ...and the trailing segment stands on its own as the final answer bubble.
    assert has_element?(lv, sent_bubble, "FINAL-ANSWER")
  end

  test "agent sidebar renders a final-only message when no deltas were streamed",
       %{conn: conn} do
    # A provider that sends NO incremental deltas, only a terminal `final: true`
    # full message, must still have its reply rendered (the guard only suppresses
    # the final chunk when deltas already produced the text).
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          {:final_message, "Only final."}
        ]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "no deltas"})
    |> render_submit()

    assert_push_event(
      lv,
      "local_agent_text_append",
      %{message_id: _msg_id, piece: "Only final."},
      1_000
    )

    assert_receive {:local_agent_event,
                    %{type: :turn_completed, session_id: ^session_id, text: "Only final."}},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="agent"][data-message-status="sent"]),
             "Only final."
           )
  end

  test "agent sidebar renders markdown for local agent prose", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          {:text_delta,
           """
           Intro **bold** and `inline()`.

           - first item
           - second item

           <script>alert("x")</script>
           """}
        ]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    lv
    |> form("#local-agent-form", agent: %{message: "markdown"})
    |> render_submit()

    assert_push_event(
      lv,
      "local_agent_text_append",
      %{message_id: message_id, piece: piece},
      1_000
    )

    assert piece =~ "Intro"

    sync_liveview(lv)

    # MDEx (GFM) emits standard semantic tags inside the `.chat-markdown`
    # container (styling lives in app.css scoped to `.chat-markdown`).
    assert has_element?(
             lv,
             "##{message_id} [data-role='chat-md-body'].chat-markdown p strong",
             "bold"
           )

    assert has_element?(lv, "##{message_id} .chat-markdown p code", "inline()")
    assert has_element?(lv, "##{message_id} .chat-markdown ul li", "first item")

    html = render(lv)
    # MDEx runs with the default safe mode, so raw HTML is dropped rather than
    # escaped — the script can never reach the DOM in any form.
    refute html =~ "<script>"
    refute html =~ "alert(&quot;x&quot;)"
  end

  test "agent sidebar can cancel a running local agent turn", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_local_agent_ui,
        script: [{:text_delta, "late"}]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "wait"})
    |> render_submit()

    assert_receive {:local_agent_adapter_waiting, _stream_pid}, 1_000
    sync_liveview(lv)

    assert has_element?(lv, "#local-agent-sidebar[data-agent-status='running']")
    refute has_element?(lv, "#local-agent-cancel")
    assert has_element?(lv, "#local-agent-submit[data-role='chat-stop'][data-action='stop']")
    refute has_element?(lv, "#local-agent-submit[data-role='chat-send']")
    assert has_element?(lv, "#local-agent-input:not([disabled])")
    assert has_element?(lv, ~s(#local-agent-input[placeholder="Ask about this workspace"]))
    refute render(lv) =~ "Agent is responding"

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="agent"][data-message-status="running"] [data-role="agent-loading"])
           )

    lv
    |> element("#local-agent-submit[data-role='chat-stop']")
    |> render_click()

    assert_receive {:local_agent_event, %{type: :turn_cancelled, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    assert has_element?(lv, "#local-agent-sidebar[data-agent-status='cancelled']")

    refute has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="agent"][data-message-status="cancelled"])
           )
  end

  test "agent sidebar submit during running queues the next turn", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_local_agent_ui,
        script: [{:text_delta, "done"}]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "first"})
    |> render_submit()

    assert_receive {:local_agent_adapter_waiting, first_stream_pid}, 1_000
    sync_liveview(lv)

    assert has_element?(lv, "#local-agent-sidebar[data-agent-status='running']")
    assert has_element?(lv, "#local-agent-input:not([disabled])")
    assert has_element?(lv, "#local-agent-submit[data-role='chat-stop'][data-action='stop']")
    refute has_element?(lv, "#local-agent-submit[data-role='chat-send']")

    lv
    |> form("#local-agent-form", agent: %{message: "second"})
    |> render_submit()

    assert_receive {:local_agent_event,
                    %{type: :turn_queued, session_id: ^session_id, pending: 1}},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             "#local-agent-queued-panel[data-role='queued-messages'][data-queued-count='1'][data-queued-index='1']",
             "Queue 1/1"
           )

    assert has_element?(lv, "#local-agent-queued-title[data-role='queued-count']", "Queue 1/1")
    assert has_element?(lv, "#local-agent-queued-title[class*='text-[10px]']")
    assert has_element?(lv, "#local-agent-queued-body[data-role='queued-body']")
    assert has_element?(lv, "#local-agent-queued-message[data-role='queued-message']", "second")
    assert has_element?(lv, "#local-agent-queued-message[class*='text-[13px]']")
    assert has_element?(lv, "#local-agent-queued-flush[title='Send queued']", "Send")

    refute_received {:local_agent_event, %{type: :turn_cancelled, session_id: ^session_id}}

    lv
    |> element("#local-agent-submit[data-role='chat-stop']")
    |> render_click()

    assert_receive {:local_agent_event, %{type: :turn_cancelled, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    assert has_element?(lv, "#local-agent-sidebar[data-agent-status='cancelled']")

    assert has_element?(
             lv,
             "#local-agent-queued-panel[data-role='queued-messages'][data-queued-count='1'][data-queued-index='1']",
             "Queue 1/1"
           )

    assert has_element?(lv, "#local-agent-queued-title[data-role='queued-count']", "Queue 1/1")
    assert has_element?(lv, "#local-agent-queued-title[class*='text-[10px]']")
    assert has_element?(lv, "#local-agent-queued-body[data-role='queued-body']")
    assert has_element?(lv, "#local-agent-queued-message[class*='text-[13px]']")

    refute has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "second"
           )

    lv
    |> element("#local-agent-queued-flush")
    |> render_click()

    assert_receive {:local_agent_adapter_waiting, second_stream_pid}, 1_000

    sync_liveview(lv)

    assert has_element?(lv, "#local-agent-sidebar[data-agent-status='running']")
    refute has_element?(lv, "#local-agent-queued-panel")

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "second"
           )

    refute has_element?(lv, "#local-agent-error", "turn_in_progress")

    send(first_stream_pid, :release_local_agent_ui)
    send(second_stream_pid, :release_local_agent_ui)

    assert_receive {:local_agent_event,
                    %{type: :turn_completed, session_id: ^session_id, text: "done"}},
                   1_000
  end

  test "queued turn waits for the running turn before taking over", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_local_agent_ui,
        script: [{:text_delta, "B-streaming"}]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    # Turn A: start it and let it become :running (blocked on wait_for).
    lv
    |> form("#local-agent-form", agent: %{message: "first"})
    |> render_submit()

    assert_receive {:local_agent_adapter_waiting, first_stream_pid}, 1_000
    sync_liveview(lv)

    turn_a = liveview_assign(lv, :local_agent_turn_id)
    assert is_binary(turn_a)

    # Submit a SECOND message mid-stream: queue B behind A.
    lv
    |> form("#local-agent-form", agent: %{message: "second"})
    |> render_submit()

    assert_receive {:local_agent_event,
                    %{
                      type: :turn_queued,
                      session_id: ^session_id,
                      turn_id: turn_b,
                      pending: 1
                    }},
                   1_000

    sync_liveview(lv)

    assert is_binary(turn_b)
    assert turn_b != turn_a
    assert liveview_assign(lv, :local_agent_turn_id) == turn_a
    assert liveview_assign(lv, :local_agent_status) == :running

    send(first_stream_pid, :release_local_agent_ui)
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_a}}, 1_000
    assert_receive {:local_agent_adapter_waiting, second_stream_pid}, 1_000

    sync_liveview(lv)

    assert liveview_assign(lv, :local_agent_status) == :running
    assert liveview_assign(lv, :local_agent_turn_id) != turn_a

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="agent"][data-message-status="running"])
           )

    send(second_stream_pid, :release_local_agent_ui)
  end

  test "hook sends during a running turn preserve queue order and visible pending state", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_local_agent_ui,
        script: [{:text_delta, "done"}]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    render_hook(lv, "send_local_agent", %{"message" => "first"})

    assert_receive {:local_agent_adapter_waiting, first_stream_pid}, 1_000
    sync_liveview(lv)

    turn_a = liveview_assign(lv, :local_agent_turn_id)
    assert is_binary(turn_a)

    render_hook(lv, "send_local_agent", %{"message" => "second"})
    render_hook(lv, "send_local_agent", %{"message" => "third"})

    assert_receive {:local_agent_event,
                    %{
                      type: :turn_queued,
                      session_id: ^session_id,
                      turn_id: turn_b,
                      pending: 1
                    }},
                   1_000

    assert_receive {:local_agent_event,
                    %{
                      type: :turn_queued,
                      session_id: ^session_id,
                      turn_id: turn_c,
                      pending: 2
                    }},
                   1_000

    sync_liveview(lv)

    assert liveview_assign(lv, :local_agent_turn_id) == turn_a
    assert liveview_assign(lv, :local_agent_pending) == 2
    assert Enum.map(liveview_assign(lv, :local_agent_queue), & &1.body) == ["second", "third"]

    assert has_element?(
             lv,
             "#local-agent-queued-panel[data-role='queued-messages'][data-queued-count='2'][data-queued-index='1']",
             "Queue 1/2"
           )

    send(first_stream_pid, :release_local_agent_ui)
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_a}}, 1_000
    assert_receive {:local_agent_adapter_waiting, second_stream_pid}, 1_000
    assert_receive {:local_agent_event, %{type: :turn_started, turn_id: ^turn_b}}, 1_000

    sync_liveview(lv)

    assert liveview_assign(lv, :local_agent_turn_id) == turn_b
    assert liveview_assign(lv, :local_agent_pending) == 1
    assert Enum.map(liveview_assign(lv, :local_agent_queue), & &1.body) == ["third"]

    send(second_stream_pid, :release_local_agent_ui)
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_b}}, 1_000
    assert_receive {:local_agent_adapter_waiting, third_stream_pid}, 1_000
    assert_receive {:local_agent_event, %{type: :turn_started, turn_id: ^turn_c}}, 1_000

    sync_liveview(lv)

    assert liveview_assign(lv, :local_agent_turn_id) == turn_c
    assert liveview_assign(lv, :local_agent_pending) == 0
    assert liveview_assign(lv, :local_agent_queue) == []

    send(third_stream_pid, :release_local_agent_ui)
  end

  # Inject the test-only fake ex_mcp ACP adapter so the chat-rail rendering can be
  # driven deterministically through the real ExMCP.ACP stack (no provider CLI).
  defp use_test_agent_adapter!(opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    Application.put_env(:ecrits, :local_agent, provider: "codex")

    Application.put_env(:ecrits, :local_agent_ui,
      provider: "codex",
      adapter_opts: Keyword.put(adapter_opts, :exmcp_adapter, EcritsWeb.FakeAcpAdapter)
    )
  end

  defp put_provider_integrations!(integrations) do
    current =
      case Application.get_env(:ecrits, :local_agent_ui, []) do
        config when is_list(config) -> config
        _ -> []
      end

    Application.put_env(
      :ecrits,
      :local_agent_ui,
      Keyword.put(current, :integration_options, integrations)
    )
  end

  defp ready_provider_integrations do
    [
      %{
        id: "codex",
        label: "Codex CLI/ACP",
        status: :ready,
        detail: "codex at /bin/codex"
      },
      %{
        id: "claude",
        label: "Claude CLI/ACP",
        status: :ready,
        detail: "claude at /bin/claude"
      }
    ]
  end

  defp open_workspace(conn), do: open_workspace(conn, LocalWorkspaceAdapterStub.valid_path(), [])

  defp open_workspace(conn, opts) when is_list(opts),
    do: open_workspace(conn, LocalWorkspaceAdapterStub.valid_path(), opts)

  defp open_workspace(conn, path) when is_binary(path), do: open_workspace(conn, path, [])

  defp open_workspace(conn, path, opts) do
    conn = put_workspace_handoff(conn, path)
    {:ok, lv, html} = live(conn, ~p"/workspace")

    case Keyword.get(opts, :document) do
      nil ->
        {:ok, lv, html}

      document_path ->
        open_document(lv, document_path)
        {:ok, lv, render(lv)}
    end
  end

  defp open_document(lv, document_path) do
    render_hook(lv, "open_file", %{"path" => document_path})
    render_async(lv, 2_000)
    sync_liveview(lv)
    lv
  end

  defp put_workspace_handoff(conn, path) do
    live_session_id = Plug.Conn.get_session(conn, :local_live_session_id)
    :ok = WorkspaceHandoff.put_workspace_path(live_session_id, path)
    conn
  end

  defp init_workspace_session(
         conn,
         live_session_id,
         path \\ LocalWorkspaceAdapterStub.valid_path()
       ) do
    conn = Phoenix.ConnTest.init_test_session(conn, %{local_live_session_id: live_session_id})
    put_workspace_handoff(conn, path)
  end

  defp subscribe_agent(lv) do
    session_id = local_agent_session_id(lv)
    :ok = AcpAgent.subscribe(session_id)
    track_agent_session(session_id)

    session_id
  end

  defp track_agent_session(session_id) do
    on_exit(fn ->
      case AcpAgent.whereis(session_id) do
        pid when is_pid(pid) -> stop_pid(pid)
        nil -> :ok
      end
    end)
  end

  # Tear down the durable, path-keyed workspace Session AND its foreground agent
  # (the agent lives under its own supervisor, so stopping the Session alone would
  # leave the agent running for the next test). Tolerant of nothing being started.
  defp stop_workspace_session(path) do
    case Ecrits.Workspace.Session.whereis(path) do
      pid when is_pid(pid) ->
        # The Session can die between whereis and this call when another
        # on_exit (track_agent_session) tears the agent down first — a dead
        # Session is exactly the desired end state, not a failure.
        try do
          case Ecrits.Workspace.Session.foreground_agent(%{path: path}) do
            %{pid: agent_pid} when is_pid(agent_pid) -> stop_pid(agent_pid)
            _ -> :ok
          end
        catch
          :exit, _ -> :ok
        end

        stop_pid(pid)

      nil ->
        :ok
    end
  end

  defp stop_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp local_agent_session_id(lv) do
    session_id =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#local-agent-sidebar")
      |> LazyHTML.attribute("data-session-id")
      |> List.first()

    assert is_binary(session_id)
    assert session_id != ""
    session_id
  end

  defp sync_liveview(lv) do
    _ = :sys.get_state(lv.pid)
    :ok
  end

  defp sync_workspace_session(path) do
    case Ecrits.Workspace.Session.whereis(path) do
      pid when is_pid(pid) ->
        _ = :sys.get_state(pid)
        :ok

      nil ->
        :ok
    end
  end

  defp assert_has_element_after_open_sync(lv, selector) do
    unless has_element?(lv, selector) do
      sync_workspace_session(
        liveview_assign(lv, :workspace_path) || LocalWorkspaceAdapterStub.valid_path()
      )

      sync_liveview(lv)
    end

    assert has_element?(lv, selector)
  end

  defp restore_doc_vfs_env(nil), do: Application.delete_env(:ecrits, :doc_vfs)
  defp restore_doc_vfs_env(value), do: Application.put_env(:ecrits, :doc_vfs, value)

  defp liveview_assign(lv, key) do
    lv.pid
    |> :sys.get_state()
    |> Map.get(:socket)
    |> then(& &1.assigns[key])
  end

  defp local_rhwp_document_id(lv) do
    document_id =
      lv
      |> render_local_hwp_editor_html()
      |> local_hwp_document_id_from_html()

    assert is_binary(document_id)
    assert document_id != ""
    document_id
  end

  defp render_local_hwp_editor_html(lv) do
    html = render(lv)

    if local_hwp_document_id_from_html(html) do
      html
    else
      sync_liveview(lv)
      render(lv)
    end
  end

  defp local_hwp_document_id_from_html(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="local-hwp-editor"]))
    |> LazyHTML.attribute("data-local-document-id")
    |> List.first()
  end

  defp prepare_local_workspace_fixture do
    cleanup_local_workspace_fixture()

    root = LocalWorkspaceAdapterStub.valid_path()
    File.mkdir_p!(Path.join(root, "drafts"))

    File.cp!(
      "priv/static/assets/standard_contracts/service_agreement_v1.hwp",
      Path.join(root, "template.hwp")
    )

    File.cp!(
      "priv/static/assets/standard_contracts/employment_v1.hwp",
      Path.join(root, "employment_v1.hwp")
    )

    File.cp!(
      "priv/static/assets/standard_contracts/employment_v1.hwp",
      Path.join(root, "employment_v1 (1).hwp")
    )

    File.cp!(
      "test/fixtures/hwpx/real_contract.hwpx",
      Path.join(root, "drafts/service.hwpx")
    )

    File.write!(Path.join(root, "drafts/reference.docx"), "docx fixture")
    File.write!(Path.join(root, "drafts/ledger.xlsx"), "xlsx fixture")
  end

  defp cleanup_local_workspace_fixture do
    root = LocalWorkspaceAdapterStub.valid_path()
    _ = Ecrits.Fuse.DocMount.teardown(root)

    for relative_path <- [
          "template.hwp",
          "employment_v1.hwp",
          "employment_v1 (1).hwp",
          "drafts/service.hwpx",
          "drafts/reference.docx",
          "drafts/ledger.xlsx",
          "imported-service.hwpx"
        ] do
      document_id = Document.id_for(root, relative_path)
      _ = Document.close(document_id)
    end

    rm_rf_workspace!(root)
  end

  defp doc_vfs_backend_mode_label(status \\ Ecrits.Fuse.DocMount.status())
  defp doc_vfs_backend_mode_label(%{backend: :fskit}), do: "FSKit/VFS"
  defp doc_vfs_backend_mode_label(%{backend: :fuse}), do: "FUSE/VFS"

  defp rm_rf_workspace!(root, attempts \\ 3)

  defp rm_rf_workspace!(root, 0), do: File.rm_rf!(root)

  defp rm_rf_workspace!(root, attempts) do
    case File.rm_rf(root) do
      {:ok, _removed} ->
        :ok

      {:error, _path, _reason} ->
        _ = Ecrits.Fuse.DocMount.teardown(root)
        _ = File.rmdir(Ecrits.Fuse.DocMount.mount_point(root))
        _ = File.rmdir(Path.dirname(Ecrits.Fuse.DocMount.mount_point(root)))
        rm_rf_workspace!(root, attempts - 1)
    end
  end
end
