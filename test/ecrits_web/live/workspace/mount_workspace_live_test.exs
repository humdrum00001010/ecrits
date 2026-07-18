defmodule EcritsWeb.WorkspaceEhwpRuntimeStub do
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

defmodule EcritsWeb.Workspace.MountWorkspaceLiveTest do
  use EcritsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecrits.AcpAgent
  alias Ecrits.AcpAgent.Session, as: AgentSession
  alias Ecrits.Agent.Dialog
  alias Ecrits.Doc.BrowserBridge
  alias Ecrits.Document
  alias Ecrits.Document.PreviewSnapshot
  alias Ecrits.WorkspaceHandoff
  alias EcritsWeb.WorkspaceDirectoryPickerStub
  alias EcritsWeb.WorkspaceAdapterStub

  setup %{conn: conn} do
    previous = Application.get_env(:ecrits, :workspace_adapter)
    previous_directory_picker = Application.get_env(:ecrits, :directory_picker)
    previous_directory_picker_stub = Application.get_env(:ecrits, :directory_picker_stub)
    previous_agent = Application.get_env(:ecrits, :agent)
    previous_agent_ui = Application.get_env(:ecrits, :agent_ui)
    previous_ehwp_opts = Application.get_env(:ecrits, :ehwp_opts)

    previous_workspace_adapter_stub_path =
      Application.get_env(:ecrits, :workspace_adapter_stub_path)

    workspace_path =
      Path.join(
        System.tmp_dir!(),
        "ecrits-ui-#{System.unique_integer([:positive, :monotonic])}"
      )

    Application.put_env(:ecrits, :workspace_adapter_stub_path, workspace_path)
    Application.put_env(:ecrits, :workspace_adapter, WorkspaceAdapterStub)
    Application.put_env(:ecrits, :directory_picker, WorkspaceDirectoryPickerStub)
    Application.put_env(:ecrits, :ehwp_opts, runtime: EcritsWeb.WorkspaceEhwpRuntimeStub)

    Application.put_env(
      :ecrits,
      :directory_picker_stub,
      {:ok, WorkspaceDirectoryPickerStub.valid_path()}
    )

    prepare_workspace_fixture()

    # The foreground agent is now owned by the path-keyed `Ecrits.Workspace.Session`
    # (durable, shared across tests at the same `valid_path()`). Clear any Session
    # left over from a prior test so each test starts with a fresh agent — without
    # this, a leaked in-flight turn / provider thread bleeds across tests.
    stop_workspace_session(WorkspaceAdapterStub.valid_path())

    live_session_id = "mount-workspace-test-#{System.unique_integer([:positive])}"

    :ok =
      WorkspaceHandoff.put_workspace_path(live_session_id, WorkspaceAdapterStub.valid_path())

    conn = Phoenix.ConnTest.init_test_session(conn, %{live_session_id: live_session_id})

    on_exit(fn ->
      stop_workspace_session(WorkspaceAdapterStub.valid_path())
      cleanup_workspace_fixture()

      if previous do
        Application.put_env(:ecrits, :workspace_adapter, previous)
      else
        Application.delete_env(:ecrits, :workspace_adapter)
      end

      if previous_directory_picker do
        Application.put_env(:ecrits, :directory_picker, previous_directory_picker)
      else
        Application.delete_env(:ecrits, :directory_picker)
      end

      if previous_directory_picker_stub do
        Application.put_env(
          :ecrits,
          :directory_picker_stub,
          previous_directory_picker_stub
        )
      else
        Application.delete_env(:ecrits, :directory_picker_stub)
      end

      if previous_agent_ui do
        Application.put_env(:ecrits, :agent_ui, previous_agent_ui)
      else
        Application.delete_env(:ecrits, :agent_ui)
      end

      if previous_agent do
        Application.put_env(:ecrits, :agent, previous_agent)
      else
        Application.delete_env(:ecrits, :agent)
      end

      if previous_ehwp_opts do
        Application.put_env(:ecrits, :ehwp_opts, previous_ehwp_opts)
      else
        Application.delete_env(:ecrits, :ehwp_opts)
      end

      if previous_workspace_adapter_stub_path do
        Application.put_env(
          :ecrits,
          :workspace_adapter_stub_path,
          previous_workspace_adapter_stub_path
        )
      else
        Application.delete_env(:ecrits, :workspace_adapter_stub_path)
      end
    end)

    {:ok, conn: conn, live_session_id: live_session_id}
  end

  test "root renders unauthenticated mount screen", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/")

    assert has_element?(lv, "#mount-root")
    assert has_element?(lv, "a[aria-label='Ecrits'][href='/']")
    assert has_element?(lv, "#native-directory-picker[data-role='native-directory-picker']")
    assert has_element?(lv, "#mount-picker-surface[data-role='mount-picker-surface']")
    assert has_element?(lv, "#mount-control-row[data-role='mount-control-row']")
    assert has_element?(lv, "#mount-control-row #mount-choose", "Open folder")

    assert has_element?(
             lv,
             "#mount-control-row #path-form[phx-submit='workspace.path.open']"
           )

    assert has_element?(
             lv,
             "#mount-control-row #path-input[name='mount_path[path]']"
           )

    assert has_element?(
             lv,
             "#mount-control-row #path-submit[type='submit'][aria-label='Open path'][title='Open this path']"
           )

    assert has_element?(lv, "#path-submit", "Open")
    refute has_element?(lv, "#manual-path-picker")
    refute has_element?(lv, "#provider-picker")
    refute has_element?(lv, "#agent-provider-picker")
    refute has_element?(lv, "#directory-picker[data-role='directory-picker']")
    refute has_element?(lv, "#mount-submit")
    refute has_element?(lv, "#mount-form")
    refute has_element?(lv, "#mount-path")
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
             "#agent-provider-setup[data-provider='claude'][data-status='login_required']"
           )

    assert has_element?(lv, "#agent-provider-current-status", "Login required")

    assert has_element?(
             lv,
             "#agent-provider-install-command",
             "curl -fsSL https://claude.ai/install.sh | bash"
           )

    assert has_element?(lv, "#agent-provider-login-command", "claude auth login")
    assert has_element?(lv, "#agent-provider-check-command", "claude auth status")

    assert has_element?(lv, "a#agent-provider-return[href]", "Workspace")
  end

  test "invalid mount path renders inline error", %{conn: conn} do
    Application.put_env(:ecrits, :directory_picker_stub, {:ok, "/not-here"})

    {:ok, lv, _html} = live(conn, ~p"/")

    lv
    |> element("#mount-choose")
    |> render_click()

    render_async(lv)

    assert has_element?(lv, "#mount-error", "Workspace path does not exist.")
    assert has_element?(lv, "#mount-picker-surface")
  end

  test "workspace path query is ignored in favor of the session handoff", %{conn: conn} do
    file_path = Path.join(WorkspaceAdapterStub.valid_path(), "not-a-directory.txt")
    File.write!(file_path, "not a directory")

    {:ok, lv, _html} = live(conn, ~p"/workspace?#{[path: file_path]}")

    assert has_element?(lv, "#workspace-grid")
    refute has_element?(lv, "#mount-error")
  end

  test "native picker unavailable renders inline error", %{conn: conn} do
    Application.put_env(:ecrits, :directory_picker_stub, {
      :error,
      {:native_picker_unavailable, "Native folder picker is unavailable on this OS."}
    })

    {:ok, lv, _html} = live(conn, ~p"/")

    lv
    |> element("#mount-choose")
    |> render_click()

    render_async(lv)

    assert has_element?(
             lv,
             "#mount-error",
             "Native folder picker is unavailable on this OS."
           )
  end

  test "native picker runs asynchronously while the mount screen stays responsive", %{conn: conn} do
    Application.put_env(:ecrits, :directory_picker_stub, {
      :await,
      self(),
      {:error, :cancelled}
    })

    {:ok, lv, _html} = live(conn, ~p"/")

    lv
    |> element("#mount-choose")
    |> render_click()

    assert_receive {:directory_picker_started, picker_pid}
    assert has_element?(lv, "#mount-choose[disabled][data-busy='true']", "Opening picker")

    send(picker_pid, :release_directory_picker)
    render_async(lv)

    assert has_element?(lv, "#mount-error", "Folder selection canceled.")
    assert has_element?(lv, "#mount-choose[data-busy='false']", "Open folder")
  end

  test "manual path form submits through LiveView without URL state", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")

    assert has_element?(
             lv,
             "#path-form[phx-submit='workspace.path.open'] #path-input[name='mount_path[path]']"
           )
  end

  test "valid mount path navigates to workspace shell", %{conn: conn} do
    put_provider_integrations!(ready_provider_integrations())

    Application.put_env(:ecrits, :directory_picker_stub, {
      :await,
      self(),
      {:ok, WorkspaceDirectoryPickerStub.valid_path()}
    })

    {:ok, lv, _html} = live(conn, ~p"/")

    lv
    |> element("#mount-choose")
    |> render_click()

    assert_receive {:directory_picker_started, picker_pid}
    assert has_element?(lv, "#mount-choose[disabled][data-busy='true']", "Opening picker")
    send(picker_pid, :release_directory_picker)

    assert_redirect(lv, ~p"/workspace")

    {:ok, workspace_lv, _html} = live(conn, ~p"/workspace")
    render_hook(workspace_lv, "workspace.chat_rail.tab_ready", %{"id" => "mount-shell-tab"})
    sync_liveview(workspace_lv)

    assert has_element?(workspace_lv, "#workspace-root")
    assert has_element?(workspace_lv, "div#workspace-root")
    refute has_element?(workspace_lv, "main#workspace-root")
    assert has_element?(workspace_lv, "a[aria-label='Ecrits'][href='/workspace']")
    assert has_element?(workspace_lv, "#workspace-root[class*='overflow-hidden']")

    refute has_element?(workspace_lv, "#workspace-grid[phx-hook]")

    assert has_element?(
             workspace_lv,
             "#file-tree-resizer[phx-hook='EcritsWeb.Workspace.WorkspaceLive.WorkspacePanelResize'][data-panel='file_tree']"
           )

    assert has_element?(
             workspace_lv,
             "#agent-rail-resizer[phx-hook='EcritsWeb.Workspace.WorkspaceLive.WorkspacePanelResize'][data-panel='chat_rail']"
           )

    assert has_element?(workspace_lv, "#workspace-grid[data-office-asset-version]")
    assert has_element?(workspace_lv, "#workspace-grid[class*='h-full']")
    assert has_element?(workspace_lv, "#workspace-grid[class*='isolate']")
    assert has_element?(workspace_lv, "#workspace-grid[style*='--workspace-editor-z']")

    assert has_element?(
             workspace_lv,
             "#workspace-grid[style*='--workspace-agent-rail-z']"
           )

    assert has_element?(workspace_lv, "#workspace-grid[class*='overflow-hidden']")
    refute has_element?(workspace_lv, "#workspace-grid[class*='max-lg:']")

    assert has_element?(
             workspace_lv,
             "#workspace-grid[class*='--workspace-chat-rail-width']"
           )

    assert has_element?(
             workspace_lv,
             "#workspace-grid[class*='--workspace-chat-rail-live-width']"
           )

    assert has_element?(
             workspace_lv,
             "#workspace-grid[class*='--workspace-file-tree-width']"
           )

    assert has_element?(
             workspace_lv,
             "#file-tree-panel[data-component='repo-browser'][data-file-tree-panel='true'][data-collapsed='false'][class*='overflow-hidden']"
           )

    assert has_element?(
             workspace_lv,
             "#editor-shell[data-editor-shell='true'][class*='z-[var(--workspace-editor-z)]']"
           )

    assert has_element?(workspace_lv, "#file-tree-panel [data-role='repo-browser-header']")
    assert has_element?(workspace_lv, ~s(#file-tree-panel[aria-label="Workspace files"]))

    assert has_element?(
             workspace_lv,
             "#file-tree-panel > #file-tree-content:first-child > div:first-child[data-role='repo-browser-header'][data-action='collapse-file-tree']"
           )

    assert has_element?(workspace_lv, "#file-tree-content[data-role='file-tree-content']")

    assert has_element?(
             workspace_lv,
             ~s(button#file-node-template-hwpx[data-role="repo-browser-row"][phx-click="workspace.document.open"][phx-value-path="template.hwpx"])
           )

    refute has_element?(workspace_lv, ~s(button#file-node-template-hwpx[data-phx-link]))
    refute has_element?(workspace_lv, ~s(button#file-node-template-hwpx[href]))

    assert has_element?(
             workspace_lv,
             ~s(#file-tree-resizer[data-role="file-tree-resizer"][aria-label="Resize file tree"][class*="block"])
           )

    assert has_element?(
             workspace_lv,
             ~s(#file-tree-hide[data-role="file-tree-hide"][aria-label="Hide file tree"][aria-controls="file-tree-content"][aria-expanded="true"])
           )

    assert has_element?(
             workspace_lv,
             ~s(#file-tree-restore[data-role="file-tree-restore"][class*="hidden"])
           )

    assert has_element?(
             workspace_lv,
             ~s(#file-tree-show[data-role="file-tree-show"][aria-label="Show file tree"][aria-controls="file-tree-content"][aria-expanded="true"])
           )

    refute has_element?(workspace_lv, "#file-tree-breadcrumb")
    assert has_element?(workspace_lv, "#agent-sidebar[data-default-visible='true']")
    assert has_element?(workspace_lv, "#agent-sidebar[class*='relative']")

    assert has_element?(
             workspace_lv,
             "#agent-sidebar[class*='z-[var(--workspace-agent-rail-z)]']"
           )

    assert has_element?(workspace_lv, "#agent-sidebar[class*='overflow-visible']")

    assert has_element?(
             workspace_lv,
             "#agent-rail-resizer[data-role='chat-rail-resizer'][aria-label='Resize chat rail'][class*='block']"
           )

    assert has_element?(workspace_lv, "#agent-sidebar[data-agent-status='idle']")

    assert has_element?(
             workspace_lv,
             "#agent-sidebar [data-role='chat-rail-body'][class*='overflow-visible']"
           )

    assert has_element?(workspace_lv, "#agent-thread[class*='overflow-y-auto']")

    assert has_element?(
             workspace_lv,
             "form#agent-provider-options[data-role='provider-options']"
           )

    assert has_element?(
             workspace_lv,
             "form#agent-provider-options[data-selected-provider='codex'][data-selected-model='gpt-5.5'][data-selected-reasoning='medium'][data-selected-access='read-only'] details#agent-model-select[data-role='agent-model-select'][data-selected-provider='codex'][data-selected-model='gpt-5.5']",
             "GPT-5.5"
           )

    assert has_element?(
             workspace_lv,
             "#agent-model-select[class*='max-w-32'] > summary[class*='max-w-32']"
           )

    refute has_element?(workspace_lv, "#agent-model-select > summary[class*='w-full']")

    refute has_element?(workspace_lv, "#agent-model-select option")
    refute has_element?(workspace_lv, "#agent-provider-options option[value='fake']")
    refute has_element?(workspace_lv, "#agent-provider-options option[value='external']")

    assert has_element?(
             workspace_lv,
             "form#agent-provider-options details#agent-reasoning-select[data-role='provider-reasoning-select'][data-selected-reasoning='medium'] button#agent-inline-reasoning-medium[data-selected='true']",
             "Medium - balanced reasoning/tokens"
           )

    assert has_element?(
             workspace_lv,
             "form#agent-provider-options details#agent-reasoning-select [class*='right-0']"
           )

    assert has_element?(
             workspace_lv,
             "form#agent-provider-options details#agent-access-select[data-role='agent-access-control'][data-selected-access='read-only'] button#agent-inline-access-read-only[data-selected='true']",
             "Read only"
           )

    refute has_element?(workspace_lv, "select#agent-reasoning-select")
    refute has_element?(workspace_lv, "select#agent-access-select")

    refute has_element?(workspace_lv, "#agent-provider-picker")
    refute has_element?(workspace_lv, "#agent-provider-integrations")
    refute has_element?(workspace_lv, "#agent-modal-reasoning-select")
    refute has_element?(workspace_lv, "#agent-modal-access-control")

    refute has_element?(workspace_lv, "#agent-model-modal")

    assert has_element?(
             workspace_lv,
             "#agent-model-select button#agent-inline-model-gpt-5\\.5[data-role='agent-model-option'][data-provider='codex'][data-selected='true']",
             "GPT-5.5"
           )

    assert has_element?(
             workspace_lv,
             "#agent-model-select [data-role='agent-model-menu'][class*='left-0'][class*='overflow-y-auto']"
           )

    assert has_element?(
             workspace_lv,
             "#agent-model-select [data-role='agent-model-option-label'][class*='whitespace-normal']",
             "GPT-5.3 Codex Spark"
           )

    assert has_element?(
             workspace_lv,
             "#agent-model-select button#agent-inline-model-gpt-5\\.3-codex-spark[data-role='agent-model-option'][data-provider='codex']",
             "GPT-5.3 Codex Spark"
           )

    refute has_element?(
             workspace_lv,
             "#agent-model-select button#agent-inline-model-claude-opus-4-7"
           )

    assert has_element?(
             workspace_lv,
             "#agent-model-select button#agent-go-to-provider[phx-click='agent.model_dialog.open'][data-role='agent-provider-config-open']",
             "Go to provider"
           )

    workspace_lv
    |> element("#agent-go-to-provider")
    |> render_click()

    assert has_element?(
             workspace_lv,
             "#agent-model-modal[role='dialog'][aria-modal='true'] #agent-model-detail-codex[data-provider='codex'][data-selected='true']",
             "Codex"
           )

    assert has_element?(
             workspace_lv,
             "#agent-model-modal #agent-model-detail-claude[data-provider='claude']",
             "Claude"
           )

    assert has_element?(
             workspace_lv,
             ~s(#agent-model-modal #agent-model-detail-claude img[src="/images/icons/claude-favicon.ico"])
           )

    assert has_element?(
             workspace_lv,
             "#agent-model-modal button#agent-model-detail-claude[phx-click='agent.provider.select'][phx-value-provider='claude']"
           )

    refute has_element?(workspace_lv, "#agent-model-modal [data-provider='fake']")
    refute has_element?(workspace_lv, "#agent-model-modal #agent-modal-options-form")
    refute has_element?(workspace_lv, "#agent-model-modal #agent-modal-model-select")

    refute has_element?(
             workspace_lv,
             "#agent-model-modal #agent-modal-reasoning-select"
           )

    refute has_element?(
             workspace_lv,
             "#agent-model-modal #agent-modal-access-control"
           )

    refute has_element?(
             workspace_lv,
             "#agent-model-modal button[data-role='provider-reasoning-option']"
           )

    refute has_element?(
             workspace_lv,
             "#agent-model-modal button[data-role='agent-access-option']"
           )

    refute has_element?(workspace_lv, "#agent-model-modal button[data-provider='fake']")
    refute has_element?(workspace_lv, "#agent-model-modal button[data-provider='external']")

    workspace_lv
    |> element("#agent-model-modal-close")
    |> render_click()

    refute has_element?(workspace_lv, "#agent-model-modal")

    assert has_element?(workspace_lv, "form#agent-form[data-role='chat-form']")

    assert has_element?(
             workspace_lv,
             "form#agent-form #agent-input[name='agent[message]']"
           )

    refute has_element?(workspace_lv, "form#agent-form #agent-model-select")
    refute has_element?(workspace_lv, "form#agent-form #agent-reasoning-select")
    refute has_element?(workspace_lv, "form#agent-form #agent-access-select")
    assert has_element?(workspace_lv, "#agent-upload[data-role='chat-upload']")

    assert has_element?(
             workspace_lv,
             ~s(#agent-provider-options input[type="file"][name="document_import"][data-role="document-import-file-input"])
           )

    assert has_element?(workspace_lv, "#agent-submit", "Send")
  end

  test "panel resize persists only the final browser measurement", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    render_hook(lv, "workspace.layout.resize.finish", %{
      "panel" => "chat_rail",
      "start_x" => 800.4,
      "x" => 700.2,
      "panel_width" => 339.6,
      "viewport_width" => 1_200.1
    })

    assert has_element?(
             lv,
             "#workspace-grid[style*='--workspace-chat-rail-width: 440px']"
           )

    assert has_element?(lv, "#agent-rail-resizer[data-dragging='false']")
  end

  test "workspace chat rail reasoning option is selectable", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    assert has_element?(
             lv,
             "#agent-provider-options #agent-reasoning-select button#agent-inline-reasoning-minimal",
             "Minimal - fastest, least tokens"
           )

    assert has_element?(
             lv,
             "#agent-provider-options #agent-reasoning-select button#agent-inline-reasoning-low",
             "Low - light reasoning, lower tokens"
           )

    assert has_element?(
             lv,
             "#agent-provider-options #agent-reasoning-select button#agent-inline-reasoning-medium[data-selected='true']",
             "Medium - balanced reasoning/tokens"
           )

    assert has_element?(
             lv,
             "#agent-provider-options #agent-reasoning-select button#agent-inline-reasoning-xhigh",
             "XHigh - maximum reasoning/tokens"
           )

    lv
    |> element("#agent-inline-reasoning-high")
    |> render_click()

    # #42: reasoning persists in the durable session, NOT the URL — the click
    # does NOT push_patch; it updates the bound config in place (the selection is
    # reflected in the re-rendered control below).
    assert has_element?(
             lv,
             "#agent-provider-options #agent-reasoning-select[data-selected-reasoning='high'] button#agent-inline-reasoning-high[data-selected='true']",
             "High - deeper reasoning, more tokens"
           )
  end

  test "workspace chat rail provider detail switches provider", %{conn: conn} do
    put_provider_integrations!(ready_provider_integrations())

    {:ok, lv, _html} = open_workspace(conn)

    lv
    |> element("#agent-go-to-provider")
    |> render_click()

    lv
    |> element("#agent-model-detail-claude")
    |> render_click()

    refute has_element?(lv, "#agent-model-modal")

    assert has_element?(
             lv,
             "#agent-provider-options[data-selected-provider='claude'][data-selected-model='default'] #agent-model-select[data-selected-provider='claude'][data-selected-model='default']",
             "Default"
           )

    refute has_element?(
             lv,
             "#agent-model-select button[data-role='agent-model-option'][data-provider='codex']"
           )

    refute has_element?(lv, "#agent-model-select option")

    lv
    |> element("#agent-go-to-provider")
    |> render_click()

    lv
    |> element("#agent-model-detail-claude")
    |> render_click()

    refute has_element?(lv, "#agent-model-modal")
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
    |> element("#agent-go-to-provider")
    |> render_click()

    assert has_element?(
             lv,
             "#agent-model-modal button#agent-model-detail-codex[data-role='agent-provider-select'][data-status='ready'][phx-click='agent.provider.select']"
           )

    assert has_element?(
             lv,
             ~s(#agent-model-modal a#agent-model-detail-claude[data-role="agent-provider-setup"][data-status="missing"][target="_blank"][href*="/local/agent-providers/claude/setup"]),
             "install"
           )

    refute has_element?(
             lv,
             "#agent-model-modal button#agent-model-detail-claude[phx-click='agent.provider.select']"
           )
  end

  test "workspace chat rail submits selected inline options to the local agent", %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [echo_opts: true])

    {:ok, lv, _html} = open_workspace(conn)

    assert has_element?(
             lv,
             "form#agent-provider-options details#agent-model-select[data-role='agent-model-select']"
           )

    assert has_element?(
             lv,
             "form#agent-provider-options details#agent-reasoning-select[data-role='provider-reasoning-select']"
           )

    assert has_element?(
             lv,
             "form#agent-provider-options details#agent-access-select[data-role='agent-access-control']"
           )

    refute has_element?(lv, "select#agent-reasoning-select")
    refute has_element?(lv, "select#agent-access-select")

    refute has_element?(lv, "form#agent-provider-options option[value='fake']")
    refute has_element?(lv, "form#agent-provider-options option[value='external']")

    lv
    |> element(~s([id="agent-inline-model-gpt-5.3-codex-spark"]))
    |> render_click()

    assert has_element?(
             lv,
             "#agent-provider-options[data-selected-provider='codex'][data-selected-model='gpt-5.3-codex-spark']"
           )

    # reasoning + access select into the durable SESSION (no URL patch); the
    # submit below proves they were forwarded to the adapter (echoed back).
    lv
    |> element("#agent-inline-reasoning-xhigh")
    |> render_click()

    lv
    |> element("#agent-inline-access-full-workspace")
    |> render_click()

    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "selected rail opts"})
    |> render_submit()

    assert_receive {:agent_event,
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
             ~s([data-role="agent-message"][data-message-role="agent"][data-message-status="sent"]),
             "model=gpt-5.3-codex-spark"
           )
  end

  test "workspace chat rail ignores fake provider URL state", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()

    {:ok, lv, _html} = live(conn, ~p"/workspace?#{[path: root, provider: "fake"]}")

    assert has_element?(lv, "#agent-provider-options[data-selected-provider='codex']")
    assert has_element?(lv, "#workspace-grid")
  end

  test "file tree supports expansion, row-open, and format affordances", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    assert has_element?(lv, "#file-tree")
    assert has_element?(lv, ~s(#file-tree ul[role="tree"]))
    refute has_element?(lv, "#file-node-ecrits")
    assert has_element?(lv, "#file-node-Assignment-2[aria-expanded='false']")
    assert has_element?(lv, "#file-node-drafts[aria-expanded='false']")

    assert has_element?(
             lv,
             ~s(button#file-node-template-hwpx[data-role="repo-browser-row"][phx-click="workspace.document.open"][phx-value-path="template.hwpx"])
           )

    refute has_element?(lv, "#file-node-template-hwpx[data-bytes-url]")
    refute has_element?(lv, "#file-node-template-hwpx[data-node-path]")

    refute has_element?(lv, "#file-node-template-hwpx[href]")
    refute has_element?(lv, ~s(#file-node-template-hwpx[data-phx-link]))
    refute has_element?(lv, ~s([id^="open-file-"]))
    refute has_element?(lv, "#file-tree [data-role='file-extension']")
    refute has_element?(lv, "#disabled-file-Antigravity-dmg")
    refute has_element?(lv, "#file-node-Antigravity-dmg")
    refute has_element?(lv, "#file-node-drafts-service-hwpx")

    lv
    |> element("#toggle-dir-Assignment-2")
    |> render_click()

    assert has_element?(lv, "#file-node-Assignment-2[aria-expanded='true']")
    refute has_element?(lv, "#file-node-Assignment-2 + ul[role='group']")

    lv
    |> element("#toggle-dir-drafts")
    |> render_click()

    assert has_element?(lv, "#file-node-drafts[aria-expanded='true']")

    assert has_element?(
             lv,
             ~s(button#file-node-drafts-service-hwpx[phx-click="workspace.document.open"][phx-value-path="drafts/service.hwpx"])
           )

    refute has_element?(lv, "#open-file-drafts-service-hwpx")
    refute has_element?(lv, ~s([id^="open-file-"]))
    refute has_element?(lv, "#preview-file-drafts-reference-docx")
    refute has_element?(lv, "#disabled-file-drafts-notes-xyz")

    assert has_element?(
             lv,
             ~s(button#file-node-drafts-reference-docx[phx-click="workspace.document.open"][phx-value-path="drafts/reference.docx"])
           )

    assert has_element?(
             lv,
             ~s(button#file-node-drafts-ledger-xlsx[phx-click="workspace.document.open"][phx-value-path="drafts/ledger.xlsx"])
           )

    lv
    |> element("#toggle-dir-rulebook-md")
    |> render_click()

    assert has_element?(lv, "#file-node-rulebook-md[aria-expanded='true']")

    lv
    |> element("#toggle-dir-rulebook-md-acceptance-certificate")
    |> render_click()

    assert has_element?(
             lv,
             "#file-node-rulebook-md-acceptance-certificate[data-tree-depth='1']"
           )

    assert has_element?(
             lv,
             "#file-node-rulebook-md-acceptance-certificate-acceptance-certificate-md[data-tree-depth='2'][phx-click='workspace.document.open']"
           )

    refute has_element?(
             lv,
             "#file-node-rulebook-md-acceptance-certificate #file-node-rulebook-md-acceptance-certificate-acceptance-certificate-md"
           )

    refute has_element?(lv, "#rhwp-shell")
    refute has_element?(lv, "#rhwp-error")

    open_document(lv, "drafts/service.hwpx")

    assert has_element?(lv, "#file-node-drafts-service-hwpx[aria-selected='true']")
    assert has_element?(lv, "#file-node-drafts-service-hwpx[class*='bg-base-300/70']")
    assert has_element?(lv, "#studio-document-tab-drafts-service-hwpx[data-active='true']")
    refute has_element?(lv, "#file-tree-breadcrumb")

    sync_liveview(lv)
    assert has_element?(lv, "#rhwp-save-state", "Loaded -")

    open_document(lv, "template.hwpx")

    refute has_element?(lv, "#file-tree-breadcrumb")
  end

  test "document query reopens a local HWPX in the EHWP shell without SaaS upload UI", %{
    conn: conn
  } do
    {:ok, lv, _html} = open_workspace(conn, document: "drafts/service.hwpx")

    assert has_element?(lv, "#rhwp-shell")
    assert has_element?(lv, "#rhwp-toolbar")
    assert has_element?(lv, "#studio-root[data-component='studio-document-surface']")
    assert has_element?(lv, "#studio-document-header")
    refute has_element?(lv, "#file-tree-breadcrumb")
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
    assert has_element?(lv, "#rhwp-fullscreen[data-role='editor-fullscreen-toggle']")
    assert has_element?(lv, "#rhwp-save-state", "Loaded -")
    refute has_element?(lv, "#rhwp-checkpoint")
    refute has_element?(lv, "#rhwp-save")
    refute has_element?(lv, ~s([data-role="rhwp-checkpoint"]))
    refute has_element?(lv, ~s([data-role="rhwp-save"]))
    assert has_element?(lv, "#rhwp-editor-frame.contents")

    assert has_element?(lv, ~s([data-role="hwp-editor"][data-renderer="rhwp-wasm"]))

    assert_canvas_state(lv, ~s([data-role="hwp-editor"]), %{
      "localDocumentFormat" => "hwpx"
    })

    assert has_element?(
             lv,
             ~s([data-role="hwp-editor"][phx-hook="EcritsWeb.Live.Studio.Components.Canvas.HwpPages.WasmHwpEditor"])
           )

    # The browser-WASM hook owns the page-stack DOM (phx-update="ignore") and
    # builds the per-page <canvas> nodes client-side from the streamed bytes, so
    # the server-rendered stack is an empty, hook-owned container.
    assert has_element?(lv, ~s([data-role="hwp-pages"][phx-update="ignore"]))
    assert has_element?(lv, ~s([data-role="hwp-pages"].ehwp-document-stack))

    # The hook fetches the document's raw bytes from the gated read-only route.
    assert is_binary(canvas_state(lv, ~s([data-role="hwp-editor"]))["bytesUrl"])

    refute render(lv) =~ ~s(phx-hook="Rhwp")
    refute has_element?(lv, ~s([data-role="hwp-editor"][data-editable-spec-candidates]))

    refute has_element?(lv, ~s([data-role="canvas-empty-upload-action"]))
    refute has_element?(lv, "#document-direct-upload-input")
    refute has_element?(lv, ~s([phx-hook="DirectR2Upload"]))
  end

  test "document search events and rendered state are owned by LiveView", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn, document: "drafts/service.hwpx")
    document_id = liveview_assign(lv, :active_document).id

    assert has_element?(lv, "#document-search-bar[hidden]")

    render_hook(lv, "document.search.open", %{"document_id" => document_id})

    assert has_element?(lv, "#document-search-bar:not([hidden])")
    assert liveview_assign(lv, :document_search).open?

    lv
    |> form("#document-search-bar", document_search: %{query: "계약"})
    |> render_change()

    assert_push_event(
      lv,
      "document.search.command",
      %{action: "search", document_id: ^document_id, format: "hwpx", query: "계약"},
      1_000
    )

    assert has_element?(lv, "#document-search-input[value='계약']")
    assert liveview_assign(lv, :document_search).query == "계약"

    render_hook(lv, "document.search.result_received", %{
      "document_id" => document_id,
      "query" => "계약",
      "total" => 41,
      "index" => 1
    })

    assert has_element?(lv, "#document-search-counter", "1 of 41")

    lv |> element("#document-search-next") |> render_click()

    assert_push_event(
      lv,
      "document.search.command",
      %{action: "next", document_id: ^document_id, query: "계약"},
      1_000
    )

    lv |> element("#document-search-prev") |> render_click()

    assert_push_event(
      lv,
      "document.search.command",
      %{action: "prev", document_id: ^document_id, query: "계약"},
      1_000
    )

    render_hook(lv, "document.search.result_received", %{
      "document_id" => document_id,
      "query" => "stale",
      "total" => 2,
      "index" => 2
    })

    assert has_element?(lv, "#document-search-counter", "1 of 41")

    lv |> element("#document-search-close") |> render_click()

    assert_push_event(
      lv,
      "document.search.command",
      %{action: "close", document_id: ^document_id, query: "계약"},
      1_000
    )

    assert has_element?(lv, "#document-search-bar[hidden]")
    refute liveview_assign(lv, :document_search).open?

    render_hook(lv, "document.search.open", %{"document_id" => document_id})

    assert_push_event(
      lv,
      "document.search.command",
      %{action: "search", document_id: ^document_id, query: "계약"},
      1_000
    )

    open_document(lv, "template.hwpx")

    assert %{open?: false, query: "", document_id: nil} =
             liveview_assign(lv, :document_search)
  end

  test "local HWPX opens the browser-WASM shell and pushes the bytes URL to load", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn, document: "drafts/service.hwpx")

    render_async(lv, 2_000)
    _ = render_hwp_editor_html(lv)

    # HWP/HWPX render entirely in the browser now: the server stands up the
    # WasmHwpEditor shell (no server-side SVG stream) and tells the hook where to
    # fetch the document's raw bytes for `new HwpDocument(bytes)`.
    assert has_element?(lv, "#rhwp-shell")
    assert has_element?(lv, ~s([data-role="hwp-editor"][data-renderer="rhwp-wasm"]))

    assert has_element?(
             lv,
             ~s([data-role="hwp-editor"][phx-hook="EcritsWeb.Live.Studio.Components.Canvas.HwpPages.WasmHwpEditor"])
           )

    # The bytes URL points at the gated read-only route with the workspace +
    # document path, and the server pushes it as `document.hwp.load_command` on open.
    bytes_url = canvas_state(lv, ~s([data-role="hwp-editor"]))["bytesUrl"]

    assert is_binary(bytes_url)
    assert bytes_url =~ "/document-bytes?"
    assert bytes_url =~ "document=drafts%2Fservice.hwpx"

    # No server-side page rasterization happens; the hook builds the canvases.
    assert has_element?(lv, ~s([data-role="hwp-pages"][phx-update="ignore"]))
  end

  test "document query opens a local DOCX through the client WASM office editor", %{
    conn: conn
  } do
    {:ok, lv, _html} = open_workspace(conn, document: "drafts/reference.docx")

    assert has_element?(lv, "#rhwp-shell")
    assert has_element?(lv, "#studio-document-tab-drafts-reference-docx[data-active='true']")
    assert has_element?(lv, "#studio-document-tab-drafts-reference-docx", "reference.docx")

    # Office documents render SOLELY through the in-browser LibreOffice WASM
    # editor (the `WasmOfficeEditor` hook); there is no server-side LOK tile
    # render path.
    assert has_element?(
             lv,
             ~s([data-role="office-wasm-viewer"][data-renderer="libreoffice-wasm"][phx-hook="EcritsWeb.Live.Studio.Components.Canvas.OfficeWasm.WasmOfficeEditor"])
           )

    assert_canvas_state(lv, ~s([data-role="office-wasm-viewer"]), %{
      "localDocumentFormat" => "docx"
    })

    refute has_element?(lv, ~s([data-renderer="libreofficex-png-tiles"]))
    refute has_element?(lv, ~s([data-renderer="libreofficex-lok-edit"]))
    refute has_element?(lv, ~s([data-role="hwp-editor"]))
  end

  test "VFS semantic edits replay into the visible active office WASM editor", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "drafts/reference.docx")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="office-wasm-viewer"]), %{
      "documentPath" => "drafts/reference.docx"
    })

    assert_push_event(lv, "document.office.load_command", %{url: initial_url}, 1_000)
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
      "document.engine.operation.command",
      %{document_id: document_id, verb: "edit", payload: %{ops: [pushed_op]}},
      1_000
    )

    assert is_binary(document_id)
    assert pushed_op == op
    refute_push_event(lv, "document.office.load_command", %{document_id: ^document_id}, 200)

    sync_liveview(lv)

    bytes_url = canvas_state(lv, ~s([data-role="office-wasm-viewer"]))["bytesUrl"]

    assert bytes_url == initial_url
  end

  test "VFS edits without semantic ops reload the visible active office WASM editor", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "drafts/reference.docx")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="office-wasm-viewer"]), %{
      "documentPath" => "drafts/reference.docx"
    })

    assert_push_event(lv, "document.office.load_command", %{url: initial_url}, 1_000)
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
      "document.office.load_command",
      %{document_id: document_id, url: url},
      1_000
    )

    assert is_binary(document_id)
    assert url =~ "/document-bytes?"
    assert url =~ "document=drafts%2Freference.docx"
    assert url =~ "&v="

    sync_liveview(lv)

    bytes_url = canvas_state(lv, ~s([data-role="office-wasm-viewer"]))["bytesUrl"]

    assert bytes_url == url
  end

  test "workspace session restores open document tabs and persisted viewport on remount", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "document-restore-session", root)

    {:ok, lv, _html} = open_workspace(conn, root, document: "drafts/reference.docx")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="office-wasm-viewer"]), %{
      "documentPath" => "drafts/reference.docx"
    })

    render_hook(lv, "document.viewport.changed", %{
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

    assert_canvas_state(restored_lv, ~s([data-role="office-wasm-viewer"]), %{
      "documentPath" => "drafts/reference.docx",
      "scrollTop" => 321,
      "scrollLeft" => 7
    })
  end

  test "document query opens a local XLSX through the client WASM office editor", %{
    conn: conn
  } do
    {:ok, lv, _html} = open_workspace(conn, document: "drafts/ledger.xlsx")

    assert has_element?(lv, "#rhwp-shell")
    assert has_element?(lv, "#studio-document-tab-drafts-ledger-xlsx[data-active='true']")
    assert has_element?(lv, "#studio-document-tab-drafts-ledger-xlsx", "ledger.xlsx")

    assert has_element?(
             lv,
             ~s([data-role="office-wasm-viewer"][data-renderer="libreoffice-wasm"][phx-hook="EcritsWeb.Live.Studio.Components.Canvas.OfficeWasm.WasmOfficeEditor"])
           )

    assert_canvas_state(lv, ~s([data-role="office-wasm-viewer"]), %{
      "localDocumentFormat" => "xlsx"
    })

    refute has_element?(lv, ~s([data-renderer="libreofficex-png-tiles"]))
    refute has_element?(lv, ~s([data-renderer="libreofficex-lok-edit"]))
    refute has_element?(lv, ~s([data-role="hwp-editor"]))
  end

  test "file tree open event gives XLSX its own active document tab", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn, document: "drafts/reference.docx")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="office-wasm-viewer"]), %{
      "localDocumentFormat" => "docx"
    })

    assert has_element?(lv, "#studio-document-tab-drafts-reference-docx[data-active='true']")

    render_hook(lv, "workspace.document.open", %{"path" => "drafts/ledger.xlsx"})
    render_async(lv)

    assert has_element?(lv, "#studio-document-tab-drafts-reference-docx")
    assert has_element?(lv, "#studio-document-tab-drafts-ledger-xlsx[data-active='true']")
    assert has_element?(lv, "#studio-document-tab-drafts-ledger-xlsx", "ledger.xlsx")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="office-wasm-viewer"]), %{
      "localDocumentFormat" => "xlsx"
    })
  end

  test "non-ASCII documents of the same format keep distinct tabs", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    request_path = "프로젝트_요청서.hwpx"
    contract_path = "표준_계약서.hwpx"

    for path <- [request_path, contract_path] do
      File.cp!("test/fixtures/hwpx/real_contract.hwpx", Path.join(root, path))
    end

    {:ok, lv, _html} = open_workspace(conn)
    open_document(lv, request_path)
    open_document(lv, contract_path)

    assert has_element?(
             lv,
             ~s([data-role="document-tab"][title="#{request_path}"][data-active="false"]),
             Path.basename(request_path)
           )

    assert has_element?(
             lv,
             ~s([data-role="document-tab"][title="#{contract_path}"][data-active="true"]),
             Path.basename(contract_path)
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

    assert_canvas_state_after_open_sync(lv, ~s([data-role="office-wasm-viewer"]), %{
      "localDocumentFormat" => "xlsx"
    })

    session_id = subscribe_agent(lv)
    session_pid = AcpAgent.whereis(session_id)
    assert is_pid(session_pid)

    lv
    |> form("#agent-form", agent: %{message: "read this workbook"})
    |> render_submit()

    assert_receive {:agent_adapter_waiting, task_pid}, 2_000

    assert %{active_doc: active_doc, document_path: path} = AgentSession.tool_context(session_pid)
    assert is_binary(active_doc) and String.starts_with?(active_doc, "d_xlsx_")
    assert is_binary(path) and String.ends_with?(path, "drafts/ledger.xlsx")

    send(task_pid, :release_xlsx_context_probe)
    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 2_000
  end

  test "local composer upload imports a selected HWPX into the workspace and opens it", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    upload_name = "imported-service.hwpx"
    upload_path = Path.join(root, upload_name)
    upload_bytes = File.read!("test/fixtures/hwpx/real_contract.hwpx")

    refute File.exists?(upload_path)

    {:ok, lv, _html} = open_workspace(conn, root)

    upload =
      file_input(lv, "#agent-provider-options", :document_import, [
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
    assert has_element?(lv, "#rhwp-shell")

    assert_canvas_state(lv, ~s([data-role="hwp-editor"]), %{
      "localDocumentFormat" => "hwpx",
      "documentPath" => upload_name
    })

    refute has_element?(lv, "#document-direct-upload-input")
    refute has_element?(lv, ~s([phx-hook="DirectR2Upload"]))
  end

  test "document query opens a local HWPX with the same Studio editor surface", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn, document: "template.hwpx")

    assert_has_element_after_open_sync(
      lv,
      "#rhwp-shell[data-component='studio-document-surface']"
    )

    assert_has_element_after_open_sync(
      lv,
      "#studio-root[data-component='studio-document-surface']"
    )

    assert has_element?(lv, "#studio-document-header")
    refute has_element?(lv, "#file-tree-breadcrumb")
    assert has_element?(lv, "#studio-document-tabs[data-role='document-tabs']")
    assert has_element?(lv, "#studio-document-tab-template-hwpx[data-active='true']")
    assert has_element?(lv, "#studio-document-tab-template-hwpx", "template.hwpx")
    refute has_element?(lv, "#studio-document-header details")
    refute has_element?(lv, "#studio-document-header summary")
    refute has_element?(lv, "#studio-document-header [data-role='document-picker']")
    refute has_element?(lv, "#document-type-badge")
    refute has_element?(lv, "#studio-export-picker")
    assert has_element?(lv, "#rhwp-fullscreen[data-role='editor-fullscreen-toggle']")

    assert_canvas_state(lv, ~s([data-role="hwp-editor"]), %{
      "localDocumentFormat" => "hwpx",
      "documentPath" => "template.hwpx"
    })
  end

  test "header picker + fullscreen buttons are desktop controls without responsive gates", %{
    conn: conn
  } do
    {:ok, lv, _html} = open_workspace(conn, document: "template.hwpx")

    html = render(lv)

    picker_class = header_action_class(html, "#document-element-picker")
    assert picker_class =~ "inline-flex"
    refute picker_class =~ "md:inline-flex"
    refute picker_class =~ "lg:inline-flex"

    fullscreen_class = header_action_class(html, "#rhwp-fullscreen")
    assert fullscreen_class =~ "inline-flex"
    refute fullscreen_class =~ "md:inline-flex"
    refute fullscreen_class =~ "lg:inline-flex"

    fullscreen_click =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#rhwp-fullscreen")
      |> LazyHTML.attribute("phx-click")
      |> List.first()

    assert fullscreen_click == "workspace.editor_fullscreen.toggle"

    lv |> element("#rhwp-fullscreen") |> render_click()

    assert encoded_state?(
             lv,
             "#workspace-grid",
             "data-workspace-layout",
             %{"editorFullscreen" => true}
           )

    assert has_element?(lv, "#rhwp-fullscreen[aria-pressed='true']")
  end

  test "document element picker mode is stored in the workspace session", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")

    assert has_element?(lv, "#document-element-picker[aria-pressed='false']")

    lv
    |> element("#document-element-picker")
    |> render_click()

    assert has_element?(
             lv,
             "#document-element-picker[aria-pressed='true'][data-active='true']"
           )

    assert encoded_state?(
             lv,
             "#document-element-picker-bridge",
             "data-picker-state",
             %{"enabled" => true, "picks" => []}
           )

    {:ok, lv2, _html} = open_workspace(conn, root)
    render_async(lv2, 2_000)
    sync_liveview(lv2)

    assert_has_element_after_open_sync(lv2, "#document-element-picker[aria-pressed='true']")
    assert has_element?(lv2, "#document-element-picker[data-active='true']")
  end

  defp header_action_class(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> List.first()
  end

  test "local rhwp events load bytes, checkpoint, save, and reload saved bytes", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    relative_path = "drafts/service.hwpx"
    path = Path.join(root, relative_path)
    original = File.read!(path)

    {:ok, lv, _html} = open_workspace(conn, root, document: relative_path)

    render_async(lv, 2_000)
    _ = render_hwp_editor_html(lv)

    document_id = rhwp_document_id(lv)

    render_hook(lv, "document.hwp.load", %{"document_id" => document_id})
    assert has_element?(lv, "#rhwp-save-state", "Loaded -")

    render_hook(lv, "document.snapshot.checkpoint", %{
      "document_id" => document_id,
      "bytes_base64" => Base.encode64(original),
      "format" => "hwpx"
    })

    assert File.read!(path) == original
    assert has_element?(lv, "#rhwp-save-state", "Checkpointed - canonical file unchanged")

    saved = File.read!("test/fixtures/hwpx/real_contract.hwpx")

    render_hook(lv, "document.snapshot.save_requested", %{
      "document_id" => document_id,
      "bytes_base64" => Base.encode64(saved),
      "format" => "hwpx"
    })

    assert File.read!(path) == saved
    assert has_element?(lv, "#rhwp-save-state", "Saved -")

    {:ok, reloaded_lv, _html} = open_workspace(conn, root, document: relative_path)

    render_async(reloaded_lv, 2_000)
    _ = render_hwp_editor_html(reloaded_lv)

    assert_canvas_state(reloaded_lv, ~s([data-role="hwp-editor"]), %{
      "localDocumentFormat" => "hwpx"
    })
  end

  # The upload half of the :octet lane is a programmatic LiveView upload
  # (hook `uploadBytes`, no live_file_input), which `Phoenix.LiveViewTest`'s
  # client cannot drive yet — the pipeline is covered by the fork's upload
  # suites and browser verification. Server-side claim semantics stay here.
  @tag :edit_failure
  test "save events referencing an unknown octet id fail truthfully", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    relative_path = "drafts/service.hwpx"
    path = Path.join(root, relative_path)
    original = File.read!(path)

    {:ok, lv, _html} = open_workspace(conn, root, document: relative_path)

    render_async(lv, 2_000)
    _ = render_hwp_editor_html(lv)

    document_id = rhwp_document_id(lv)
    render_hook(lv, "document.hwp.load", %{"document_id" => document_id})

    render_hook(lv, "document.snapshot.save_requested", %{
      "document_id" => document_id,
      "octet_id" => "octet-never-uploaded",
      "format" => "hwpx"
    })

    assert File.read!(path) == original
    refute has_element?(lv, "#rhwp-save-state", "Saved -")
  end

  # Single-active-transfer is enforced by the octet channel ("upload already
  # in progress", see OctetChannelTest) and the client FIFO queue (JS suite).
  # The LiveView's contract is the sink: an unguessable id, subscribed on
  # mount and rendered for the channel client to join on.
  test "the octet lane renders its subscribed sink id for the channel client", %{
    conn: conn
  } do
    {:ok, lv, _html} = open_workspace(conn)

    sink_id = liveview_assign(lv, :octet_sink_id)
    assert is_binary(sink_id) and byte_size(sink_id) >= 32
    assert render(lv) =~ ~s(data-octet-sink="#{sink_id}")

    bytes = :crypto.strong_rand_bytes(64)
    send(lv.pid, {:octet_upload, "octet-sink-test", bytes})
    assert_push_event(lv, "octet:ack", %{id: "octet-sink-test", bytes: 64})
  end

  @tag :edit_failure
  test "a timed-out browser VFS write is removed, rolled back, and ignores its late octet reply",
       %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="hwp-editor"]), %{
      "localDocumentFormat" => "hwpx",
      "documentPath" => "template.hwpx"
    })

    edit_id = "browser-timeout-vfs"

    caller =
      Task.async(fn ->
        BrowserBridge.call(lv.pid, :vfs_write, %{edit_id: edit_id, ops: []}, timeout: 50)
      end)

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{
        request_id: request_id,
        document_id: document_id,
        verb: "vfs_write",
        payload: %{edit_id: ^edit_id}
      },
      1_000
    )

    assert {:error, {:browser_timeout, "viewer did not reply in time"}} =
             Task.await(caller, 1_000)

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{
        document_id: ^document_id,
        verb: "vfs_rollback",
        payload: %{edit_id: ^edit_id}
      },
      1_000
    )

    sync_liveview(lv)
    assert liveview_assign(lv, :doc_browser_pending) == %{}

    octet_id = "late-timeout-octet"
    put_liveview_octet(lv, octet_id, "late exported document")

    render_hook(lv, "document.engine.operation.replied", %{
      "request_id" => request_id,
      "result" => %{"edit_id" => edit_id, "octet_id" => octet_id}
    })

    assert liveview_assign(lv, :octet_stash) == %{}
    assert liveview_assign(lv, :doc_browser_pending) == %{}
  end

  test "a dead browser VFS caller is removed and rolled back before a late reply", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="hwp-editor"]), %{
      "localDocumentFormat" => "hwpx",
      "documentPath" => "template.hwpx"
    })

    owner = self()
    edit_id = "browser-dead-caller-vfs"
    ref = make_ref()

    caller =
      spawn(fn ->
        send(lv.pid, {:doc_browser_request, self(), ref, :vfs_write, %{edit_id: edit_id}})
        send(owner, {:browser_caller_waiting, self()})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:browser_caller_waiting, ^caller}

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{
        request_id: request_id,
        document_id: document_id,
        verb: "vfs_write",
        payload: %{edit_id: ^edit_id}
      },
      1_000
    )

    caller_monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{
        document_id: ^document_id,
        verb: "vfs_rollback",
        payload: %{edit_id: ^edit_id}
      },
      1_000
    )

    sync_liveview(lv)
    assert liveview_assign(lv, :doc_browser_pending) == %{}

    render_hook(lv, "document.engine.operation.replied", %{
      "request_id" => request_id,
      "result" => %{"edit_id" => edit_id, "ok" => true}
    })

    assert liveview_assign(lv, :doc_browser_pending) == %{}
  end

  test "switching documents cancels a pending browser write immediately", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    expected_document_id = liveview_assign(lv, :pool_document_id)
    edit_id = "browser-switch-vfs"

    caller =
      Task.async(fn ->
        BrowserBridge.call(lv.pid, :vfs_write, %{edit_id: edit_id},
          expected_document_id: expected_document_id,
          timeout: 1_000
        )
      end)

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{document_id: old_view_document_id, verb: "vfs_write", payload: %{edit_id: ^edit_id}},
      1_000
    )

    open_document(lv, "drafts/service.hwpx")

    assert {:error, :document_changed} = Task.await(caller, 250)

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{
        document_id: ^old_view_document_id,
        verb: "vfs_rollback",
        payload: %{edit_id: ^edit_id}
      },
      1_000
    )

    assert liveview_assign(lv, :doc_browser_pending) == %{}
    assert liveview_assign(lv, :doc_browser_vfs_leases) == %{}
  end

  test "a routed browser request is rejected after its document changed before dispatch", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    stale_document_id = liveview_assign(lv, :pool_document_id)

    open_document(lv, "drafts/service.hwpx")
    active_document_id = liveview_assign(lv, :pool_document_id)
    refute active_document_id == stale_document_id

    assert {:error,
            {:document_mismatch, %{expected: ^stale_document_id, actual: ^active_document_id}}} =
             BrowserBridge.call(lv.pid, :vfs_write, %{edit_id: "stale-route"},
               expected_document_id: stale_document_id,
               timeout: 1_000
             )

    refute_push_event(
      lv,
      "document.engine.operation.command",
      %{verb: "vfs_write", payload: %{edit_id: "stale-route"}},
      100
    )

    assert liveview_assign(lv, :doc_browser_pending) == %{}
  end

  test "a successful browser write keeps a lease that rolls back when its owner dies", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    expected_document_id = liveview_assign(lv, :pool_document_id)
    owner = self()
    edit_id = "browser-leased-vfs"

    caller =
      spawn(fn ->
        result =
          BrowserBridge.call(lv.pid, :vfs_write, %{edit_id: edit_id},
            expected_document_id: expected_document_id,
            timeout: 1_000
          )

        # This system-message barrier is sent by the same process after the
        # BrowserBridge ACK, so the LiveView has installed the lease before the
        # test is told the call returned.
        _ = :sys.get_state(lv.pid)
        send(owner, {:leased_browser_write_returned, self(), result})

        receive do
          :hold -> :ok
        end
      end)

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{
        request_id: request_id,
        document_id: view_document_id,
        verb: "vfs_write",
        payload: %{edit_id: ^edit_id}
      },
      1_000
    )

    render_hook(lv, "document.engine.operation.replied", %{
      "request_id" => request_id,
      "result" => %{"edit_id" => edit_id, "bytes" => "exported"}
    })

    assert_receive {:leased_browser_write_returned, ^caller,
                    {:ok, %{"edit_id" => ^edit_id, "bytes" => "exported"}}}

    assert map_size(liveview_assign(lv, :doc_browser_vfs_leases)) == 1

    caller_monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{
        document_id: ^view_document_id,
        verb: "vfs_rollback",
        payload: %{edit_id: ^edit_id}
      },
      1_000
    )

    sync_liveview(lv)
    assert liveview_assign(lv, :doc_browser_pending) == %{}
    assert liveview_assign(lv, :doc_browser_vfs_leases) == %{}
  end

  test "a browser commit reply remains rollback-capable until its bridge completion ACK", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    expected_document_id = liveview_assign(lv, :pool_document_id)
    edit_id = "browser-unacknowledged-commit"

    write_ref = make_ref()

    send(
      lv.pid,
      {:doc_browser_request, self(), write_ref, :vfs_write, %{edit_id: edit_id},
       expected_document_id}
    )

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{request_id: write_request_id, verb: "vfs_write", payload: %{edit_id: ^edit_id}},
      1_000
    )

    render_hook(lv, "document.engine.operation.replied", %{
      "request_id" => write_request_id,
      "result" => %{"edit_id" => edit_id, "bytes" => "exported"}
    })

    assert_receive {:doc_browser_reply, ^write_ref, {:ok, %{"edit_id" => ^edit_id}}}
    send(lv.pid, {:doc_browser_request_completed, self(), write_ref})
    sync_liveview(lv)
    assert map_size(liveview_assign(lv, :doc_browser_vfs_leases)) == 1

    commit_ref = make_ref()

    send(
      lv.pid,
      {:doc_browser_request, self(), commit_ref, :vfs_commit, %{edit_id: edit_id},
       expected_document_id}
    )

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{request_id: commit_request_id, verb: "vfs_commit", payload: %{edit_id: ^edit_id}},
      1_000
    )

    render_hook(lv, "document.engine.operation.replied", %{
      "request_id" => commit_request_id,
      "result" => %{"edit_id" => edit_id, "awaiting_finalize" => true}
    })

    assert_receive {:doc_browser_reply, ^commit_ref,
                    {:ok, %{"edit_id" => ^edit_id, "awaiting_finalize" => true}}}

    send(lv.pid, {:doc_browser_request_cancelled, self(), commit_ref, :timeout})

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{verb: "vfs_rollback", payload: %{edit_id: ^edit_id}},
      1_000
    )

    refute_push_event(
      lv,
      "document.engine.operation.command",
      %{verb: "vfs_finalize", payload: %{edit_id: ^edit_id}},
      100
    )

    sync_liveview(lv)
    assert liveview_assign(lv, :doc_browser_pending) == %{}
    assert liveview_assign(lv, :doc_browser_vfs_leases) == %{}
  end

  test "a bridge completion ACK finalizes a successful browser commit exactly once", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    expected_document_id = liveview_assign(lv, :pool_document_id)
    edit_id = "browser-acknowledged-commit"

    write_ref = make_ref()

    send(
      lv.pid,
      {:doc_browser_request, self(), write_ref, :vfs_write, %{edit_id: edit_id},
       expected_document_id}
    )

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{request_id: write_request_id, verb: "vfs_write", payload: %{edit_id: ^edit_id}},
      1_000
    )

    render_hook(lv, "document.engine.operation.replied", %{
      "request_id" => write_request_id,
      "result" => %{"edit_id" => edit_id, "bytes" => "exported"}
    })

    assert_receive {:doc_browser_reply, ^write_ref, {:ok, %{"edit_id" => ^edit_id}}}
    send(lv.pid, {:doc_browser_request_completed, self(), write_ref})
    sync_liveview(lv)

    commit_ref = make_ref()

    send(
      lv.pid,
      {:doc_browser_request, self(), commit_ref, :vfs_commit, %{edit_id: edit_id},
       expected_document_id}
    )

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{request_id: commit_request_id, verb: "vfs_commit", payload: %{edit_id: ^edit_id}},
      1_000
    )

    render_hook(lv, "document.engine.operation.replied", %{
      "request_id" => commit_request_id,
      "result" => %{"edit_id" => edit_id, "awaiting_finalize" => true}
    })

    assert_receive {:doc_browser_reply, ^commit_ref,
                    {:ok, %{"edit_id" => ^edit_id, "awaiting_finalize" => true}}}

    send(lv.pid, {:doc_browser_request_completed, self(), commit_ref})

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{
        request_id: finalize_request_id,
        verb: "vfs_finalize",
        payload: %{edit_id: ^edit_id}
      },
      1_000
    )

    sync_liveview(lv)
    assert liveview_assign(lv, :doc_browser_vfs_leases) == %{}

    assert %{
             ^finalize_request_id => %{kind: :vfs_finalize, status: :waiting}
           } = liveview_assign(lv, :doc_browser_pending)

    render_hook(lv, "document.engine.operation.replied", %{
      "request_id" => finalize_request_id,
      "result" => %{"edit_id" => edit_id, "finalized" => true}
    })

    assert liveview_assign(lv, :doc_browser_pending) == %{}

    render_hook(lv, "document.engine.operation.replied", %{
      "request_id" => finalize_request_id,
      "result" => %{"edit_id" => edit_id, "already_finalized" => true}
    })

    assert liveview_assign(lv, :doc_browser_pending) == %{}
  end

  test "lost finalize replies retry idempotently then reload committed bytes without rollback", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    expected_document_id = liveview_assign(lv, :pool_document_id)
    edit_id = "browser-finalize-recovery"

    {finalize_request_id, browser_document_id} =
      prepare_acknowledged_browser_commit(lv, expected_document_id, edit_id)

    for attempt <- 1..2 do
      send(lv.pid, {:doc_browser_finalize_timeout, finalize_request_id, attempt})

      assert_push_event(
        lv,
        "document.engine.operation.command",
        %{
          request_id: ^finalize_request_id,
          document_id: ^browser_document_id,
          verb: "vfs_finalize",
          payload: %{edit_id: ^edit_id}
        },
        1_000
      )
    end

    send(lv.pid, {:doc_browser_finalize_timeout, finalize_request_id, 3})

    assert_push_event(
      lv,
      "document.hwp.load_command",
      %{
        document_id: ^browser_document_id,
        force: true,
        vfs_recovery: true,
        vfs_recovery_id: recovery_id,
        vfs_recovery_attempt: 1
      },
      1_000
    )

    assert %{
             ^recovery_id => %{kind: :vfs_recovery, status: :waiting, attempt: 1}
           } = liveview_assign(lv, :doc_browser_pending)

    render_hook(lv, "document.vfs.recovery.replied", %{
      "recovery_id" => recovery_id,
      "attempt" => 1,
      "error" => "canonical document reload failed"
    })

    assert_push_event(
      lv,
      "document.hwp.load_command",
      %{
        document_id: ^browser_document_id,
        force: true,
        vfs_recovery: true,
        vfs_recovery_id: ^recovery_id,
        vfs_recovery_attempt: 2
      },
      1_000
    )

    render_hook(lv, "document.vfs.recovery.replied", %{
      "recovery_id" => recovery_id,
      "attempt" => 2,
      "result" => %{"reloaded" => true}
    })

    refute_push_event(
      lv,
      "document.engine.operation.command",
      %{verb: "vfs_rollback", payload: %{edit_id: ^edit_id}},
      100
    )

    sync_liveview(lv)
    assert liveview_assign(lv, :doc_browser_pending) == %{}
    assert liveview_assign(lv, :doc_browser_vfs_leases) == %{}
  end

  test "cancelling missing octet entries leaves the owning LiveView alive", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()

    {:ok, lv, _html} = open_workspace(conn, root, document: "drafts/service.hwpx")
    pid = lv.pid

    render_hook(lv, "octet:cancel", %{
      "id" => "octet-already-finished",
      "entry_refs" => ["missing-entry"]
    })

    _ = :sys.get_state(pid)
    assert lv.pid == pid
  end

  @tag :edit_failure
  test "channel cancellation removes an upload that overtook the client stash drop", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "drafts/service.hwpx")
    id = "octet-cancel-overtake"
    bytes = "late committed octet"

    _ = render_hook(lv, "octet:cancel", %{"id" => id})
    assert liveview_assign(lv, :octet_stash) == %{}

    send(lv.pid, {:octet_upload, id, bytes})
    assert_push_event(lv, "octet:ack", %{id: ^id, bytes: 20})
    assert liveview_assign(lv, :octet_stash) == %{id => bytes}

    send(lv.pid, {:octet_cancelled, id})
    sync_liveview(lv)

    assert liveview_assign(lv, :octet_stash) == %{}
  end

  test "local rhwp text mutation is acknowledged and does not remount", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()

    {:ok, lv, _html} = open_workspace(conn, root, document: "drafts/service.hwpx")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="hwp-editor"]), %{
      "localDocumentFormat" => "hwpx",
      "documentPath" => "drafts/service.hwpx"
    })

    pid = lv.pid
    document_id = rhwp_document_id(lv)

    render_hook(lv, "document.content.changed", %{
      "documentId" => document_id,
      "eventId" => "edit-1",
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

    assert_canvas_state(lv, ~s([data-role="hwp-editor"]), %{
      "localDocumentId" => document_id
    })

    assert {:ok, %Document{id: ^document_id}} = Document.document(document_id)
  end

  test "agent form reports real provider unavailable without fake response", %{conn: conn} do
    missing = "ecrits-codex-missing-#{Ecto.UUID.generate()}"

    Application.put_env(:ecrits, :agent_ui,
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        fail_with: "executable_not_found: #{missing}"
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "hello local"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{
                      type: :turn_failed,
                      session_id: ^session_id
                    }},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "hello local"
           )

    assert has_element?(
             lv,
             ~s([id^="agent-user-"][data-chat-role="chat-message"] [data-role="chat-message-body"]),
             "hello local"
           )

    assert has_element?(lv, "#agent-sidebar[data-agent-status='failed']")
    assert has_element?(lv, "#agent-error", "Codex ACP unavailable")
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

    root = WorkspaceAdapterStub.valid_path()

    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")

    session_id = subscribe_agent(lv)
    session_pid = AcpAgent.whereis(session_id)
    assert is_pid(session_pid)

    lv
    |> form("#agent-form", agent: %{message: "read this document"})
    |> render_submit()

    assert_receive {:agent_adapter_waiting, task_pid}, 2_000

    # The agent binds doc.* context at send time — the UNIFIED document handle
    # points at what's on screen without relying on idle session mutation.
    assert %{active_doc: active_doc, document_path: path} = AgentSession.tool_context(session_pid)
    assert is_binary(active_doc) and String.starts_with?(active_doc, "d_hwpx_")
    assert is_binary(path) and String.ends_with?(path, "template.hwpx")

    send(task_pid, :release_context_probe)
    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 2_000
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

    root = WorkspaceAdapterStub.valid_path()

    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")

    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "read this document"})
    |> render_submit()

    assert_receive {:fake_acp_prompt, _sid, prompt}, 1_000
    mount_status = Ecrits.Fuse.DocMount.status()
    mounted? = Ecrits.Fuse.DocMount.mounted?(root)
    normalized_prompt = String.replace(prompt, ~r/\s+/, " ")

    cond do
      mount_status.enabled? and mounted? ->
        assert byte_size(normalized_prompt) <= 800
        assert normalized_prompt =~ "do not edit read-only requests"
        assert normalized_prompt =~ "Open the document once with `doc.open_doc`"
        assert normalized_prompt =~ "ACP read/search/edit for text and tables"
        assert normalized_prompt =~ "shell search stays read-only"
        assert normalized_prompt =~ "Keep every document mutation in ACP"
        assert normalized_prompt =~ "scripted shell rewrites"
        assert normalized_prompt =~ "For brief-driven fills"
        assert normalized_prompt =~ "every field, list item, and table row"
        assert normalized_prompt =~ "one `미기재` in each unsupported blank"
        assert normalized_prompt =~ "reread changed ACP payloads"
        assert normalized_prompt =~ "one post-commit `doc.find`"
        assert normalized_prompt =~ "one image-only `doc.edit`"
        refute normalized_prompt =~ "path: \"current\""
        refute normalized_prompt =~ "payment schedule"
        refute normalized_prompt =~ "first recipient"
        refute normalized_prompt =~ "arbitrator"
        refute normalized_prompt =~ "Article 51"
        refute normalized_prompt =~ "annex 631"
        refute normalized_prompt =~ "`(인)`"

        # The mounted policy deliberately establishes the edit boundary without
        # teaching an ACP agent a JSONL rewrite recipe.
        refute prompt =~ "create the temp file"
        refute prompt =~ "`mktemp`"
        refute prompt =~ ~s({"type":"table")
        refute prompt =~ ~s({"type":"picture")
        refute prompt =~ "HWPUNIT"
        refute prompt =~ "ref.cellPath"
        refute prompt =~ "doc.close_doc"
        refute prompt =~ "doc.context"
        refute prompt =~ "temp_path"
        refute prompt =~ "mounted_at"

      mount_status.enabled? ->
        assert prompt =~ "Doc VFS backend is available, but this workspace is not mounted"
        assert prompt =~ mount_status.message
        assert normalized_prompt =~ "Report the unavailable ACP document surface"
        assert normalized_prompt =~ "Read-only shell search and inspection may continue"
        assert normalized_prompt =~ "never bypass ACP"
        assert normalized_prompt =~ "doc.edit for text or tables"
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

        assert normalized_prompt =~ "Report the unavailable ACP document surface"
        assert normalized_prompt =~ "Read-only shell search and inspection may continue"
        assert normalized_prompt =~ "never bypass ACP"
        assert normalized_prompt =~ "doc.edit for text or tables"
        refute prompt =~ "documents are EDITABLE FILES"

      true ->
        assert prompt =~ "Use doc MCP tools"
        assert prompt =~ "doc.context"
        assert prompt =~ "current_document.document"
        refute prompt =~ "VFS mode"
    end

    refute prompt =~ "template.hwpx"
    refute prompt =~ "pass this as `document`"

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)
  end

  test "manual VFS enable subscribes direct VFS edit previews", %{conn: conn} do
    previous_vfs = Application.get_env(:ecrits, :doc_vfs)
    on_exit(fn -> restore_doc_vfs_env(previous_vfs) end)

    root = WorkspaceAdapterStub.valid_path()
    Application.put_env(:ecrits, :doc_vfs, enabled: false)

    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    session_id = subscribe_agent(lv)
    seed_known_vfs_turn(session_id, "manual-vfs-preview-turn")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="hwp-editor"]), %{
      "localDocumentFormat" => "hwpx",
      "documentPath" => "template.hwpx"
    })

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
             agent_id: session_id,
             instance_id: agent_instance_id(session_id),
             turn_id: "manual-vfs-preview-turn",
             path: Path.join(root, "template.hwpx"),
             doc: "template.hwpx",
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

        assert_preview_state(lv, %{
          "documentPath" => "template.hwpx",
          "deltaCount" => 1
        })

        assert has_element?(
                 lv,
                 ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"])
               )

        refute has_element?(lv, ~s([data-role="editor-preview-image"]))

        assert [%{items: items}] = AcpAgent.agent_snapshot(session_id).transcript
        assert Enum.any?(items, &(Map.get(&1, :role) == :edit_preview))

        refute has_element?(lv, ~s([data-role="edit-preview-card"]))
        refute has_element?(lv, ~s([data-role="doc-edit-card"]))
    end
  end

  test "VFS edit for a cold workspace document renders a durable descriptor and renderer preview",
       %{
         conn: conn
       } do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root)
    session_id = subscribe_agent(lv)
    seed_known_vfs_turn(session_id, "cold-vfs-preview-turn")

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: "cold-vfs-preview-turn",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 1,
         marker: "SYNTHETIC_COLD_VFS_PREVIEW",
         highlights: [
           %{
             "kind" => "text",
             "op" => "replace_text",
             "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
             "text" => "SYNTHETIC_COLD_VFS_PREVIEW"
           }
         ]
       }}
    )

    sync_liveview(lv)

    refute has_element?(lv, "#studio-document-tab-template-hwpx")

    assert_preview_state(lv, %{"documentPath" => "template.hwpx", "deltaCount" => 1})

    assert has_element?(
             lv,
             ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"])
           )

    refute has_element?(lv, ~s([data-role="editor-preview-image"]))

    refute has_element?(lv, ~s([data-role="edit-preview-card"]))
    refute has_element?(lv, ~s([data-role="doc-edit-card"]))

    assert [%Dialog{items: items}] = AcpAgent.agent_snapshot(session_id).transcript

    assert Enum.any?(items, fn item ->
             Map.get(item, :role) == :edit_preview and
               Map.get(item, :document_path) == "template.hwpx" and
               Map.get(item, :backend) == "ehwp" and
               Map.get(item, :mode) == "descriptor" and
               is_map(Map.get(item, :version))
           end)

    stop_pid(lv.pid)
    sync_workspace_session(root)

    {:ok, lv2, _html2} = open_workspace(conn, root)

    lv2
    |> element("#agent-rail-picker")
    |> render_click()

    lv2
    |> element("#agent-rail-option-#{session_id}")
    |> render_click()

    sync_liveview(lv2)

    assert_preview_state(lv2, %{"documentPath" => "template.hwpx", "deltaCount" => 1})

    assert has_element?(
             lv2,
             ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"])
           )

    refute has_element?(lv2, ~s([data-role="editor-preview-image"]))

    refute has_element?(lv2, ~s([data-role="doc-edit-card"]))
  end

  @tag :edit_failure
  test "the traced VFS event renders one stable chat-rail preview without a full edit trip", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    relative_path = "template.hwpx"
    markdown_path = "MANIFEST.md"
    turn_id = "dbg-preview-render-path"
    edit_id = "dbg-preview-render-edit"
    tab_id = "dbg-preview-render-tab"

    File.write!(Path.join(root, markdown_path), "# Preview switch target\n")

    {:ok, lv, _html} =
      open_workspace(conn, root,
        document: relative_path,
        chat_rail_tab_id: tab_id
      )

    session_id = subscribe_agent(lv)
    seed_known_vfs_turn(session_id, turn_id)

    ref = %{"section" => 0, "paragraph" => 0, "offset" => 0}

    ops = [
      %{"op" => "delete_range", "ref" => ref, "count" => 6},
      %{"op" => "insert_text", "ref" => ref, "text" => "미리보기 경로 기록"}
    ]

    highlights = [
      %{
        "kind" => "text",
        "op" => "insert_text",
        "ref" => ref,
        "offset" => 0,
        "length" => 10,
        "text" => "미리보기 경로 기록"
      }
    ]

    info = %{
      agent_id: session_id,
      instance_id: agent_instance_id(session_id),
      turn_id: turn_id,
      edit_id: edit_id,
      path: Path.join(root, relative_path),
      doc: relative_path,
      applied: 2,
      delta_applied: 2,
      progress_index: 1,
      progress_total: 1,
      ops: ops,
      sets: [],
      highlights: highlights
    }

    send_vfs_edit_and_wait(lv, info)

    expected_summary =
      "template.hwpx: 1 change — delete_range; insert_text"

    assert has_element?(lv, ~s([data-role="editor-preview-summary"]), expected_summary)

    assert has_element?(
             lv,
             ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"])
           )

    assert_preview_state(lv, %{
      "documentPath" => relative_path,
      "deltaCount" => 1
    })

    first_state = mixed_preview_canvas_state(lv)
    first_rows = mixed_preview_chat_rows(lv)
    first_preview_id = mixed_preview_row_id(first_rows)

    assert Jason.decode!(first_state["previewHighlights"]) == highlights
    assert [descriptor] = mixed_preview_descriptors(session_id, turn_id)
    assert descriptor.edit_id == edit_id
    assert descriptor.applied == 1
    assert descriptor.ops == ops
    assert descriptor.highlights == highlights

    # The runtime trace replayed this exact event. It must upsert the same
    # descriptor and stream row instead of duplicating the chat preview.
    send_vfs_edit_and_wait(lv, info)

    assert [_descriptor] = mixed_preview_descriptors(session_id, turn_id)
    assert mixed_preview_row_id(mixed_preview_chat_rows(lv)) == first_preview_id
    assert mixed_preview_canvas_state(lv) == first_state

    open_document(lv, markdown_path)

    assert has_element?(lv, ~s([data-role="markdown-editor"]))
    assert {:safe, _preview_html} = liveview_assign(lv, :markdown_preview_html)
    assert mixed_preview_row_id(mixed_preview_chat_rows(lv)) == first_preview_id
    assert mixed_preview_canvas_state(lv) == first_state
    assert has_element?(lv, ~s([data-role="editor-preview-summary"]), expected_summary)

    stop_pid(lv.pid)
    sync_workspace_session(root)

    {:ok, replayed, _html} =
      open_workspace(conn, root, chat_rail_tab_id: tab_id)

    render_async(replayed, 2_000)
    sync_liveview(replayed)

    assert subscribe_agent(replayed) == session_id
    assert mixed_preview_row_id(mixed_preview_chat_rows(replayed)) == first_preview_id
    assert mixed_preview_canvas_state(replayed) == first_state

    assert has_element?(
             replayed,
             ~s([data-role="editor-preview-summary"]),
             expected_summary
           )
  end

  test "VFS preview persists edit composition and scroll without rendered image payloads", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    session_id = subscribe_agent(lv)
    seed_known_vfs_turn(session_id, "composition-vfs-preview-turn")

    render_hook(lv, "document.viewport.changed", %{
      "document_path" => "template.hwpx",
      "top" => 321,
      "left" => 7
    })

    sync_workspace_session(root)

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: "composition-vfs-preview-turn",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 2,
         preview_base_url: "blob:http://localhost/transient-preview",
         ops: [
           %{
             "op" => "insert_picture",
             "image_base64" => "data:image/png;base64,live-playback-bytes"
           }
         ],
         composition_ops: [
           %{
             "op" => "insert_picture",
             "src" => "/tmp/brand.png",
             "image_base64" => "data:image/png;base64,rendered-bytes",
             "nested" => %{"bytes" => <<1, 2, 3>>}
           }
         ],
         sets: [
           %{
             "ref" => "picture[brand]",
             "props" => %{"x" => 42, "imageBase64" => "rendered-bytes"}
           }
         ],
         highlights: [
           %{
             "kind" => "picture",
             "ref" => %{"section" => 0, "paragraph" => 0, "controlIndex" => 0},
             "text" => "brand mark",
             "bytes_base64" => "rendered-highlight-bytes"
           }
         ]
       }}
    )

    sync_liveview(lv)

    transcript_items =
      session_id
      |> AcpAgent.agent_snapshot()
      |> Map.fetch!(:transcript)
      |> Enum.flat_map(&Map.get(&1, :items, []))

    persisted = Enum.find(transcript_items, &(Map.get(&1, :role) == :edit_preview))

    assert persisted.scroll == %{scroll_top: 321, scroll_left: 7}

    assert [%{"op" => "insert_picture", "src" => "/tmp/brand.png", "nested" => %{}}] =
             persisted.ops

    assert [%{"ref" => "picture[brand]", "props" => %{"x" => 42}}] = persisted.sets

    assert [
             %{
               "kind" => "picture",
               "ref" => %{"section" => 0, "paragraph" => 0, "controlIndex" => 0},
               "text" => "brand mark"
             }
           ] = persisted.highlights

    serialized = inspect(persisted, limit: :infinity, printable_limit: :infinity)
    refute serialized =~ "data:image"
    refute serialized =~ "blob:"
    refute serialized =~ "image_base64"
    refute serialized =~ "imageBase64"
    refute serialized =~ "bytes_base64"
    refute serialized =~ "rendered-bytes"

    assert has_element?(
             lv,
             ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"])
           )

    refute has_element?(lv, ~s([data-role="editor-preview-image"]))

    assert_canvas_state(
      lv,
      ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"]),
      %{"scrollTop" => 321, "scrollLeft" => 7}
    )
  end

  test "native picture fallback composes into the immutable VFS preview across switch and replay",
       %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    picture_path = Path.join(root, "signature.png")
    File.write!(picture_path, "signature image")

    pool_document_id =
      Ecrits.Doc.Pool.document_id_for(Path.join(root, "template.hwpx"), :hwpx)

    picture_ref = %{
      "section" => 0,
      "paragraph" => 0,
      "offset" => 2,
      "cellPath" => [%{"controlIndex" => 0, "cellIndex" => 3, "cellParaIndex" => 0}]
    }

    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_mixed_preview_turn,
        script: [
          %{
            type: :tool_call_started,
            id: "mixed-picture-edit",
            name: "doc.edit",
            arguments: %{
              "document" => pool_document_id,
              "op" => %{
                "op" => "insert_picture",
                "ref" => Jason.encode!(picture_ref),
                "src" => picture_path
              },
              "fallback" => %{
                "attempted" => "vfs",
                "reason" => "unrepresentable"
              }
            }
          },
          %{
            type: :tool_call_completed,
            id: "mixed-picture-edit",
            name: "doc.edit",
            result: %{
              "ok" => true,
              "applied" => 1,
              "native" => [%{"paraIdx" => 0, "controlIdx" => 1}]
            }
          },
          {:text_delta, "완료했습니다."}
        ]
      ]
    )

    conn = init_workspace_session(conn, "mixed-preview-composition", root)
    tab_id = "mixed-preview-composition-tab"

    {:ok, lv, _html} =
      open_workspace(conn, root,
        document: "template.hwpx",
        chat_rail_tab_id: tab_id
      )

    session_id = subscribe_agent(lv)
    assert liveview_assign(lv, :pool_document_id) == pool_document_id

    lv
    |> form("#agent-form", agent: %{message: "표를 만들고 (인)에 서명을 넣어줘"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, session_id: ^session_id, turn_id: turn_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, stream_pid}, 1_000

    vfs_ops = [
      %{
        "op" => "insert_table",
        "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
        "rows" => 1,
        "cols" => 1,
        "cells" => [["서명"]]
      },
      %{
        "op" => "set_cell",
        "ref" => %{
          "section" => 0,
          "paragraph" => 0,
          "cell" => %{
            "parentParaIndex" => 0,
            "controlIndex" => 0,
            "cellIndex" => 0,
            "cellParaIndex" => 0
          }
        },
        "replacement" => "(인)"
      }
    ]

    vfs_highlights = [
      %{
        "kind" => "table",
        "op" => "insert_table",
        "ref" => %{
          "section" => 0,
          "paragraph" => 0,
          "cell" => %{
            "parentParaIndex" => 0,
            "controlIndex" => 0,
            "cellIndex" => 0,
            "cellParaIndex" => 0
          }
        },
        "text" => "서명"
      },
      %{
        "kind" => "text",
        "op" => "set_cell",
        "ref" => picture_ref,
        "text" => "(인)"
      }
    ]

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: turn_id,
         edit_id: "mixed-vfs-edit",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 2,
         progress_index: 1,
         progress_total: 1,
         composition_ops: vfs_ops,
         highlights: vfs_highlights
       }}
    )

    sync_liveview(lv)

    before_native = mixed_preview_descriptor(session_id, turn_id)
    assert before_native.applied == 1
    assert before_native.ops == vfs_ops
    before_state = mixed_preview_canvas_state(lv)
    before_rows = mixed_preview_chat_rows(lv)
    before_preview_id = mixed_preview_row_id(before_rows)
    assert mixed_preview_row_index(before_rows, before_preview_id) != nil

    send(stream_pid, :release_mixed_preview_turn)

    assert_receive {:agent_event,
                    %{
                      type: :tool_call_completed,
                      session_id: ^session_id,
                      turn_id: ^turn_id,
                      tool_call_id: "mixed-picture-edit"
                    }},
                   1_000

    assert_receive {:agent_event,
                    %{type: :turn_completed, session_id: ^session_id, turn_id: ^turn_id}},
                   1_000

    sync_liveview(lv)

    [composed] = mixed_preview_descriptors(session_id, turn_id)

    assert composed.edit_id == before_native.edit_id
    assert composed.preview_identity == before_native.preview_identity
    assert composed.preview_snapshot == before_native.preview_snapshot
    assert composed.applied == 2

    assert composed.ops ==
             vfs_ops ++
               [
                 %{
                   "op" => "insert_picture",
                   "ref" => Jason.encode!(picture_ref),
                   "src" => picture_path
                 }
               ]

    assert composed.highlights ==
             vfs_highlights ++
               [
                 %{
                   "kind" => "picture",
                   "op" => "insert_picture",
                   "ref" => %{
                     "section" => 0,
                     "paragraph" => 0,
                     "control" => 1,
                     "type" => "picture"
                   },
                   "text" => "signature.png"
                 }
               ]

    composed_state = mixed_preview_canvas_state(lv)
    composed_rows = mixed_preview_chat_rows(lv)
    assert mixed_preview_row_id(composed_rows) == before_preview_id

    assert mixed_preview_row_index(composed_rows, before_preview_id) <
             mixed_preview_row_index(composed_rows, "agent-tool-mixed-picture-edit")

    assert_preview_state(lv, %{"deltaCount" => 2})
    assert Jason.decode!(composed_state["previewHighlights"]) == composed.highlights
    assert composed_state["bytesUrl"] == before_state["bytesUrl"]
    refute has_element?(lv, "#agent-error")

    open_document(lv, "drafts/service.hwpx")
    switched_state = mixed_preview_canvas_state(lv)
    assert switched_state == composed_state
    assert mixed_preview_chat_rows(lv) == composed_rows
    refute has_element?(lv, "#agent-error")

    stop_pid(lv.pid)
    sync_workspace_session(root)

    {:ok, replayed_lv, _html} =
      open_workspace(conn, root, chat_rail_tab_id: tab_id)

    render_async(replayed_lv, 2_000)
    sync_liveview(replayed_lv)
    assert subscribe_agent(replayed_lv) == session_id
    assert mixed_preview_canvas_state(replayed_lv) == composed_state
    assert mixed_preview_chat_rows(replayed_lv) == composed_rows
    assert [replayed_descriptor] = mixed_preview_descriptors(session_id, turn_id)
    assert replayed_descriptor == composed
    refute has_element?(replayed_lv, "#agent-error")
  end

  test "committed VFS continuation replaces the racing live preview with durable final bytes", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    session_id = subscribe_agent(lv)
    seed_known_vfs_turn(session_id, "immutable-vfs-preview-turn")
    final_bytes = File.read!(Path.join(root, "template.hwpx"))
    final_sha256 = Document.sha256(final_bytes)

    edit_id = "vfs-edit-immutable-preview"

    highlights = [
      %{
        "kind" => "text",
        "op" => "replace_text",
        "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
        "offset" => 0,
        "length" => 6,
        "text" => "수정 완료"
      }
    ]

    preview_steps = [
      %{
        "ops" => [
          %{
            "op" => "replace_text",
            "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
            "query" => "수정 전",
            "replacement" => "수정 완료"
          }
        ],
        "sets" => [],
        "highlights" => highlights
      }
    ]

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: "immutable-vfs-preview-turn",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         edit_id: edit_id,
         applied: 0,
         progress_index: 0,
         progress_total: 1,
         preview_only: true,
         preview_steps: preview_steps,
         highlights: highlights
       }}
    )

    sync_liveview(lv)

    live_state =
      canvas_state(lv, ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"]))

    assert String.starts_with?(live_state["bytesUrl"], "/document-bytes?")
    assert has_element?(lv, ~s([data-role="editor-preview"] [id$="-live-canvas"]))

    immutable_url = "blob:http://localhost/immutable-pre-edit-snapshot"

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: "immutable-vfs-preview-turn",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         edit_id: edit_id,
         applied: 1,
         progress_index: 1,
         progress_total: 1,
         preview_continuation: true,
         browser_authority: true,
         preview_base_url: immutable_url,
         preview_steps: preview_steps,
         highlights: highlights
       }}
    )

    sync_liveview(lv)

    committed_state =
      canvas_state(lv, ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"]))

    assert committed_state["bytesUrl"] =~ "/document-bytes?"
    assert committed_state["bytesUrl"] =~ "snapshot=#{final_sha256}"
    refute committed_state["bytesUrl"] == immutable_url
    assert Jason.decode!(committed_state["previewSteps"]) == []
    assert has_element?(lv, ~s([data-role="editor-preview"] [id$="-committed-canvas"]))
    refute has_element?(lv, ~s([data-role="editor-preview"] [id$="-live-canvas"]))
  end

  test "persisted VFS preview pins edit-time bytes across document switches and transcript replay",
       %{
         conn: conn
       } do
    root = WorkspaceAdapterStub.valid_path()
    relative_path = "template.hwpx"
    path = Path.join(root, relative_path)
    original_bytes = File.read!(path)
    edit_time_bytes = rezip_hwpx(original_bytes, "edit-time")
    later_bytes = rezip_hwpx(original_bytes, "later")

    refute edit_time_bytes == original_bytes
    refute later_bytes == edit_time_bytes
    assert {:ok, "hwpx"} = Document.detect_format(relative_path, edit_time_bytes)
    assert {:ok, "hwpx"} = Document.detect_format(relative_path, later_bytes)

    {:ok, lv, _html} =
      open_workspace(conn, root,
        document: relative_path,
        chat_rail_tab_id: "preview-origin"
      )

    session_id = subscribe_agent(lv)
    seed_known_vfs_turn(session_id, "pinned-vfs-preview-turn")
    document_id = Document.id_for(root, relative_path)

    on_exit(fn ->
      snapshot_path =
        PreviewSnapshot.path(document_id, Document.sha256(edit_time_bytes))

      File.rm_rf(Path.dirname(snapshot_path))
    end)

    assert {:ok, ^original_bytes} = Document.read(document_id)

    File.write!(path, edit_time_bytes)

    # The already-open Document.Session is deliberately stale. Snapshot capture
    # must read the committed path at the VFS boundary, never these old bytes.
    assert {:ok, ^original_bytes} = Document.read(document_id)

    highlights = [
      %{
        "kind" => "text",
        "op" => "replace_text",
        "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
        "length" => 8,
        "text" => "EDIT_TIME"
      }
    ]

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: "pinned-vfs-preview-turn",
         path: path,
         doc: relative_path,
         edit_id: "pinned-preview",
         applied: 1,
         highlights: highlights
       }}
    )

    sync_liveview(lv)

    selector = ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"])
    before = canvas_state(lv, selector)

    assert before["documentPath"] == relative_path
    assert before["localDocumentId"] == document_id
    assert Jason.decode!(before["previewHighlights"]) == highlights

    before_uri = URI.parse(before["bytesUrl"])
    before_query = URI.decode_query(before_uri.query)

    assert before_uri.path == "/document-bytes"
    assert before_query["path"] == root
    assert before_query["document"] == relative_path
    assert before_query["snapshot"] == Document.sha256(edit_time_bytes)
    assert fetch_document_bytes(before["bytesUrl"]) == edit_time_bytes

    assert [%Dialog{items: items}] = AcpAgent.agent_snapshot(session_id).transcript

    assert Enum.any?(items, fn item ->
             snapshot = Map.get(item, :preview_snapshot)

             Map.get(item, :role) == :edit_preview and is_map(snapshot) and
               Map.get(snapshot, :document_id) == document_id and
               Map.get(snapshot, :sha256) == Document.sha256(edit_time_bytes)
           end)

    File.write!(path, later_bytes)
    open_document(lv, "drafts/service.hwpx")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="hwp-editor"]), %{
      "documentPath" => "drafts/service.hwpx"
    })

    after_switch = canvas_state(lv, selector)

    pinned_keys = [
      "documentId",
      "localDocumentId",
      "documentPath",
      "bytesUrl",
      "previewHighlights",
      "previewSteps"
    ]

    assert Map.take(after_switch, pinned_keys) == Map.take(before, pinned_keys)
    assert File.read!(path) == later_bytes
    assert fetch_document_bytes(after_switch["bytesUrl"]) == edit_time_bytes

    stop_pid(lv.pid)
    sync_workspace_session(root)
    File.rm!(path)
    refute File.exists?(path)

    {:ok, replayed_lv, _html} =
      open_workspace(conn, root, chat_rail_tab_id: "preview-origin")

    render_async(replayed_lv, 2_000)
    sync_liveview(replayed_lv)
    assert subscribe_agent(replayed_lv) == session_id

    replayed = canvas_state(replayed_lv, selector)

    assert Map.take(replayed, pinned_keys) == Map.take(before, pinned_keys)
    assert fetch_document_bytes(replayed["bytesUrl"]) == edit_time_bytes
  end

  test "a delayed VFS preview stays with its completed turn while the queued turn is running",
       %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_delayed_preview_turn,
        script: [{:text_delta, "turn reply"}]
      ]
    )

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "delayed-preview-origin-turn", root)
    tab_id = "delayed-preview-origin-turn-tab"
    {:ok, lv, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "first edit"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, session_id: ^session_id, turn_id: turn1}},
                   1_000

    assert_receive {:agent_adapter_waiting, task1}, 1_000

    lv
    |> form("#agent-form", agent: %{message: "second edit"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_queued, session_id: ^session_id, turn_id: turn2}},
                   1_000

    send(task1, :release_delayed_preview_turn)

    assert_receive {:agent_event,
                    %{type: :turn_completed, session_id: ^session_id, turn_id: ^turn1}},
                   1_000

    assert_receive {:agent_adapter_waiting, task2}, 1_000
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn2}}, 1_000

    send_vfs_edit_and_wait(lv, %{
      path: Path.join(root, "template.hwpx"),
      doc: "template.hwpx",
      agent_id: session_id,
      instance_id: agent_instance_id(session_id),
      turn_id: turn1,
      edit_id: "delayed-first-turn-edit",
      applied: 1,
      progress_index: 1,
      progress_total: 1,
      highlights: [
        %{
          "kind" => "text",
          "op" => "replace_text",
          "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
          "length" => 7,
          "text" => "FIRST EDIT"
        }
      ]
    })

    assert [%Dialog{turn_id: ^turn1, items: first_items}] =
             AcpAgent.agent_snapshot(session_id).transcript

    assert [%{turn_id: ^turn1, edit_id: "delayed-first-turn-edit"}] =
             Enum.filter(first_items, &(&1.role == :edit_preview))

    send(task2, :release_delayed_preview_turn)

    assert_receive {:agent_event,
                    %{type: :turn_completed, session_id: ^session_id, turn_id: ^turn2}},
                   1_000

    assert [
             %Dialog{turn_id: ^turn1, items: replay_first_items},
             %Dialog{turn_id: ^turn2, items: replay_second_items}
           ] = AcpAgent.agent_snapshot(session_id).transcript

    assert Enum.any?(replay_first_items, &(&1.role == :edit_preview))
    refute Enum.any?(replay_second_items, &(&1.role == :edit_preview))

    stop_pid(lv.pid)
    sync_workspace_session(root)

    {:ok, replayed, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    sync_liveview(replayed)
    assert subscribe_agent(replayed) == session_id

    assert chat_stream_roles(replayed) == [
             "user",
             "agent",
             "editor_preview",
             "user",
             "agent"
           ]

    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "duplicate committed previews from simultaneous stable-tab LiveViews persist and replay once",
       %{
         conn: conn
       } do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "reply"}]])
    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "duplicate-preview-connections", root)
    tab_id = "duplicate-preview-tab"

    {:ok, live_a, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    session_id = subscribe_agent(live_a)

    live_a
    |> form("#agent-form", agent: %{message: "keep reconnect history"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      session_id: ^session_id,
                      turn_id: dialog_turn_id
                    }},
                   1_000

    sync_liveview(live_a)

    {:ok, live_b, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    assert subscribe_agent(live_b) == session_id
    sync_liveview(live_a)

    refute has_element?(live_a, "#agent-error")
    refute has_element?(live_b, "#agent-error")
    assert has_element?(live_a, ~s(#agent-sidebar[data-agent-status="idle"]))
    assert has_element?(live_b, ~s(#agent-sidebar[data-agent-status="idle"]))

    assert has_element?(
             live_b,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "keep reconnect history"
           )

    assert has_element?(
             live_a,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "keep reconnect history"
           )

    info = %{
      path: Path.join(root, "template.hwpx"),
      doc: "template.hwpx",
      agent_id: session_id,
      instance_id: agent_instance_id(session_id),
      turn_id: dialog_turn_id,
      edit_id: "duplicate-final-preview",
      applied: 1,
      progress_index: 1,
      progress_total: 1,
      highlights: [
        %{
          "kind" => "text",
          "op" => "replace_text",
          "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
          "length" => 9,
          "text" => "ONE FINAL"
        }
      ]
    }

    send_vfs_edit_and_wait(live_a, info)
    send_vfs_edit_and_wait(live_b, info)
    send_vfs_edit_and_wait(live_b, info)
    sync_liveview(live_a)
    sync_liveview(live_b)

    preview_items =
      session_id
      |> AcpAgent.agent_snapshot()
      |> Map.fetch!(:transcript)
      |> Enum.flat_map(&Map.get(&1, :items, []))
      |> Enum.filter(&(Map.get(&1, :role) == :edit_preview))

    assert [preview_item] = preview_items
    assert preview_item.edit_id == "duplicate-final-preview"

    assert preview_item.preview_identity == %{
             turn_id: dialog_turn_id,
             edit_id: "duplicate-final-preview",
             document_id: Document.id_for(root, "template.hwpx"),
             snapshot_id: preview_item.preview_snapshot.id
           }

    preview_count =
      live_b
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="editor-preview"]))
      |> LazyHTML.attribute("data-role")
      |> length()

    assert preview_count == 1

    live_a_preview_count =
      live_a
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="editor-preview"]))
      |> LazyHTML.attribute("data-role")
      |> length()

    assert live_a_preview_count == 1

    stop_pid(live_a.pid)
    sync_workspace_session(root)

    assert Process.alive?(live_b.pid)
    assert agent_session_id(live_b) == session_id
    refute has_element?(live_b, "#agent-error")
    assert has_element?(live_b, ~s(#agent-sidebar[data-agent-status="idle"]))

    assert has_element?(
             live_b,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "keep reconnect history"
           )

    stop_pid(live_b.pid)
    sync_workspace_session(root)

    {:ok, restored, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    sync_liveview(restored)

    assert subscribe_agent(restored) == session_id
    refute has_element?(restored, "#agent-error")
    assert has_element?(restored, ~s(#agent-sidebar[data-agent-status="idle"]))

    restored_preview_count =
      restored
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="editor-preview"]))
      |> LazyHTML.attribute("data-role")
      |> length()

    assert restored_preview_count == 1
  end

  test "simultaneous stable-tab LiveViews finalize one terminal turn once", %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "one completion"}]])
    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "single-terminal-finalizer", root)
    tab_id = "single-terminal-finalizer-tab"

    {:ok, live_a, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    session_id = subscribe_agent(live_a)
    {:ok, live_b, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    assert subscribe_agent(live_b) == session_id
    :ok = Ecrits.Workspace.Session.subscribe_file_events(root)

    live_a
    |> form("#agent-form", agent: %{message: "finalize exactly once"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      session_id: ^session_id,
                      instance_id: instance_id,
                      turn_id: turn_id
                    }},
                   2_000

    assert_receive {:workspace_turn_finalized,
                    %{
                      workspace_path: ^root,
                      agent_id: ^session_id,
                      instance_id: ^instance_id,
                      turn_id: ^turn_id,
                      result: %{
                        saved: [],
                        failed: [],
                        staged: %{committed: [], pending: []}
                      },
                      summary: %{successful?: true}
                    }},
                   2_000

    sync_liveview(live_a)
    sync_liveview(live_b)
    assert has_element?(live_a, ~s(#agent-sidebar[data-agent-status="idle"]))
    assert has_element?(live_b, ~s(#agent-sidebar[data-agent-status="idle"]))

    refute_receive {:workspace_turn_finalized, %{agent_id: ^session_id, turn_id: ^turn_id}},
                   100

    state = root |> Ecrits.Workspace.Session.whereis() |> :sys.get_state()

    assert %{
             {^session_id, ^instance_id, ^turn_id} => %{
               status: :completed,
               summary: %{successful?: true}
             }
           } = state.turn_finalizations

    refute Map.has_key?(state.turn_finalizations[{session_id, instance_id, turn_id}], :result)
  end

  @tag :edit_failure
  test "committed preview snapshot failure is explicit and never falls back to mutable bytes", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    tab_id = "unavailable-preview-tab"
    {:ok, lv, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    session_id = subscribe_agent(lv)
    seed_known_vfs_turn(session_id, "failed-vfs-preview-turn")

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: "failed-vfs-preview-turn",
         edit_id: "failed-preview-snapshot",
         applied: 1,
         progress_index: 1,
         progress_total: 1,
         preview_snapshot_error: "forced_snapshot_failure",
         highlights: []
       }}
    )

    sync_liveview(lv)

    assert has_element?(lv, ~s([data-role="editor-preview-unavailable"]))
    refute has_element?(lv, ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"]))

    assert [%Dialog{items: items}] = AcpAgent.agent_snapshot(session_id).transcript
    assert [preview] = Enum.filter(items, &(Map.get(&1, :role) == :edit_preview))
    assert preview.role == :edit_preview
    assert preview.preview_unavailable == true
    assert preview.preview_error == "forced_snapshot_failure"
    assert preview.preview_snapshot == nil

    stop_pid(lv.pid)
    sync_workspace_session(root)

    {:ok, replayed_lv, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    sync_liveview(replayed_lv)

    assert subscribe_agent(replayed_lv) == session_id
    assert has_element?(replayed_lv, ~s([data-role="editor-preview-unavailable"]))

    refute has_element?(
             replayed_lv,
             ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"])
           )
  end

  test "VFS preview selects a visible text range after a delete highlight", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root)
    session_id = subscribe_agent(lv)
    seed_known_vfs_turn(session_id, "delete-highlight-vfs-turn")

    ref = %{"section" => 0, "paragraph" => 2}

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: "delete-highlight-vfs-turn",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 2,
         marker: "VISIBLE_PREVIEW_RANGE",
         highlights: [
           %{
             "kind" => "text",
             "op" => "delete_range",
             "ref" => ref,
             "offset" => 4
           },
           %{
             "kind" => "text",
             "op" => "insert_text",
             "ref" => ref,
             "offset" => 4,
             "length" => 21,
             "text" => "VISIBLE_PREVIEW_RANGE"
           }
         ]
       }}
    )

    sync_liveview(lv)

    highlights =
      lv
      |> canvas_state(~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"]))
      |> Map.fetch!("previewHighlights")
      |> Jason.decode!()

    assert Enum.any?(highlights, &(&1["op"] == "insert_text" and &1["length"] == 21))
  end

  test "VFS preview prefers a ranged body edit over a stale cell ref", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root)
    session_id = subscribe_agent(lv)
    seed_known_vfs_turn(session_id, "stale-cell-vfs-turn")

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: "stale-cell-vfs-turn",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 2,
         marker: "VISIBLE_BODY_RANGE",
         highlights: [
           %{
             "kind" => "text",
             "op" => "set_cell",
             "ref" => %{
               "section" => 0,
               "paragraph" => 862,
               "cell" => %{
                 "parentParaIndex" => 862,
                 "controlIndex" => 0,
                 "cellIndex" => 2,
                 "cellParaIndex" => 0
               }
             },
             "offset" => 0,
             "length" => 148,
             "text" => "STALE_CELL_RANGE"
           },
           %{
             "kind" => "text",
             "op" => "insert_text",
             "ref" => %{"section" => 0, "paragraph" => 73},
             "offset" => 0,
             "length" => 18,
             "text" => "VISIBLE_BODY_RANGE"
           }
         ]
       }}
    )

    sync_liveview(lv)

    highlights =
      lv
      |> canvas_state(~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"]))
      |> Map.fetch!("previewHighlights")
      |> Jason.decode!()

    assert Enum.any?(highlights, &(&1["ref"]["paragraph"] == 73))
    assert Enum.any?(highlights, &(&1["ref"]["cell"]["parentParaIndex"] == 862))
  end

  test "VFS preview sends the exact saved text as a native highlight anchor", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root)
    session_id = subscribe_agent(lv)
    seed_known_vfs_turn(session_id, "exact-highlight-vfs-turn")

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: "exact-highlight-vfs-turn",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 1,
         highlights: [
           %{
             "kind" => "text",
             "op" => "insert_text",
             "ref" => %{"section" => 0, "paragraph" => 81},
             "offset" => 0,
             "length" => 30,
             "text" => "          3. 산출내역서 및 마일스톤 지급계획"
           }
         ]
       }}
    )

    sync_liveview(lv)

    highlights =
      lv
      |> canvas_state(~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"]))
      |> Map.fetch!("previewHighlights")
      |> Jason.decode!()

    assert [highlight] = highlights
    assert highlight["ref"]["paragraph"] == 81
    assert highlight["length"] == 30
    assert highlight["text"] == "          3. 산출내역서 및 마일스톤 지급계획"
  end

  test "VFS edit for a large active document keeps one embedded rail preview", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    session_id = subscribe_agent(lv)
    seed_known_vfs_turn(session_id, "large-vfs-preview-turn")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="hwp-editor"]), %{
      "localDocumentFormat" => "hwpx",
      "documentPath" => "template.hwpx"
    })

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: "large-vfs-preview-turn",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 2,
         marker: "SYNTHETIC_LARGE_ACTIVE_VFS",
         highlights: [
           %{
             "kind" => "text",
             "op" => "replace_text",
             "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
             "text" => "SYNTHETIC_LARGE_ACTIVE_VFS"
           }
         ]
       }}
    )

    sync_liveview(lv)

    assert_preview_state(lv, %{"documentPath" => "template.hwpx", "deltaCount" => 2})

    assert has_element?(
             lv,
             ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"])
           )

    refute has_element?(lv, ~s([data-role="editor-preview-image"]))

    refute has_element?(lv, ~s([data-role="doc-edit-card"]))

    assert [%{items: items}] = AcpAgent.agent_snapshot(session_id).transcript

    assert Enum.any?(items, fn item ->
             Map.get(item, :role) == :edit_preview and
               Map.get(item, :document_path) == "template.hwpx" and
               Map.get(item, :applied) == 2 and
               Map.get(item, :mode) == "descriptor"
           end)
  end

  test "repeated VFS edits replace the previous embedded rail preview", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    session_id = subscribe_agent(lv)
    seed_known_vfs_turn(session_id, "repeated-vfs-preview-turn")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="hwp-editor"]), %{
      "localDocumentFormat" => "hwpx",
      "documentPath" => "template.hwpx"
    })

    for marker <- ["SYNTHETIC_VFS_PREVIEW_ONE", "SYNTHETIC_VFS_PREVIEW_TWO"] do
      send(
        lv.pid,
        {:vfs_doc_edited,
         %{
           agent_id: session_id,
           instance_id: agent_instance_id(session_id),
           turn_id: "repeated-vfs-preview-turn",
           path: Path.join(root, "template.hwpx"),
           doc: "template.hwpx",
           applied: 1,
           marker: marker,
           highlights: [
             %{
               "kind" => "text",
               "op" => "replace_text",
               "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
               "text" => marker
             }
           ]
         }}
      )

      sync_liveview(lv)
    end

    html = render(lv)

    preview_count =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="editor-preview"]))
      |> LazyHTML.attribute("data-role")
      |> length()

    image_count =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="editor-preview-image"]))
      |> LazyHTML.attribute("data-role")
      |> length()

    assert preview_count == 1
    assert image_count == 0

    assert has_element?(
             lv,
             ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"])
           )

    refute has_element?(lv, ~s([data-role="doc-edit-card"]))
  end

  test "one VFS write streams semantic edit ranges through one stable preview", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    session_id = subscribe_agent(lv)
    edit_id = "streamed-vfs-edit"
    turn_id = "streamed-vfs-preview-turn"
    seed_known_vfs_turn(session_id, turn_id)

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: turn_id,
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         edit_id: edit_id,
         progress_index: 0,
         progress_total: 2,
         preview_only: true,
         applied: 0,
         delta_applied: 2,
         marker: "STREAMED_TOKEN_PENDING",
         highlights: [],
         ops: [%{"op" => "delete_range"}, %{"op" => "insert_text"}]
       }}
    )

    sync_liveview(lv)

    assert_preview_state(lv, %{
      "documentPath" => "template.hwpx",
      "deltaCount" => 2,
      "status" => "running"
    })

    assert has_element?(
             lv,
             ~s([data-role="editor-preview"] [data-role="editor-preview-delta-count"]),
             "2"
           )

    refute has_element?(
             lv,
             ~s([data-role="editor-preview"] [data-role="editor-preview-delta-count"]),
             "0"
           )

    refute Enum.any?(AcpAgent.agent_snapshot(session_id).transcript, fn turn ->
             Enum.any?(Map.get(turn, :items, []), &(Map.get(&1, :role) == :edit_preview))
           end)

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: turn_id,
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         edit_id: edit_id,
         progress_index: 1,
         progress_total: 2,
         applied: 2,
         marker: "STREAMED_TOKEN_ONE",
         highlights: [
           %{
             "kind" => "text",
             "op" => "insert_text",
             "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
             "length" => 18,
             "text" => "STREAMED_TOKEN_ONE"
           }
         ]
       }}
    )

    sync_liveview(lv)

    assert_preview_state(lv, %{
      "documentPath" => "template.hwpx",
      "deltaCount" => 1,
      "status" => "running"
    })

    assert has_element?(
             lv,
             ~s([data-role="editor-preview"][id^="agent-editor-preview-#{turn_id}-"])
           )

    refute Enum.any?(AcpAgent.agent_snapshot(session_id).transcript, fn turn ->
             Enum.any?(Map.get(turn, :items, []), &(Map.get(&1, :role) == :edit_preview))
           end)

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: agent_instance_id(session_id),
         turn_id: turn_id,
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         edit_id: edit_id,
         progress_index: 2,
         progress_total: 2,
         applied: 4,
         marker: "STREAMED_TOKEN_TWO",
         highlights: [
           %{
             "kind" => "text",
             "op" => "insert_text",
             "ref" => %{"section" => 0, "paragraph" => 1, "offset" => 0},
             "length" => 18,
             "text" => "STREAMED_TOKEN_TWO"
           }
         ]
       }}
    )

    sync_liveview(lv)

    assert_preview_state(lv, %{
      "documentPath" => "template.hwpx",
      "deltaCount" => 2,
      "status" => "sent"
    })

    assert has_element?(
             lv,
             ~s([data-role="editor-preview"] [data-role="editor-preview-delta-count"]),
             "2"
           )

    preview_ids =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="editor-preview"][id^="agent-editor-preview-#{turn_id}-"]))
      |> LazyHTML.attribute("id")

    assert length(preview_ids) == 1

    transcript_items =
      session_id
      |> AcpAgent.agent_snapshot()
      |> Map.fetch!(:transcript)
      |> Enum.flat_map(&Map.get(&1, :items, []))

    assert Enum.count(transcript_items, &(Map.get(&1, :role) == :edit_preview)) == 1
    assert Enum.find(transcript_items, &(Map.get(&1, :role) == :edit_preview)).applied == 2
  end

  test "VFS property writes are pushed to the open HWP browser editor", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()

    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="hwp-editor"]), %{
      "localDocumentFormat" => "hwpx",
      "documentPath" => "template.hwpx"
    })

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
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
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
      "document.engine.operation.command",
      %{verb: "set", payload: %{sets: [set_payload]}},
      1_000
    )

    assert set_payload["ref"] == ref
    assert set_payload["props"]["BackgroundColor"] == "#CFFAFE"
  end

  test "reselecting full workspace access reapplies VFS write policy", %{conn: conn} do
    previous_vfs = Application.get_env(:ecrits, :doc_vfs)
    root = WorkspaceAdapterStub.valid_path()

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
        {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")

        lv
        |> element("#agent-inline-access-full-workspace")
        |> render_click()

        sync_liveview(lv)
        assert Ecrits.Fuse.OpenDocs.writable?(root)

        Ecrits.Fuse.OpenDocs.set_writable(root, false)
        refute Ecrits.Fuse.OpenDocs.writable?(root)

        lv
        |> element("#agent-inline-access-full-workspace")
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

    {:ok, lv, _html} = open_workspace(conn, document: "template.hwpx")

    session_id = subscribe_agent(lv)
    session_pid = AcpAgent.whereis(session_id)
    assert is_pid(session_pid)

    # Build a conversation so there is something to lose.
    lv
    |> form("#agent-form", agent: %{message: "first question"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      session_id: ^session_id,
                      turn_id: completed_turn_id
                    }},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "first question"
           )

    send_vfs_edit_and_wait(lv, %{
      path: Path.join(WorkspaceAdapterStub.valid_path(), "template.hwpx"),
      doc: "template.hwpx",
      agent_id: session_id,
      instance_id: agent_instance_id(session_id),
      turn_id: completed_turn_id,
      edit_id: "document-switch-stable-preview",
      applied: 1,
      progress_index: 1,
      progress_total: 1,
      marker: "PREVIEW_MUST_STAY_ON_DOCUMENT_SWITCH",
      highlights: []
    })

    stable_preview = liveview_assign(lv, :agent_vfs_preview_item)
    assert %{edit_id: "document-switch-stable-preview"} = stable_preview
    assert has_element?(lv, ~s([data-role="editor-preview"]))

    # Expand the drafts directory so its documents become selectable.
    lv
    |> element("#toggle-dir-drafts")
    |> render_click()

    # Select a DIFFERENT document — the path that previously reset the chat.
    open_document(lv, "drafts/service.hwpx")

    sync_liveview(lv)

    # Same session_id, same backing PID, conversation intact.
    assert agent_session_id(lv) == session_id
    assert AcpAgent.whereis(session_id) == session_pid
    assert Process.alive?(session_pid)
    assert liveview_assign(lv, :agent_vfs_preview_item) == stable_preview
    assert has_element?(lv, ~s([data-role="editor-preview"]))
    refute has_element?(lv, "#agent-error")

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "first question"
           )

    # Select a SECOND, different document (back to the HWPX top-level one) —
    # still preserved.
    open_document(lv, "template.hwpx")

    sync_liveview(lv)

    assert agent_session_id(lv) == session_id
    assert AcpAgent.whereis(session_id) == session_pid
    assert Process.alive?(session_pid)
    assert liveview_assign(lv, :agent_vfs_preview_item) == stable_preview
    assert has_element?(lv, ~s([data-role="editor-preview"]))
    refute has_element?(lv, "#agent-error")

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "first question"
           )

    # The live session's per-turn document context must follow the active doc,
    # so the agent's doc.* tools still target what the user is viewing — the
    # `document_path` followed the switch back to template.hwpx.
    assert {:ok, %{document_path: path}} = AcpAgent.status(nil, session_id)
    assert is_binary(path) and String.ends_with?(path, "template.hwpx")
  end

  test "a new browser tab starts a fresh rail and keeps the old chat in recents",
       %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "ack reply"}]])
    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "refresh-session", root)

    {:ok, lv, _html} = open_workspace(conn, root)

    session_id = subscribe_agent(lv)
    agent_pid = AcpAgent.whereis(session_id)
    assert is_pid(agent_pid)

    # A turn that completes → builds the transcript AND derives the auto-title.
    lv
    |> form("#agent-form", agent: %{message: "한 단어로 확인만"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    # The durable agent retained the derived title + transcript.
    assert AcpAgent.title(session_id) == "한 단어로 확인만"
    snapshot = AcpAgent.agent_snapshot(session_id)
    assert [%{user: "한 단어로 확인만"} | _] = snapshot.transcript
    refute snapshot.title_user_edited?
    assert has_element?(lv, "#agent-title-label[value='한 단어로 확인만']")

    # A second browser tab has a distinct tab id, so it starts a fresh rail while
    # retaining the first tab's completed chat in recents.
    stop_pid(lv.pid)
    sync_workspace_session(root)

    {:ok, lv2, _html2} = open_workspace(conn, root)

    sync_liveview(lv2)

    # New active rail: a distinct tab must not inherit the first tab's selection.
    new_session_id = subscribe_agent(lv2)
    refute new_session_id == session_id
    assert AcpAgent.whereis(session_id) == agent_pid
    assert Process.alive?(agent_pid)

    assert has_element?(lv2, "#agent-title-label[value='New Chat']")

    refute has_element?(
             lv2,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "한 단어로 확인만"
           )

    assert has_element?(lv2, "#agent-rail-picker[data-count='2']")

    lv2
    |> element("#agent-rail-picker")
    |> render_click()

    assert chat_rail_agent_ids(lv2) == [new_session_id, session_id]
    assert has_element?(lv2, "#agent-rail-option-#{session_id}", "한 단어로 확인만")

    lv2
    |> element("#agent-rail-option-#{session_id}")
    |> render_click()

    sync_liveview(lv2)

    assert agent_session_id(lv2) == session_id
    assert has_element?(lv2, "#agent-title-label[value='한 단어로 확인만']")

    send(
      lv2.pid,
      {:agent_event,
       %{
         session_id: session_id,
         instance_id: AcpAgent.agent_snapshot(session_id).instance_id,
         type: :title_generated,
         title: "Provider refined title"
       }}
    )

    sync_liveview(lv2)

    assert has_element?(lv2, "#agent-title-label[value='Provider refined title']")

    assert has_element?(
             lv2,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "한 단어로 확인만"
           )

    lv2
    |> element("#agent-rail-picker")
    |> render_click()

    assert chat_rail_agent_ids(lv2) == [new_session_id, session_id]
    assert has_element?(lv2, "#agent-rail-option-#{session_id} .hero-check")
    refute has_element?(lv2, "#agent-rail-option-#{new_session_id} .hero-check")

    # Tear down the durable workspace Session + agent so the shared valid_path()
    # doesn't leak this agent into sibling tests.
    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "a browser refresh reattaches the selected rail without reordering recents",
       %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "persisted reply"}]])
    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "stable-refresh-session", root)
    tab_id = "stable-refresh-tab"

    {:ok, lv, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    old_session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "persist this rail"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^old_session_id}},
                   1_000

    sync_liveview(lv)

    lv
    |> element("#agent-refresh")
    |> render_click()

    sync_liveview(lv)
    new_session_id = subscribe_agent(lv)
    refute new_session_id == old_session_id

    lv
    |> element("#agent-rail-picker")
    |> render_click()

    assert chat_rail_agent_ids(lv) == [new_session_id, old_session_id]

    lv
    |> element("#agent-rail-option-#{old_session_id}")
    |> render_click()

    sync_liveview(lv)
    assert agent_session_id(lv) == old_session_id

    stop_pid(lv.pid)
    sync_workspace_session(root)

    {:ok, lv2, _html2} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    sync_liveview(lv2)

    assert subscribe_agent(lv2) == old_session_id
    assert has_element?(lv2, "#agent-title-label[value='persist this rail']")

    assert has_element?(
             lv2,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "persist this rail"
           )

    lv2
    |> element("#agent-rail-picker")
    |> render_click()

    assert chat_rail_agent_ids(lv2) == [new_session_id, old_session_id]
    assert has_element?(lv2, "#agent-rail-option-#{old_session_id} .hero-check")

    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "same-tab siblings keep different documents while sharing rail state and preview", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_same_tab_turn,
        script: [{:text_delta, "shared reply"}]
      ]
    )

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "same-tab-different-documents", root)
    tab_id = "same-tab-different-documents-id"

    {:ok, live_a, _html} =
      open_workspace(conn, root,
        document: "template.hwpx",
        chat_rail_tab_id: tab_id
      )

    old_session_id = subscribe_agent(live_a)
    seed_known_vfs_turn(old_session_id, "same-tab-pinned-preview-turn")
    template_path = Path.join(root, "template.hwpx")
    template_bytes = File.read!(template_path)
    template_document_id = Document.id_for(root, "template.hwpx")

    on_exit(fn ->
      template_document_id
      |> PreviewSnapshot.path(Document.sha256(template_bytes))
      |> Path.dirname()
      |> File.rm_rf()
    end)

    preview_info = %{
      path: template_path,
      doc: "template.hwpx",
      agent_id: old_session_id,
      instance_id: agent_instance_id(old_session_id),
      turn_id: "same-tab-pinned-preview-turn",
      edit_id: "same-tab-pinned-preview",
      applied: 1,
      highlights: [
        %{
          "kind" => "text",
          "op" => "replace_text",
          "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
          "length" => 6,
          "text" => "공유 수정"
        }
      ]
    }

    send_vfs_edit_and_wait(live_a, preview_info)
    sync_liveview(live_a)

    {:ok, live_b, _html} =
      open_workspace(conn, root,
        document: "drafts/service.hwpx",
        chat_rail_tab_id: tab_id
      )

    assert subscribe_agent(live_b) == old_session_id
    sync_liveview(live_a)
    sync_liveview(live_b)

    assert liveview_assign(live_a, :active_document_path) == "template.hwpx"
    assert liveview_assign(live_b, :active_document_path) == "drafts/service.hwpx"
    refute has_element?(live_a, "#agent-error")
    refute has_element?(live_b, "#agent-error")

    preview_selector =
      ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"])

    preview_a = canvas_state(live_a, preview_selector)
    preview_b = canvas_state(live_b, preview_selector)

    pinned_preview_keys = [
      "documentId",
      "localDocumentId",
      "documentPath",
      "bytesUrl",
      "previewHighlights",
      "previewSteps"
    ]

    assert Map.take(preview_b, pinned_preview_keys) ==
             Map.take(preview_a, pinned_preview_keys)

    assert preview_b["documentPath"] == "template.hwpx"
    assert preview_b["localDocumentId"] == template_document_id
    assert fetch_document_bytes(preview_b["bytesUrl"]) == template_bytes

    live_a
    |> form("#agent-form", agent: %{message: "running on the shared rail"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, session_id: ^old_session_id, turn_id: first_turn_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, first_stream_pid}, 1_000
    sync_liveview(live_a)
    sync_liveview(live_b)

    assert liveview_assign(live_a, :agent_status) == :running
    assert liveview_assign(live_b, :agent_status) == :running

    assert has_element?(
             live_b,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "running on the shared rail"
           )

    live_b
    |> form("#agent-form", agent: %{message: "queued on the shared rail"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_queued, session_id: ^old_session_id, turn_id: second_turn_id}},
                   1_000

    sync_liveview(live_a)
    sync_liveview(live_b)

    assert Enum.map(liveview_assign(live_a, :agent_queue), & &1.body) ==
             ["queued on the shared rail"]

    assert Enum.map(liveview_assign(live_b, :agent_queue), & &1.body) ==
             ["queued on the shared rail"]

    assert has_element?(live_a, "#agent-queued-panel", "queued on the shared rail")
    assert has_element?(live_b, "#agent-queued-panel", "queued on the shared rail")

    send(first_stream_pid, :release_same_tab_turn)

    assert_receive {:agent_event,
                    %{type: :turn_completed, session_id: ^old_session_id, turn_id: ^first_turn_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, second_stream_pid}, 1_000
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^second_turn_id}}, 1_000
    send(second_stream_pid, :release_same_tab_turn)

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      session_id: ^old_session_id,
                      turn_id: ^second_turn_id
                    }},
                   1_000

    sync_liveview(live_a)
    sync_liveview(live_b)

    assert liveview_assign(live_a, :agent_status) == :idle
    assert liveview_assign(live_b, :agent_status) == :idle
    assert liveview_assign(live_a, :agent_queue) == []
    assert liveview_assign(live_b, :agent_queue) == []

    live_a
    |> element("#agent-refresh")
    |> render_click()

    sync_liveview(live_a)
    sync_liveview(live_b)

    new_session_id = agent_session_id(live_a)
    refute new_session_id == old_session_id
    assert agent_session_id(live_b) == new_session_id
    assert subscribe_agent(live_b) == new_session_id
    assert liveview_assign(live_a, :active_document_path) == "template.hwpx"
    assert liveview_assign(live_b, :active_document_path) == "drafts/service.hwpx"
    refute has_element?(live_a, "#agent-error")
    refute has_element?(live_b, "#agent-error")

    live_b
    |> element("#agent-rail-picker")
    |> render_click()

    live_b
    |> element("#agent-rail-option-#{old_session_id}")
    |> render_click()

    sync_liveview(live_a)
    sync_liveview(live_b)

    assert agent_session_id(live_a) == old_session_id
    assert agent_session_id(live_b) == old_session_id
    assert liveview_assign(live_a, :active_document_path) == "template.hwpx"
    assert liveview_assign(live_b, :active_document_path) == "drafts/service.hwpx"
    refute has_element?(live_a, "#agent-error")
    refute has_element?(live_b, "#agent-error")

    restored_a = canvas_state(live_a, preview_selector)
    restored_b = canvas_state(live_b, preview_selector)

    assert Map.take(restored_a, pinned_preview_keys) ==
             Map.take(preview_a, pinned_preview_keys)

    assert Map.take(restored_b, pinned_preview_keys) ==
             Map.take(preview_a, pinned_preview_keys)

    for live <- [live_a, live_b] do
      assert has_element?(
               live,
               ~s([data-role="agent-message"][data-message-role="user"]),
               "running on the shared rail"
             )

      assert has_element?(
               live,
               ~s([data-role="agent-message"][data-message-role="user"]),
               "queued on the shared rail"
             )
    end

    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "same-tab provider restart snapshots every sibling when the agent id is reused", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_restarted_provider_turn,
        echo_opts: true
      ]
    )

    put_provider_integrations!(ready_provider_integrations())

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "same-tab-provider-restart", root)
    tab_id = "same-tab-provider-restart-id"

    {:ok, live_a, _html} =
      open_workspace(conn, root,
        document: "template.hwpx",
        chat_rail_tab_id: tab_id
      )

    session_id = subscribe_agent(live_a)
    old_agent_pid = AcpAgent.whereis(session_id)
    old_instance_id = AcpAgent.agent_snapshot(session_id).instance_id
    template_path = Path.join(root, "template.hwpx")
    template_bytes = File.read!(template_path)
    template_document_id = Document.id_for(root, "template.hwpx")

    on_exit(fn ->
      template_document_id
      |> PreviewSnapshot.path(Document.sha256(template_bytes))
      |> Path.dirname()
      |> File.rm_rf()
    end)

    live_a
    |> form("#agent-form", agent: %{message: "old provider preview"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, session_id: ^session_id, turn_id: preview_turn_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, preview_stream_pid}, 1_000
    send(preview_stream_pid, :release_restarted_provider_turn)

    assert_receive {:agent_event,
                    %{type: :turn_completed, session_id: ^session_id, turn_id: ^preview_turn_id}},
                   1_000

    sync_liveview(live_a)

    send_vfs_edit_and_wait(live_a, %{
      path: template_path,
      doc: "template.hwpx",
      agent_id: session_id,
      instance_id: agent_instance_id(session_id),
      turn_id: preview_turn_id,
      edit_id: "provider-restart-stale-preview",
      applied: 1,
      highlights: [
        %{
          "kind" => "text",
          "op" => "replace_text",
          "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
          "length" => 6,
          "text" => "이전 편집"
        }
      ]
    })

    {:ok, live_b, _html} =
      open_workspace(conn, root,
        document: "drafts/service.hwpx",
        chat_rail_tab_id: tab_id
      )

    assert subscribe_agent(live_b) == session_id
    sync_liveview(live_a)
    sync_liveview(live_b)

    live_a
    |> form("#agent-form", agent: %{message: "old provider running"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, session_id: ^session_id, turn_id: running_turn_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, _old_stream_pid}, 1_000

    live_b
    |> form("#agent-form", agent: %{message: "old provider queued"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_queued, session_id: ^session_id, turn_id: queued_turn_id}},
                   1_000

    sync_liveview(live_a)
    sync_liveview(live_b)

    for live <- [live_a, live_b] do
      assert liveview_assign(live, :agent_status) == :running
      assert liveview_assign(live, :agent_turn_id) == running_turn_id

      assert Enum.map(liveview_assign(live, :agent_queue), & &1.turn_id) ==
               [queued_turn_id]

      assert has_element?(live, ~s([data-role="editor-preview"]))
    end

    live_a
    |> element("#agent-go-to-provider")
    |> render_click()

    live_a
    |> element("#agent-model-detail-claude")
    |> render_click()

    sync_liveview(live_a)
    sync_liveview(live_b)

    assert agent_session_id(live_a) == session_id
    assert agent_session_id(live_b) == session_id
    refute AcpAgent.whereis(session_id) == old_agent_pid
    refute Process.alive?(old_agent_pid)

    # A running turn makes the provider restart asynchronous: the old process can
    # be dead before the Workspace Session resumes the fenced replacement and
    # sends the sibling rebinds. Cross both mailboxes before snapshotting the
    # reused stable id.
    sync_workspace_session(root)
    sync_liveview(live_a)
    sync_liveview(live_b)

    new_instance_id = AcpAgent.agent_snapshot(session_id).instance_id
    refute new_instance_id == old_instance_id

    for live <- [live_a, live_b] do
      assert liveview_assign(live, :agent_status) == :idle
      assert liveview_assign(live, :agent_turn_id) == nil
      assert liveview_assign(live, :agent_pending) == 0
      assert liveview_assign(live, :agent_queue) == []
      assert liveview_assign(live, :agent_vfs_preview_item) == nil
      refute has_element?(live, ~s([data-role="agent-message"]))
      refute has_element?(live, ~s([data-role="editor-preview"]))
      refute has_element?(live, "#agent-error")
    end

    assert liveview_assign(live_a, :active_document_path) == "template.hwpx"
    assert liveview_assign(live_b, :active_document_path) == "drafts/service.hwpx"

    assert %{provider: "claude", model: nil, adapter_opts: restarted_opts} =
             AcpAgent.agent_snapshot(session_id)

    # A delayed mailbox/PubSub event from the dead provider process still has
    # the durable agent id, but not the new process incarnation. It must not add
    # tools, rename the rail, or run terminal persistence on either sibling.
    stale_events = [
      %{
        type: :tool_call_started,
        session_id: session_id,
        instance_id: old_instance_id,
        turn_id: running_turn_id,
        tool_call_id: "stale-old-tool",
        name: "Bash",
        arguments: %{"command" => "false"}
      },
      %{
        type: :thread_title,
        session_id: session_id,
        instance_id: old_instance_id,
        title: "stale provider title"
      },
      %{
        type: :turn_completed,
        session_id: session_id,
        instance_id: old_instance_id,
        turn_id: running_turn_id,
        text: "stale completion"
      }
    ]

    for live <- [live_a, live_b], event <- stale_events do
      send(live.pid, {:agent_event, event})
    end

    for live <- [live_a, live_b] do
      send(
        live.pid,
        {:workspace_turn_finalized,
         %{
           workspace_path: root,
           agent_id: session_id,
           instance_id: old_instance_id,
           turn_id: running_turn_id,
           result: %{saved: ["template.hwpx"]}
         }}
      )
    end

    sync_liveview(live_a)
    sync_liveview(live_b)

    for live <- [live_a, live_b] do
      assert liveview_assign(live, :agent_instance_id) == new_instance_id
      assert liveview_assign(live, :agent_status) == :idle
      assert liveview_assign(live, :agent_turn_id) == nil
      refute has_element?(live, "#agent-tool-stale-old-tool")
      refute has_element?(live, "#agent-title-label[value='stale provider title']")
      refute has_element?(live, "#flash-info", "Saved 1 document")
      refute has_element?(live, "#agent-error")
    end

    assert AcpAgent.agent_snapshot(session_id).transcript == []

    stale_vfs =
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: old_instance_id,
         turn_id: running_turn_id,
         edit_id: "stale-old-vfs-edit",
         path: template_path,
         doc: "template.hwpx",
         applied: 1,
         preview_only: true,
         highlights: []
       }}

    for live <- [live_a, live_b] do
      send(live.pid, stale_vfs)
      sync_liveview(live)
      assert liveview_assign(live, :agent_vfs_preview_item) == nil
      refute has_element?(live, ~s([data-role="editor-preview"]))
    end

    assert AcpAgent.agent_snapshot(session_id).transcript == []

    # Claude's "default" display choice is represented canonically by omitting
    # the adapter model option; a stale Codex sibling would send `gpt-5.5` here.
    assert Keyword.get(restarted_opts, :model) == nil

    for live <- [live_a, live_b] do
      assert liveview_assign(live, :agent).provider.key == "claude"
      assert liveview_assign(live, :agent).model == "default"

      assert has_element?(
               live,
               "#agent-provider-options[data-selected-provider='claude'][data-selected-model='default']"
             )
    end

    live_b
    |> form("#agent-form", agent: %{message: "send through restarted provider"})
    |> render_submit()

    assert_receive {:agent_adapter_waiting, restarted_stream_pid}, 1_000
    send(restarted_stream_pid, :release_restarted_provider_turn)

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      session_id: ^session_id,
                      text: restarted_text
                    }},
                   1_000

    assert restarted_text =~ "send through restarted provider"
    refute restarted_text =~ "model="
    refute restarted_text =~ "model=gpt-5.5"

    assert %{provider: "claude", model: nil, adapter_opts: sent_opts} =
             AcpAgent.agent_snapshot(session_id)

    assert Keyword.get(sent_opts, :model) == nil

    sync_liveview(live_a)
    sync_liveview(live_b)

    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "simultaneous stable-tab LiveViews follow shared create and select rebinds", %{
    conn: conn
  } do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "shared reply"}]])
    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "shared-tab-rebind", root)
    tab_id = "shared-tab-rebind-id"

    {:ok, live_a, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    {:ok, live_b, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    old_session_id = subscribe_agent(live_a)
    assert agent_session_id(live_b) == old_session_id

    live_a
    |> form("#agent-form", agent: %{message: "seed shared old rail"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^old_session_id}},
                   1_000

    sync_liveview(live_a)
    sync_liveview(live_b)

    render_hook(live_b, "agent.rail.select", %{"rail-key" => "missing-shared-rail"})
    assert has_element?(live_b, "#agent-error")

    live_a
    |> element("#agent-refresh")
    |> render_click()

    sync_liveview(live_a)
    sync_liveview(live_b)

    new_session_id = agent_session_id(live_a)
    refute new_session_id == old_session_id
    assert agent_session_id(live_b) == new_session_id
    refute has_element?(live_b, "#agent-error")
    assert has_element?(live_a, ~s(#agent-sidebar[data-agent-status="idle"]))
    assert has_element?(live_b, ~s(#agent-sidebar[data-agent-status="idle"]))

    assert subscribe_agent(live_b) == new_session_id

    live_b
    |> form("#agent-form", agent: %{message: "B sends on created rail"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^new_session_id}},
                   1_000

    sync_liveview(live_a)
    sync_liveview(live_b)

    live_a
    |> element("#agent-rail-picker")
    |> render_click()

    live_a
    |> element("#agent-rail-option-#{old_session_id}")
    |> render_click()

    sync_liveview(live_a)
    sync_liveview(live_b)

    assert agent_session_id(live_a) == old_session_id
    assert agent_session_id(live_b) == old_session_id

    live_b
    |> form("#agent-form", agent: %{message: "B sends on selected rail"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^old_session_id}},
                   1_000

    sync_liveview(live_a)
    sync_liveview(live_b)

    assert has_element?(
             live_b,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "B sends on selected rail"
           )

    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "a sibling joining mid-turn keeps the shared rail alive after the sender closes", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_agent_ui,
        script: [{:text_delta, "shared turn done"}]
      ]
    )

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "shared-tab-mid-turn", root)
    tab_id = "shared-tab-mid-turn-id"
    {:ok, live_a, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    session_id = subscribe_agent(live_a)

    live_a
    |> form("#agent-form", agent: %{message: "A starts shared turn"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, session_id: ^session_id, turn_id: first_turn_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, first_stream_pid}, 1_000

    document_id = "shared-mid-turn-owned-document"
    assert :ok = Ecrits.Workspace.Session.claim_owner(root, document_id, session_id)

    {:ok, live_b, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    sync_liveview(live_a)
    sync_liveview(live_b)

    assert agent_session_id(live_b) == session_id
    assert liveview_assign(live_b, :agent_status) == :running
    assert liveview_assign(live_b, :agent_turn_id) == first_turn_id

    stop_pid(live_a.pid)
    sync_workspace_session(root)

    assert Process.alive?(live_b.pid)
    assert Ecrits.Workspace.Session.owner(root, document_id) == session_id

    send(first_stream_pid, :release_agent_ui)

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      session_id: ^session_id,
                      turn_id: ^first_turn_id
                    }},
                   1_000

    sync_liveview(live_b)
    assert liveview_assign(live_b, :agent_status) == :idle

    assert has_element?(
             live_b,
             ~s([data-role="agent-message"][data-message-role="agent"]),
             "shared turn done"
           )

    live_b
    |> form("#agent-form", agent: %{message: "B continues shared rail"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, session_id: ^session_id, turn_id: second_turn_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, second_stream_pid}, 1_000
    send(second_stream_pid, :release_agent_ui)

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      session_id: ^session_id,
                      turn_id: ^second_turn_id
                    }},
                   1_000

    sync_liveview(live_b)

    assert has_element?(
             live_b,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "B continues shared rail"
           )

    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "a sibling joining after deltas and a tool start converges on the same in-flight turn", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_snapshot_turn,
        script: [{:text_delta, " tail"}]
      ]
    )

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "shared-tab-current-snapshot", root)
    tab_id = "shared-tab-current-snapshot-id"
    {:ok, live_a, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    session_id = subscribe_agent(live_a)

    live_a
    |> form("#agent-form", agent: %{message: "inspect while I join"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{
                      type: :turn_started,
                      session_id: ^session_id,
                      turn_id: turn_id,
                      instance_id: instance_id
                    }},
                   1_000

    assert_receive {:agent_adapter_waiting, stream_pid}, 1_000
    agent_pid = AcpAgent.whereis(session_id)

    send(agent_pid, {:turn_event, turn_id, %{type: :reasoning_delta, delta: "plan first"}})
    send(agent_pid, {:turn_event, turn_id, %{type: :text_delta, delta: "before tool"}})

    send(agent_pid, {
      :turn_event,
      turn_id,
      %{
        type: :tool_call_started,
        tool_call_id: "snapshot-shell",
        name: "Bash",
        kind: "execute",
        arguments: %{"command" => "pwd"}
      }
    })

    send(agent_pid, {:turn_event, turn_id, %{type: :reasoning_delta, delta: "check result"}})

    send(
      agent_pid,
      {:turn_event, turn_id,
       %{
         type: :edit_delta,
         edit_id: "snapshot-edit",
         path: "template.hwpx",
         delta: "표 셀을 수정하는 중"
       }}
    )

    send(agent_pid, {:turn_event, turn_id, %{type: :text_delta, delta: "after start"}})

    _ = :sys.get_state(agent_pid)

    {:ok, live_b, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    sync_liveview(live_a)
    sync_liveview(live_b)

    assert agent_session_id(live_b) == session_id
    assert liveview_assign(live_b, :agent_instance_id) == instance_id
    assert liveview_assign(live_b, :agent_turn_id) == turn_id
    assert liveview_assign(live_b, :agent_status) == :running
    assert liveview_assign(live_b, :agent_text) == "after start"

    assert %{
             "snapshot-shell" => %{
               name: "Bash",
               args: %{"command" => "pwd"}
             }
           } = liveview_assign(live_b, :agent_active_tools)

    for live <- [live_a, live_b] do
      assert has_element?(live, ~s([data-message-role="user"]), "inspect while I join")
      assert has_element?(live, ~s([data-message-role="thinking"]), "plan first")
      assert has_element?(live, ~s([data-message-role="thinking"]), "check result")
      assert has_element?(live, ~s([data-message-role="agent"]), "after start")

      assert %{text: "표 셀을 수정하는 중", delta_count: 1} =
               liveview_assign(live, :agent_editor_preview)

      assert has_element?(live, ~s([data-role="editor-preview"]))

      assert has_element?(
               live,
               "#agent-tool-snapshot-shell[data-message-status='running']",
               "Bash"
             )
    end

    send(agent_pid, {
      :turn_event,
      turn_id,
      %{
        type: :tool_call_completed,
        tool_call_id: "snapshot-shell",
        name: "Bash",
        kind: "execute",
        result: %{"output" => "/tmp"}
      }
    })

    send(agent_pid, {:turn_event, turn_id, %{type: :text_delta, delta: " final"}})
    send(stream_pid, :release_snapshot_turn)

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      session_id: ^session_id,
                      turn_id: ^turn_id,
                      instance_id: ^instance_id
                    }},
                   1_000

    sync_liveview(live_a)
    sync_liveview(live_b)

    assert chat_stream_roles(live_a) == chat_stream_roles(live_b)

    assert chat_stream_roles(live_b) == [
             "user",
             "thinking",
             "agent",
             "tool",
             "thinking",
             "editor_preview",
             "agent",
             "agent"
           ]

    for live <- [live_a, live_b] do
      assert has_element?(
               live,
               "#agent-tool-snapshot-shell[data-message-status='completed']",
               "/tmp"
             )

      assert has_element?(live, ~s([data-message-role="agent"]), "after start")
      assert has_element?(live, ~s([data-message-role="agent"]), "final tail")
    end

    assert [%Dialog{turn_id: ^turn_id}] = AcpAgent.agent_snapshot(session_id).transcript
    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "a sibling joining while a delta precedes its snapshot applies that delta once", %{
    conn: conn
  } do
    use_test_agent_adapter!(adapter_opts: [test_pid: self(), wait_for: :release_cursor_race_turn])

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "shared-tab-snapshot-cursor-race", root)
    tab_id = "shared-tab-snapshot-cursor-race-id"
    {:ok, live_a, _html} = open_workspace(conn, root, chat_rail_tab_id: tab_id)
    session_id = subscribe_agent(live_a)

    live_a
    |> form("#agent-form", agent: %{message: "join during this edit"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{
                      type: :turn_started,
                      session_id: ^session_id,
                      turn_id: turn_id,
                      instance_id: instance_id
                    }},
                   1_000

    assert_receive {:agent_adapter_waiting, stream_pid}, 1_000
    agent_pid = AcpAgent.whereis(session_id)
    topic = AcpAgent.topic(session_id)

    subscriber_count = length(Registry.lookup(Ecrits.PubSub, topic))

    send(
      agent_pid,
      {:turn_event, turn_id,
       %{
         type: :edit_delta,
         edit_id: "cursor-race-edit",
         path: "template.hwpx",
         delta: "한 번만 보이는 편집"
       }}
    )

    _ = :sys.get_state(agent_pid)
    covered_snapshot = AcpAgent.agent_snapshot(session_id)
    covered_seq = covered_snapshot.event_seq
    parent = self()

    duplicate_event = %{
      type: :edit_delta,
      session_id: session_id,
      instance_id: instance_id,
      event_seq: covered_seq,
      turn_id: turn_id,
      edit_id: "cursor-race-edit",
      path: "template.hwpx",
      delta: "한 번만 보이는 편집"
    }

    debug_fun = fn
      false, {:in, {:"$gen_call", _from, :agent_snapshot}}, _name ->
        count = length(Registry.lookup(Ecrits.PubSub, topic))
        Phoenix.PubSub.broadcast(Ecrits.PubSub, topic, {:agent_event, duplicate_event})
        send(parent, {:cursor_race_duplicate_delivered, count})
        true

      delivered?, _event, _name ->
        delivered?
    end

    :ok = :sys.install(agent_pid, {:cursor_race_delivery, debug_fun, false})

    on_exit(fn ->
      if Process.alive?(agent_pid), do: :sys.remove(agent_pid, :cursor_race_delivery)
      stop_workspace_session(root)
    end)

    conn = put_workspace_handoff(conn, root)
    {:ok, live_b, _html} = live(conn, ~p"/workspace")
    render_hook(live_b, "workspace.chat_rail.tab_ready", %{"id" => tab_id})
    assert_receive {:cursor_race_duplicate_delivered, joined_count}, 2_000
    assert joined_count >= subscriber_count + 1
    :ok = :sys.remove(agent_pid, :cursor_race_delivery)
    sync_liveview(live_a)
    sync_liveview(live_b)

    assert agent_session_id(live_b) == session_id
    assert liveview_assign(live_b, :agent_instance_id) == instance_id

    for live <- [live_a, live_b] do
      assert %{
               turn_id: ^turn_id,
               text: "한 번만 보이는 편집",
               delta_count: 1,
               edit_id: "cursor-race-edit"
             } = liveview_assign(live, :agent_editor_preview)

      assert has_element?(live, ~s([data-role="editor-preview"]))
    end

    snapshot = AcpAgent.agent_snapshot(session_id)
    assert liveview_assign(live_b, :agent_event_seq) == snapshot.event_seq
    assert snapshot.current_turn.edit_preview.delta_count == 1

    send(stream_pid, :release_cursor_race_turn)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 1_000
  end

  test "same workspace path has isolated chat rails across browser tabs", %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "isolated reply"}]])

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "same-browser-tabs", root)

    {:ok, lv_a, _html} = open_workspace(conn, root)
    {:ok, lv_b, _html} = open_workspace(conn, root)

    session_id_a = subscribe_agent(lv_a)
    session_id_b = subscribe_agent(lv_b)

    refute session_id_a == session_id_b
    refute AcpAgent.whereis(session_id_a) == AcpAgent.whereis(session_id_b)

    lv_a
    |> form("#agent-form", agent: %{message: "only rail a"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id_a}},
                   1_000

    sync_liveview(lv_a)
    sync_liveview(lv_b)

    assert has_element?(
             lv_a,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "only rail a"
           )

    refute has_element?(
             lv_b,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "only rail a"
           )

    assert [%{user: "only rail a"} | _] = AcpAgent.agent_snapshot(session_id_a).transcript
    assert AcpAgent.agent_snapshot(session_id_b).transcript == []
  end

  test "waits for the colocated browser-tab hook before attaching a chat rail", %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "ready"}]])

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "tab-ready-hook", root)
    {:ok, lv, _html} = live(conn, ~p"/workspace")

    assert has_element?(
             lv,
             "#workspace-root[phx-hook='EcritsWeb.Workspace.WorkspaceLive.ChatRailTabIdentity']"
           )

    assert has_element?(lv, "#agent-sidebar[data-session-id='']")

    render_hook(lv, "workspace.chat_rail.tab_ready", %{"id" => "hook-owned-tab"})
    sync_liveview(lv)

    assert is_binary(subscribe_agent(lv))

    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "VFS edit previews route only to the owning chat rail", %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "owner reply"}]])

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "vfs-preview-owner", root)

    {:ok, lv_a, _html} = open_workspace(conn, root)
    {:ok, lv_b, _html} = open_workspace(conn, root)

    session_id_a = subscribe_agent(lv_a)
    session_id_b = subscribe_agent(lv_b)
    instance_id_a = agent_instance_id(session_id_a)

    lv_a
    |> form("#agent-form", agent: %{message: "known owner turn"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_completed, session_id: ^session_id_a, turn_id: owned_turn_id}},
                   1_000

    sync_liveview(lv_a)

    event =
      {:vfs_doc_edited,
       %{
         agent_id: session_id_a,
         instance_id: instance_id_a,
         turn_id: owned_turn_id,
         edit_id: "owned-vfs-edit",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 1,
         marker: "SYNTHETIC_OWNER_PREVIEW",
         highlights: [
           %{
             "kind" => "text",
             "op" => "replace_text",
             "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
             "text" => "SYNTHETIC_OWNER_PREVIEW"
           }
         ]
       }}

    send(lv_a.pid, event)
    send(lv_b.pid, event)

    sync_liveview(lv_a)
    sync_liveview(lv_b)

    assert_preview_state(lv_a, %{"documentPath" => "template.hwpx", "deltaCount" => 1})

    refute encoded_state?(
             lv_b,
             ~s([data-role="editor-preview"]),
             "data-preview-state",
             %{"documentPath" => "template.hwpx"}
           )

    assert [%{items: items_a}] = AcpAgent.agent_snapshot(session_id_a).transcript
    assert Enum.any?(items_a, &(Map.get(&1, :role) == :edit_preview))
    assert AcpAgent.agent_snapshot(session_id_b).transcript == []

    owned_preview = liveview_assign(lv_a, :agent_vfs_preview_item)
    owned_transcript = AcpAgent.agent_snapshot(session_id_a).transcript

    ownerless =
      {:vfs_doc_edited,
       %{
         turn_id: "ownerless-turn",
         edit_id: "ownerless-edit",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 1,
         marker: "OWNERLESS_MUST_NOT_ROUTE",
         highlights: []
       }}

    wrong_owner =
      {:vfs_doc_edited,
       %{
         agent_id: "some-other-agent",
         turn_id: "wrong-owner-turn",
         edit_id: "wrong-owner-edit",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 1,
         marker: "WRONG_OWNER_MUST_NOT_ROUTE",
         highlights: []
       }}

    session_id_only_spoof =
      {:vfs_doc_edited,
       %{
         session_id: session_id_a,
         instance_id: instance_id_a,
         turn_id: "session-id-spoof-turn",
         edit_id: "session-id-spoof-edit",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 1,
         marker: "SESSION_ID_MUST_NOT_ROUTE",
         highlights: []
       }}

    stale_instance =
      {:vfs_doc_edited,
       %{
         agent_id: session_id_a,
         instance_id: "stale-instance",
         turn_id: "stale-instance-turn",
         edit_id: "stale-instance-edit",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 1,
         marker: "STALE_INSTANCE_MUST_NOT_ROUTE",
         highlights: []
       }}

    unknown_turn =
      {:vfs_doc_edited,
       %{
         agent_id: session_id_a,
         instance_id: instance_id_a,
         turn_id: "unknown-turn",
         edit_id: "unknown-turn-edit",
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 1,
         marker: "UNKNOWN_TURN_MUST_NOT_ROUTE",
         highlights: []
       }}

    for blocked <- [
          ownerless,
          wrong_owner,
          session_id_only_spoof,
          stale_instance,
          unknown_turn
        ] do
      send(lv_a.pid, blocked)
      sync_liveview(lv_a)

      assert liveview_assign(lv_a, :agent_vfs_preview_item) == owned_preview
      assert AcpAgent.agent_snapshot(session_id_a).transcript == owned_transcript
    end

    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "a rejected atomic VFS edit restores the prior stable chat-rail preview", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        wait_for: :release_rejected_preview_turn,
        test_pid: self(),
        script: [{:text_delta, "unreachable"}]
      ]
    )

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "vfs-preview-rejected", root)
    {:ok, lv, _html} = open_workspace(conn, root)
    session_id = subscribe_agent(lv)
    instance_id = agent_instance_id(session_id)
    stable_edit_id = "stable-vfs-edit"
    edit_id = "rejected-vfs-edit"

    lv
    |> form("#agent-form", agent: %{message: "기존 미리보기를 만들어 줘"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, session_id: ^session_id, turn_id: stable_turn_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, stable_stream_pid}, 1_000
    send(stable_stream_pid, :release_rejected_preview_turn)

    assert_receive {:agent_event,
                    %{type: :turn_completed, session_id: ^session_id, turn_id: ^stable_turn_id}},
                   1_000

    sync_liveview(lv)

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: instance_id,
         turn_id: stable_turn_id,
         edit_id: stable_edit_id,
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 1,
         progress_index: 1,
         progress_total: 1,
         marker: "STABLE_PREVIEW",
         highlights: []
       }}
    )

    sync_liveview(lv)
    stable_preview = liveview_assign(lv, :agent_vfs_preview_item)
    assert %{edit_id: ^stable_edit_id} = stable_preview

    assert liveview_assign(lv, :agent_vfs_preview_rollback_item) == nil

    lv
    |> form("#agent-form", agent: %{message: "계약서를 수정해 줘"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, session_id: ^session_id, turn_id: rejected_turn_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, stream_pid}, 1_000

    send(
      lv.pid,
      {:vfs_doc_edited,
       %{
         agent_id: session_id,
         instance_id: instance_id,
         turn_id: rejected_turn_id,
         edit_id: edit_id,
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         applied: 1,
         progress_index: 1,
         progress_total: 2,
         marker: "MUST_BE_RETRACTED",
         highlights: []
       }}
    )

    sync_liveview(lv)
    assert has_element?(lv, ~s([data-role="editor-preview"]))
    assert %{edit_id: ^edit_id} = liveview_assign(lv, :agent_vfs_preview_item)
    assert liveview_assign(lv, :agent_vfs_preview_rollback_item) == stable_preview

    lv
    |> element("#toggle-dir-drafts")
    |> render_click()

    open_document(lv, "drafts/service.hwpx")
    sync_liveview(lv)

    assert %{edit_id: ^edit_id} = liveview_assign(lv, :agent_vfs_preview_item)
    assert liveview_assign(lv, :agent_vfs_preview_rollback_item) == stable_preview
    refute has_element?(lv, "#agent-error")

    send(
      lv.pid,
      {:vfs_doc_edit_rejected,
       %{
         agent_id: session_id,
         instance_id: instance_id,
         turn_id: "stale-other-turn",
         edit_id: edit_id,
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         reason: "late rejection from another turn"
       }}
    )

    sync_liveview(lv)
    assert %{edit_id: ^edit_id} = liveview_assign(lv, :agent_vfs_preview_item)
    assert liveview_assign(lv, :agent_vfs_preview_rollback_item) == stable_preview

    send(
      lv.pid,
      {:vfs_doc_edit_rejected,
       %{
         agent_id: session_id,
         instance_id: instance_id,
         turn_id: rejected_turn_id,
         edit_id: edit_id,
         path: Path.join(root, "template.hwpx"),
         doc: "template.hwpx",
         reason: "invalid structural write"
       }}
    )

    sync_liveview(lv)
    assert has_element?(lv, ~s([data-role="editor-preview"]))
    refute has_element?(lv, "#agent-error")
    assert liveview_assign(lv, :agent_vfs_preview_item) == stable_preview
    assert liveview_assign(lv, :agent_vfs_preview_rollback_item) == nil

    send(stream_pid, :release_rejected_preview_turn)

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      session_id: ^session_id,
                      turn_id: ^rejected_turn_id
                    }},
                   1_000

    sync_liveview(lv)
    refute has_element?(lv, "#agent-error")
    refute has_element?(lv, ~s([data-message-role="assistant"]), "Agent failed.")
    assert has_element?(lv, ~s(#agent-sidebar[data-agent-status="idle"]))
    assert liveview_assign(lv, :agent_vfs_preview_item) == stable_preview

    persisted_edit_ids =
      session_id
      |> AcpAgent.agent_snapshot()
      |> Map.fetch!(:transcript)
      |> Enum.flat_map(&Map.get(&1, :items, []))
      |> Enum.filter(&(Map.get(&1, :role) == :edit_preview))
      |> Enum.map(&Map.get(&1, :edit_id))

    assert persisted_edit_ids == [stable_edit_id]

    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "an ownerless VFS edit resyncs the open editor without entering the chat rail", %{
    conn: conn
  } do
    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "ownerless-editor-resync", root)
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    session_id = subscribe_agent(lv)

    send_vfs_edit_and_wait(lv, %{
      path: Path.join(root, "template.hwpx"),
      doc: "template.hwpx",
      edit_id: "ownerless-resync-edit",
      applied: 1,
      ops: [%{"op" => "replace_text", "text" => "resync"}],
      highlights: []
    })

    assert_push_event(lv, "document.engine.operation.command", %{
      verb: "edit",
      payload: %{resync: true}
    })

    refute has_element?(lv, ~s([data-role="editor-preview"]))
    assert liveview_assign(lv, :agent_vfs_preview_item) == nil
    assert AcpAgent.agent_snapshot(session_id).transcript == []

    on_exit(fn -> stop_workspace_session(root) end)
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
    assert has_element?(lv, "#agent-rail-picker[data-count='1']")

    lv
    |> element("#agent-refresh")
    |> render_click()

    sync_liveview(lv)

    assert agent_session_id(lv) == session_id

    new_pid = AcpAgent.whereis(session_id)
    assert is_pid(new_pid)
    refute new_pid == old_pid
    refute Process.alive?(old_pid)

    assert AcpAgent.agent_snapshot(session_id).transcript == []
    assert has_element?(lv, "#agent-title-label[value='New Chat']")
    assert has_element?(lv, "#agent-rail-picker[data-count='1']")
    refute has_element?(lv, "#agent-rail-picker[data-count='2']")

    on_exit(fn -> stop_workspace_session(WorkspaceAdapterStub.valid_path()) end)
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

    on_exit(fn -> stop_workspace_session(WorkspaceAdapterStub.valid_path()) end)

    session_id = subscribe_agent(lv)

    assert has_element?(lv, "#agent-picks[data-role='composer-picks']:not([phx-update])")

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

    # Browser hit-testing reports each pick to LiveView first. The native form
    # submit then sends only the message; the server-owned picker schema is the
    # sole source of prompt picks.
    Enum.each(picks, &render_hook(lv, "document.element_picker.pick.toggle", &1))

    lv
    |> form("#agent-form", agent: %{message: "여기 고쳐줘"})
    |> render_submit()

    # The agent-visible prompt keeps the exact legacy block format (typed text
    # followed by the "Selected document elements" JSON block).
    assert_receive {:fake_acp_prompt, _sid, prompt}, 1_000
    assert prompt =~ "여기 고쳐줘"
    assert prompt =~ "Selected document elements (3):"
    assert prompt =~ ~s("ref": "hwp:body/sec/0/tbl/0/cell/0")

    # Picks are structured target context only. The prompt does not add an
    # alternate document handle or a tool-specific discovery/edit recipe.
    refute prompt =~ "document_id"
    assert prompt =~ "Use this as target context; do not infer a different target from it."
    refute prompt =~ "Skip doc.context/doc.find discovery"
    refute prompt =~ "When using doc.* tools"
    refute prompt =~ "When using mounted"

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}},
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
    render_hook(lv, "document.element_picker.pick.toggle", hd(picks))

    lv
    |> form("#agent-form", agent: %{message: ""})
    |> render_submit()

    assert_receive {:fake_acp_prompt, _sid, prompt2}, 1_000
    assert prompt2 =~ "Selected document elements (1):"

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    # Refresh starts a fresh active rail; selecting the prior recent chat repaints
    # chips from the durable transcript, not the raw JSON.
    stop_pid(lv.pid)
    sync_workspace_session(WorkspaceAdapterStub.valid_path())

    {:ok, lv2, _html2} = open_workspace(conn)

    sync_liveview(lv2)
    new_session_id = subscribe_agent(lv2)
    refute new_session_id == session_id

    lv2
    |> element("#agent-rail-picker")
    |> render_click()

    lv2
    |> element("#agent-rail-option-#{session_id}")
    |> render_click()

    sync_liveview(lv2)

    assert agent_session_id(lv2) == session_id
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
    |> form("#agent-form", agent: %{message: "use one tool"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
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
    sync_workspace_session(WorkspaceAdapterStub.valid_path())

    {:ok, lv2, _html2} = open_workspace(conn)

    sync_liveview(lv2)
    new_session_id = subscribe_agent(lv2)
    refute new_session_id == session_id

    lv2
    |> element("#agent-rail-picker")
    |> render_click()

    lv2
    |> element("#agent-rail-option-#{session_id}")
    |> render_click()

    sync_liveview(lv2)

    assert has_element?(
             lv2,
             ~s([data-role="agent-tool"][data-message-role="tool"][data-message-status="completed"]),
             "doc.edit"
           )

    details = "#agent-tool-legacy-doc-edit-details[data-role='operation-details']"

    assert has_element?(lv2, details, ~s("ok": true))
    refute has_element?(lv2, details, "revision")
    refute has_element?(lv2, details, "base_version")
    refute has_element?(lv2, details, ~s("version"))
  end

  # Regression: an agent that runs its tools FIRST and only then streams the
  # reply must render the tool rows ABOVE the reply text — the display order is
  # the chronological order, matching the durable transcript.
  test "tool calls that precede the reply text render above it", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          %{
            type: :tool_call_started,
            id: "tool-ls",
            name: "shell",
            arguments: %{"cmd" => "ls"}
          },
          %{type: :tool_call_completed, id: "tool-ls", name: "shell", result: %{"ok" => true}},
          %{
            type: :tool_call_started,
            id: "tool-unzip",
            name: "shell",
            arguments: %{"cmd" => "unzip"}
          },
          %{type: :tool_call_completed, id: "tool-unzip", name: "shell", result: %{"ok" => true}},
          {:text_delta, "Yes. Me read the slides."}
        ]
      ]
    )

    conn = init_workspace_session(conn, "tool-order")

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "can you read this pptx?"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    assert chat_stream_rows(lv) == [
             {"user", "agent-user"},
             {"tool", "agent-tool-tool-ls"},
             {"tool", "agent-tool-tool-unzip"},
             {"agent", "agent-assistant"}
           ]
  end

  # Same, for a provider that streams NO text chunks: the whole reply arrives
  # once via the prompt result, after every tool event.
  test "prompt-result-only reply text renders below preceding tool calls", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        echo_opts: true,
        script: [
          %{
            type: :tool_call_started,
            id: "tool-grep",
            name: "shell",
            arguments: %{"cmd" => "grep"}
          },
          %{type: :tool_call_completed, id: "tool-grep", name: "shell", result: %{"ok" => true}}
        ]
      ]
    )

    conn = init_workspace_session(conn, "tool-order-prompt-result")

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "read it"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    assert chat_stream_rows(lv) == [
             {"user", "agent-user"},
             {"tool", "agent-tool-tool-grep"},
             {"agent", "agent-assistant"}
           ]
  end

  # Same, in the shape the vendored Claude ACP adapter actually emits: the
  # first report of a tool call is a `tool_call_update` with a non-terminal
  # status (no prior `tool_call`), and the terminal update carries no toolName.
  # Regression for the pptx-read turn that rendered its reply ABOVE the three
  # tool rows, each labeled with the generic "Tool" fallback.
  test "claude-shaped tool_call_update starts render above the trailing reply", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          %{
            type: :tool_call_in_progress,
            id: "tool-ls",
            name: "Bash",
            arguments: %{"command" => "ls ~/Downloads"}
          },
          %{type: :tool_call_completed, id: "tool-ls", result: %{"ok" => true}},
          %{
            type: :tool_call_in_progress,
            id: "tool-unzip",
            name: "Bash",
            arguments: %{"command" => "unzip -l deck.pptx"}
          },
          %{type: :tool_call_completed, id: "tool-unzip", result: %{"ok" => true}},
          {:text_delta, "Yes. Me read the slides."}
        ]
      ]
    )

    conn = init_workspace_session(conn, "tool-order-claude-shape")

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "can you read this pptx?"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    assert chat_stream_rows(lv) == [
             {"user", "agent-user"},
             {"tool", "agent-tool-tool-ls"},
             {"tool", "agent-tool-tool-unzip"},
             {"agent", "agent-assistant"}
           ]

    # The rows carry the real tool name, not the "Tool" fallback.
    assert has_element?(lv, "#agent-tool-tool-ls", "Bash")
    assert has_element?(lv, "#agent-tool-tool-unzip", "Bash")

    # The durable transcript stores the same order and names for repaint.
    assert [%{items: items}] = AcpAgent.agent_snapshot(session_id).transcript

    assert [
             %{role: :user},
             %{role: :tool, name: "Bash", status: :completed},
             %{role: :tool, name: "Bash", status: :completed},
             %{role: :agent}
           ] = items
  end

  test "thinking and shell rows keep their icons, disclosures, and persisted order", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          %{type: :reasoning_delta, delta: "Plan command"},
          %{
            type: :tool_call_started,
            id: "shell-order",
            name: "Bash",
            kind: "execute",
            arguments: %{"command" => "pwd"}
          },
          %{
            type: :tool_call_completed,
            id: "shell-order",
            name: "Bash",
            kind: "execute",
            result: %{"output" => "/tmp"}
          },
          %{type: :reasoning_delta, delta: "Read output"},
          {:text_delta, "Finished"}
        ]
      ]
    )

    conn = init_workspace_session(conn, "operation-order-persist")
    tab_id = "operation-order-persist-tab"
    {:ok, lv, _html} = open_workspace(conn, chat_rail_tab_id: tab_id)
    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "inspect files"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    expected_roles = ["user", "thinking", "tool", "thinking", "agent"]
    assert chat_stream_roles(lv) == expected_roles

    assert has_element?(
             lv,
             ~s(#agent-tool-shell-order [data-role="operation-block"][data-operation-kind="shell"])
           )

    assert has_element?(lv, "#agent-tool-shell-order-toggle", "Shell:")
    assert has_element?(lv, "#agent-tool-shell-order-toggle .hero-command-line")

    assert has_element?(
             lv,
             ~s([data-message-role="thinking"] details[data-operation-kind="thinking"] .hero-light-bulb)
           )

    for id <- [
          "#agent-tool-shell-order-disclosure",
          ~s([data-message-role="thinking"] details[data-operation-kind="thinking"])
        ] do
      assert has_element?(lv, id)
      assert has_element?(lv, "#{id} > summary[aria-controls]")
      assert has_element?(lv, "#{id} [data-role='operation-details']")
    end

    assert [%Dialog{items: items}] = AcpAgent.agent_snapshot(session_id).transcript
    assert Enum.map(items, &Map.fetch!(&1, :role)) == [:user, :thinking, :tool, :thinking, :agent]

    stop_pid(lv.pid)
    sync_workspace_session(WorkspaceAdapterStub.valid_path())

    {:ok, lv2, _html2} = open_workspace(conn, chat_rail_tab_id: tab_id)
    sync_liveview(lv2)
    assert subscribe_agent(lv2) == session_id

    assert chat_stream_roles(lv2) == expected_roles
    assert has_element?(lv2, "#agent-tool-shell-order-toggle", "Shell:")
  end

  # The visible chat rows (user/tool/agent) in DOM order, as {role, id-prefix}
  # pairs — empty thinking/placeholder rows are excluded.
  defp chat_stream_rows(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#agent-thread > [data-chat-role="chat-message"]))
    |> Enum.map(fn node ->
      role = node |> LazyHTML.attribute("data-message-role") |> List.first()
      id = node |> LazyHTML.attribute("id") |> List.first() |> to_string()
      {role, id}
    end)
    |> Enum.filter(fn {role, _id} -> role in ["user", "tool", "agent"] end)
    |> Enum.map(fn {role, id} ->
      {role,
       id
       |> String.replace(~r/-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}.*$/, "")}
    end)
  end

  defp chat_stream_roles(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#agent-thread > [data-chat-role="chat-message"]))
    |> Enum.map(fn node ->
      node
      |> LazyHTML.attribute("data-message-role")
      |> List.first()
    end)
  end

  defp chat_rail_agent_ids(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="chat-rail-option"]))
    |> Enum.map(fn node ->
      node
      |> LazyHTML.attribute("data-agent-id")
      |> List.first()
    end)
  end

  test "agent rail shows provider logo in model selector for codex route display", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    assert has_element?(
             lv,
             "#agent-sidebar[data-component='chat-rail'][data-chat-rail='true'][data-provider-key='codex']"
           )

    assert has_element?(
             lv,
             ~s(#agent-model-select[data-role="agent-model-select"] [data-role="agent-model-provider-favicon"][src="/images/icons/openai-blossom.svg"])
           )

    refute has_element?(lv, "#agent-title [data-role='chat-title-favicon']")

    assert has_element?(
             lv,
             "#agent-title-form[phx-change='agent.title.change'][data-role='chat-thread-title-form'] input#agent-title-label[data-role='chat-thread-title-label'][name='agent_title[title]'][type='text'][value='New Chat'][aria-label='Chat title']"
           )

    refute render(lv) =~ "ecrits-ui chat"
    refute has_element?(lv, "#agent-title-label[disabled]")
    refute has_element?(lv, "#agent-title-label[readonly]")
    refute has_element?(lv, "#agent-title-label[tabindex='-1']")

    assert has_element?(
             lv,
             "#agent-sidebar [data-role='chat-rail-controls'] #agent-refresh"
           )

    refute has_element?(lv, "#file-tree-refresh")
    refute has_element?(lv, "#agent-provider")
    refute has_element?(lv, "#agent-provider-icon")
  end

  test "agent rail title is manually editable through the title form", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    lv
    |> form("#agent-title-form", agent_title: %{title: "Pricing review"})
    |> render_change()

    assert has_element?(
             lv,
             "#agent-title-label[value='Pricing review']"
           )

    session_id = agent_session_id(lv)

    send(
      lv.pid,
      {:agent_event,
       %{
         session_id: session_id,
         instance_id: AcpAgent.agent_snapshot(session_id).instance_id,
         type: :title_generated,
         title: "Agent title"
       }}
    )

    sync_liveview(lv)

    assert AcpAgent.title(session_id) == "Pricing review"
    assert AcpAgent.agent_snapshot(session_id).title_user_edited?

    assert has_element?(
             lv,
             "#agent-title-label[value='Pricing review']"
           )
  end

  test "agent generated title replaces the untouched default title", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    session_id = agent_session_id(lv)

    send(
      lv.pid,
      {:agent_event,
       %{
         session_id: session_id,
         instance_id: AcpAgent.agent_snapshot(session_id).instance_id,
         type: :title_generated,
         title: "Employment review"
       }}
    )

    sync_liveview(lv)

    assert AcpAgent.title(session_id) == "Employment review"
    refute AcpAgent.agent_snapshot(session_id).title_user_edited?

    assert has_element?(
             lv,
             "#agent-title-label[value='Employment review']"
           )

    assert has_element?(
             lv,
             "#agent-rail-option-#{session_id}",
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
    |> form("#agent-form", agent: %{message: "reset this chat"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^old_session_id}},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "reset this chat"
           )

    assert [%{user: "reset this chat"} | _] = AcpAgent.agent_snapshot(old_session_id).transcript

    lv
    |> element("#agent-refresh")
    |> render_click()

    sync_liveview(lv)

    # The old rail is preserved; the button creates a distinct fresh rail.
    new_session_id = agent_session_id(lv)
    refute new_session_id == old_session_id
    track_agent_session(new_session_id)

    new_pid = AcpAgent.whereis(new_session_id)
    assert is_pid(new_pid)
    refute new_pid == old_pid
    assert AcpAgent.whereis(old_session_id) == old_pid

    assert AcpAgent.agent_snapshot(new_session_id).transcript == []
    assert has_element?(lv, "#agent-title-label[value='New Chat']")
    assert has_element?(lv, "#agent-sidebar[data-agent-status='idle']")
    assert has_element?(lv, "#agent-rail-picker[data-count='2']")

    refute has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "reset this chat"
           )

    lv
    |> element("#agent-rail-picker")
    |> render_click()

    assert has_element?(lv, "#agent-rail-picker[data-state='open']")

    assert has_element?(
             lv,
             "#agent-rail-drawer[data-role='chat-rail-dropdown'][data-state='open']"
           )

    assert has_element?(
             lv,
             "#agent-title > #agent-rail-drawer[class*='left-0'][class*='right-0']"
           )

    assert has_element?(
             lv,
             "#agent-rail-drawer[class*='transition-opacity'][class*='duration-75']"
           )

    refute has_element?(lv, "#agent-rail-drawer[class*='w-72']")
    refute has_element?(lv, "#agent-rail-drawer[class*='translate-y']")
    refute has_element?(lv, "#agent-rail-drawer[class*='scale']")

    assert has_element?(lv, "#agent-rail-drawer", "Recent chats")
    assert has_element?(lv, "#agent-rail-option-#{old_session_id}", "reset this chat")
    assert has_element?(lv, "#agent-rail-option-#{new_session_id}", "New Chat")

    lv
    |> element("#agent-rail-picker")
    |> render_click()

    assert has_element?(lv, "#agent-rail-picker[data-state='closed']")
    assert has_element?(lv, "#agent-rail-drawer[data-state='closed']")
    assert has_element?(lv, "#agent-rail-drawer[class*='opacity-0']")

    lv
    |> element("#agent-rail-picker")
    |> render_click()

    lv
    |> element("#agent-rail-option-#{old_session_id}")
    |> render_click()

    sync_liveview(lv)

    assert agent_session_id(lv) == old_session_id
    assert has_element?(lv, "#agent-title-label[value='reset this chat']")

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "reset this chat"
           )
  end

  test "pending new-chat double click and queue flush do not show the generic error banner", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_pending_new_chat,
        script: [{:text_delta, "late reply"}]
      ]
    )

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "pending-new-chat-no-error", root)
    {:ok, lv, _html} = open_workspace(conn, root)
    old_session_id = subscribe_agent(lv)
    old_instance_id = agent_instance_id(old_session_id)
    :ok = Ecrits.Workspace.Session.subscribe_file_events(root)

    lv
    |> form("#agent-form", agent: %{message: "active before new chat"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, turn_id: turn_id, session_id: ^old_session_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 1_000

    lv
    |> form("#agent-form", agent: %{message: "held in old queue"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_queued, session_id: ^old_session_id}},
                   1_000

    sync_liveview(lv)
    assert has_element?(lv, "#agent-queued-flush")
    refute has_element?(lv, "#agent-error")

    pool_pid = Process.whereis(Ecrits.Doc.Pool)
    :ok = :sys.suspend(pool_pid)

    try do
      lv |> element("#agent-refresh") |> render_click()
      sync_liveview(lv)
      refute has_element?(lv, "#agent-error")

      lv |> element("#agent-refresh") |> render_click()
      sync_liveview(lv)
      refute has_element?(lv, "#agent-error")

      lv |> element("#agent-queued-flush") |> render_click()
      sync_liveview(lv)
      refute has_element?(lv, "#agent-error")

      session_pid = Ecrits.Workspace.Session.whereis(root)
      assert map_size(:sys.get_state(session_pid).foreground_transitions) == 1
    after
      :ok = :sys.resume(pool_pid)
    end

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: ^old_session_id,
                      instance_id: ^old_instance_id,
                      turn_id: ^turn_id,
                      summary: %{successful?: true}
                    }},
                   2_000

    new_session_id = await_agent_session_change(lv, old_session_id)
    refute has_element?(lv, "#agent-error")
    refute new_session_id == old_session_id
    track_agent_session(new_session_id)
  end

  test "restart-fence rejection preserves the composer message and selected element chips", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_composer_restart,
        script: [{:text_delta, "late reply"}]
      ]
    )

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "restart-fence-composer", root)
    {:ok, lv, _html} = open_workspace(conn, root, document: "drafts/service.hwpx")
    old_session_id = subscribe_agent(lv)
    old_instance_id = agent_instance_id(old_session_id)
    :ok = Ecrits.Workspace.Session.subscribe_file_events(root)

    lv
    |> form("#agent-form", agent: %{message: "active before restart"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, turn_id: turn_id, session_id: ^old_session_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 1_000

    pool_pid = Process.whereis(Ecrits.Doc.Pool)
    :ok = :sys.suspend(pool_pid)

    pick = %{
      "document" => "drafts/service.hwpx",
      "type" => "cell",
      "ref" => "hwp:body/sec/0/tbl/0/cell/0",
      "text" => "계약 금액"
    }

    try do
      lv |> element("#agent-refresh") |> render_click()

      session_pid = Ecrits.Workspace.Session.whereis(root)
      assert map_size(:sys.get_state(session_pid).foreground_transitions) == 1

      render_hook(lv, "document.element_picker.pick.toggle", pick)
      assert has_element?(lv, ~s([data-role="composer-pick-chip"]), "계약 금액")

      lv
      |> form("#agent-form", agent: %{message: "retry after restart"})
      |> render_submit()

      sync_liveview(lv)

      assert [%{ref: "hwp:body/sec/0/tbl/0/cell/0", text: "계약 금액"}] =
               liveview_assign(lv, :document_element_picker).picks

      assert has_element?(lv, ~s([data-role="composer-pick-chip"]), "계약 금액")
      assert has_element?(lv, "#agent-input", "retry after restart")
      refute has_element?(lv, "#agent-error")
    after
      :ok = :sys.resume(pool_pid)
    end

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: ^old_session_id,
                      instance_id: ^old_instance_id,
                      turn_id: ^turn_id
                    }},
                   2_000

    sync_workspace_session(root)
    sync_liveview(lv)
    new_session_id = agent_session_id(lv)
    refute new_session_id == old_session_id
    track_agent_session(new_session_id)
  end

  test "agent new-chat button subscribes the live view to the fresh rail stream", %{
    conn: conn
  } do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "ack reply"}]])
    conn = init_workspace_session(conn, "rail-stream")

    {:ok, lv, _html} = open_workspace(conn)

    old_session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "seed old rail"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^old_session_id}},
                   1_000

    sync_liveview(lv)

    lv
    |> element("#agent-refresh")
    |> render_click()

    sync_liveview(lv)

    new_session_id = agent_session_id(lv)
    refute new_session_id == old_session_id
    track_agent_session(new_session_id)
    :ok = AcpAgent.subscribe(new_session_id)

    lv
    |> form("#agent-form", agent: %{message: "fresh rail prompt"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^new_session_id}},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "fresh rail prompt"
           )

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="agent"]),
             "ack reply"
           )
  end

  test "selecting the current recent rail repeatedly does not duplicate streamed deltas", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_agent_ui,
        script: [{:text_delta, "one copy"}]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)
    session_id = subscribe_agent(lv)

    for _ <- 1..2 do
      lv
      |> element("#agent-rail-picker")
      |> render_click()

      lv
      |> element("#agent-rail-option-#{session_id}")
      |> render_click()
    end

    lv
    |> form("#agent-form", agent: %{message: "stream once"})
    |> render_submit()

    assert_receive {:agent_adapter_waiting, stream_pid}, 1_000
    send(stream_pid, :release_agent_ui)

    assert_push_event(lv, "agent.stream.text_appended", %{piece: "one copy"})
    refute_push_event(lv, "agent.stream.text_appended", %{piece: "one copy"}, 200)

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="agent"]),
             "one copy"
           )
  end

  test "agent selector supports codex route favicon without provider badge", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    assert has_element?(lv, "#agent-sidebar[data-provider-key='codex']")

    assert has_element?(
             lv,
             ~s(#agent-model-select[data-role="agent-model-select"] [data-role="agent-model-provider-favicon"][src="/images/icons/openai-blossom.svg"])
           )

    refute has_element?(lv, "#agent-title [data-role='chat-title-favicon']")
    refute has_element?(lv, "#agent-provider")
    refute has_element?(lv, "#agent-provider-icon")
  end

  test "unsupported provider URL state is ignored", %{conn: conn} do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: WorkspaceAdapterStub.valid_path(), provider: "bogus"]}"
      )

    assert has_element?(lv, "#agent-provider-options[data-selected-provider='codex']")
  end

  test "agent status is internal and has no icon or provider badge structure", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    fragment =
      lv
      |> render()
      |> LazyHTML.from_fragment()

    assert has_element?(lv, "#agent-status[data-role='agent-status']", "Idle")

    assert ["sr-only"] =
             fragment
             |> LazyHTML.query("#agent-status")
             |> LazyHTML.attribute("class")

    assert [] =
             fragment
             |> LazyHTML.query("#agent-status img")
             |> LazyHTML.attribute("src")

    assert [] =
             fragment
             |> LazyHTML.query("#agent-status [class*='hero-']")
             |> LazyHTML.attribute("class")

    assert [] =
             fragment
             |> LazyHTML.query("#agent-status [data-provider-icon]")
             |> LazyHTML.attribute("data-provider-icon")
  end

  test "agent body uses chat rail stream and composer structure", %{conn: conn} do
    {:ok, lv, _html} = open_workspace(conn)

    assert has_element?(lv, "#agent-thread[data-role='chat-stream'][phx-update='stream']")
    assert has_element?(lv, "#agent-thread[class*='overflow-x-hidden']")

    refute has_element?(lv, "#agent-system")

    assert has_element?(lv, "#agent-form[data-role='chat-form']")
    assert has_element?(lv, "#agent-input")
    assert has_element?(lv, "#agent-upload[data-role='chat-upload']")

    assert has_element?(
             lv,
             ~s(#agent-provider-options input[type="file"][name="document_import"][class="sr-only"][data-role="document-import-file-input"])
           )

    assert has_element?(
             lv,
             "#agent-submit[type='submit'][data-role='chat-send'][data-action='send']"
           )

    refute has_element?(lv, "#document-direct-upload-input")
    refute has_element?(lv, ~s([phx-hook="DirectR2Upload"]))
  end

  test "ACP file operations render as persistent file activity, never tool cards", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          %{
            type: :file_operation_started,
            id: "acp-file-read",
            operation: "read_text_file",
            kind: "read",
            path: "/workspace/.ecrits/document.jsonl"
          },
          %{
            type: :file_operation_completed,
            id: "acp-file-read",
            operation: "read_text_file",
            kind: "read",
            path: "/workspace/.ecrits/document.jsonl"
          },
          %{
            type: :file_operation_started,
            id: "acp-file-search",
            operation: "search_text_file",
            kind: "read",
            path: "/workspace/.ecrits/document.jsonl",
            query: "수급사업자"
          },
          %{
            type: :file_operation_failed,
            id: "acp-file-search",
            operation: "search_text_file",
            kind: "read",
            path: "/workspace/.ecrits/document.jsonl",
            query: "수급사업자",
            reason: "no matches"
          },
          %{
            type: :file_operation_started,
            id: "acp-file-edit",
            operation: "edit_text_file",
            kind: "edit",
            path: "/workspace/.ecrits/document.jsonl"
          },
          %{
            type: :file_operation_completed,
            id: "acp-file-edit",
            operation: "edit_text_file",
            kind: "edit",
            path: "/workspace/.ecrits/document.jsonl"
          },
          %{
            type: :tool_call_completed,
            id: "doc-open",
            name: "doc.open_doc",
            result: %{"ok" => true}
          },
          {:text_delta, "done"}
        ]
      ]
    )

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "file-activity-persistence", root)
    tab_id = "file-activity-persistence-tab"

    {:ok, lv, _html} =
      open_workspace(conn, root, document: "template.hwpx", chat_rail_tab_id: tab_id)

    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "open and edit it"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    for {id, label, status} <- [
          {"acp-file-read", "Read", "completed"},
          {"acp-file-search", "Search", "failed"},
          {"acp-file-edit", "Edit", "completed"}
        ] do
      refute has_element?(lv, "#agent-tool-#{id}")

      row =
        "#agent-file-#{id}[data-role='file-activity'][data-message-role='file_activity'][data-message-status='#{status}']"

      assert has_element?(lv, row, label)
      assert has_element?(lv, row, "/workspace/.ecrits/document.jsonl")
      refute has_element?(lv, row, "Tool:")
    end

    assert has_element?(lv, "#agent-file-acp-file-search", "수급사업자")
    assert has_element?(lv, "#agent-file-acp-file-search", "no matches")
    assert has_element?(lv, "#agent-tool-doc-open", "doc.open_doc")

    assert [%{items: items}] = AcpAgent.agent_snapshot(session_id).transcript

    assert Enum.count(items, &(Map.get(&1, :role) == :file_activity)) == 3

    assert Enum.all?(Enum.filter(items, &(Map.get(&1, :role) == :file_activity)), fn item ->
             Map.get(item, :operation) in [
               "read_text_file",
               "search_text_file",
               "edit_text_file"
             ]
           end)

    assert Enum.any?(items, &(Map.get(&1, :name) == "doc.open_doc"))

    open_document(lv, "drafts/service.hwpx")

    for id <- ["acp-file-read", "acp-file-search", "acp-file-edit"] do
      assert has_element?(lv, "#agent-file-#{id}[data-role='file-activity']")
      refute has_element?(lv, "#agent-tool-#{id}")
    end

    agent_pid = AcpAgent.whereis(session_id)

    :sys.replace_state(agent_pid, fn state ->
      update_in(state.transcript, fn [turn | rest] ->
        legacy_item = %{
          role: :tool,
          tool_call_id: "legacy-hydrated-read",
          name: "read_text_file",
          status: :completed,
          input: Jason.encode!(%{"path" => "legacy/contract.jsonl"})
        }

        [Map.update!(turn, :items, &(&1 ++ [legacy_item])) | rest]
      end)
    end)

    stop_pid(lv.pid)
    sync_workspace_session(root)

    {:ok, lv2, _html2} =
      open_workspace(conn, root,
        document: "drafts/service.hwpx",
        chat_rail_tab_id: tab_id
      )

    sync_liveview(lv2)
    assert subscribe_agent(lv2) == session_id

    for id <- ["acp-file-read", "acp-file-search", "acp-file-edit"] do
      assert has_element?(lv2, "#agent-file-#{id}[data-role='file-activity']")
      refute has_element?(lv2, "#agent-tool-#{id}")
      refute has_element?(lv2, "#agent-file-#{id}", "Tool:")
    end

    assert has_element?(lv2, "#agent-file-acp-file-search", "no matches")

    assert has_element?(
             lv2,
             "#agent-file-legacy-hydrated-read[data-role='file-activity'][data-message-role='file_activity']",
             "Read"
           )

    assert has_element?(lv2, "#agent-file-legacy-hydrated-read", "legacy/contract.jsonl")
    refute has_element?(lv2, "#agent-tool-legacy-hydrated-read")

    on_exit(fn -> stop_workspace_session(root) end)
  end

  test "a dangling ACP file activity stays failed after the chat rail reconnects", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          %{
            type: :tool_call_started,
            id: "dangling-acp-read",
            name: "read_text_file",
            arguments: %{"path" => "mounted/contract.hwpx.jsonl"}
          }
        ]
      ]
    )

    root = WorkspaceAdapterStub.valid_path()
    conn = init_workspace_session(conn, "dangling-file-activity-persistence", root)
    tab_id = "dangling-file-activity-persistence-tab"

    {:ok, lv, _html} =
      open_workspace(conn, root, document: "template.hwpx", chat_rail_tab_id: tab_id)

    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "read the mounted projection"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    failed_row =
      "#agent-file-dangling-acp-read[data-role='file-activity'][data-message-status='failed']"

    assert has_element?(lv, failed_row, "Turn ended before the file operation finished.")
    refute has_element?(lv, "#agent-tool-dangling-acp-read")

    assert [%{items: items}] = AcpAgent.agent_snapshot(session_id).transcript

    assert %{
             status: :failed,
             reason: "Turn ended before the file operation finished.",
             body: "Turn ended before the file operation finished."
           } = Enum.find(items, &(Map.get(&1, :file_operation_id) == "dangling-acp-read"))

    stop_pid(lv.pid)
    sync_workspace_session(root)

    {:ok, lv2, _html2} =
      open_workspace(conn, root, document: "template.hwpx", chat_rail_tab_id: tab_id)

    sync_liveview(lv2)
    assert subscribe_agent(lv2) == session_id
    assert has_element?(lv2, failed_row, "Turn ended before the file operation finished.")
    refute has_element?(lv2, "#agent-tool-dangling-acp-read")

    on_exit(fn -> stop_workspace_session(root) end)
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
    |> form("#agent-form", agent: %{message: "read"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{
                      type: :tool_call_completed,
                      session_id: ^session_id,
                      tool_call_id: "tool-ui-json-read"
                    }},
                   1_000

    assert_receive {:agent_event,
                    %{
                      type: :tool_call_failed,
                      session_id: ^session_id,
                      tool_call_id: "tool-ui-read"
                    }},
                   1_000

    assert_receive {:agent_event,
                    %{
                      type: :tool_call_completed,
                      session_id: ^session_id,
                      tool_call_id: "tool-ui-find"
                    }},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             "#agent-tool-tool-ui-read[data-role='agent-tool'][data-message-status='failed']",
             "doc.read"
           )

    assert has_element?(
             lv,
             "#agent-tool-tool-ui-read[data-chat-role='chat-message'] [data-role='operation-block']"
           )

    assert has_element?(lv, ~s([data-message-role="user"][class*="mt-2"]))

    assert has_element?(
             lv,
             "#agent-tool-tool-ui-json-read-details[data-role='operation-details']",
             ~s("items")
           )

    assert has_element?(
             lv,
             "#agent-tool-tool-ui-find[data-role='agent-tool']",
             "doc.find"
           )

    assert has_element?(
             lv,
             "#agent-tool-tool-ui-json-read-details[data-role='operation-details']",
             ~s("items")
           )

    refute has_element?(
             lv,
             "#agent-tool-tool-ui-json-read-details[data-role='operation-details']",
             "%{"
           )

    refute has_element?(
             lv,
             "#agent-tool-tool-ui-json-read-details[data-role='operation-details']",
             "=>"
           )

    assert has_element?(
             lv,
             "[data-role='agent-thinking'] [data-role='operation-block']",
             "Thinking:"
           )

    assert has_element?(
             lv,
             "#agent-tool-tool-ui-read-details[data-role='operation-details']",
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
              "document" => "document.hwpx",
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
              "document" => "document.hwpx"
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
    |> form("#agent-form", agent: %{message: "make requested edits"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{
                      type: :tool_call_completed,
                      session_id: ^session_id,
                      tool_call_id: "tool-edit-no-version"
                    }},
                   1_000

    assert_receive {:agent_event,
                    %{
                      type: :tool_call_completed,
                      session_id: ^session_id,
                      tool_call_id: "tool-save-no-version"
                    }},
                   1_000

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    for {tool_call_id, tool_name} <- [
          {"tool-edit-no-version", "doc.edit"},
          {"tool-save-no-version", "doc.save"}
        ] do
      row = "#agent-tool-#{tool_call_id}"
      details = "#{row}-details[data-role='operation-details']"

      assert has_element?(lv, "#{row}[data-role='agent-tool']", tool_name)
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
    |> form("#agent-form", agent: %{message: "stream"})
    |> render_submit()

    assert_push_event(
      lv,
      "agent.stream.reasoning_appended",
      %{message_id: reasoning_message_id, piece: "checking"},
      1_000
    )

    assert String.starts_with?(reasoning_message_id, "agent-thinking-")

    assert_push_event(
      lv,
      "agent.stream.text_appended",
      %{message_id: first_message_id, piece: "hello"},
      1_000
    )

    assert String.starts_with?(first_message_id, "agent-assistant-")

    assert_push_event(
      lv,
      "agent.stream.text_appended",
      %{message_id: ^first_message_id, piece: " world"},
      1_000
    )

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="agent"][data-message-status="sent"]),
             "hello world"
           )

    assert has_element?(
             lv,
             ~s([id^="agent-assistant-"][data-chat-role="chat-message"][class*="w-full"] [data-role="agent-text"][class*="text-left"])
           )

    refute has_element?(
             lv,
             ~s([id^="agent-assistant-"][data-chat-role="chat-message"][class*="w-full"] [data-role="agent-text"][class*="text-justify"])
           )
  end

  test "agent sidebar renders a thinking row before the turn finishes", %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [wait_for: :release_agent_ui, test_pid: self()])

    {:ok, lv, _html} = open_workspace(conn)
    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "stream reasoning"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, session_id: ^session_id, turn_id: turn_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, stream_pid}, 1_000

    agent_pid = AcpAgent.whereis(session_id)
    assert is_pid(agent_pid)

    send(agent_pid, {
      :turn_event,
      turn_id,
      %{type: :reasoning_delta, delta: "Inspect workspace"}
    })

    assert_receive {:agent_event,
                    %{type: :reasoning_delta, session_id: ^session_id, turn_id: ^turn_id}},
                   1_000

    sync_liveview(lv)
    ref = liveview_assign(lv, :agent_reasoning_flush_ref)

    if is_reference(ref) do
      send(lv.pid, {:flush_agent_reasoning, ref})
    end

    sync_liveview(lv)

    thinking_row = ~s([data-message-role="thinking"][data-message-status="running"])

    assert has_element?(lv, thinking_row, "Inspect workspace")

    assert has_element?(
             lv,
             "#{thinking_row} #agent-thinking-#{turn_id}-0-toggle",
             "Thinking:"
           )

    assert has_element?(lv, "#{thinking_row} .hero-light-bulb")

    assert has_element?(
             lv,
             "#{thinking_row} [data-role='operation-details']",
             "Inspect workspace"
           )

    send(stream_pid, :release_agent_ui)
    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
  end

  test "legacy ACP file envelopes become visible file activity instead of tool cards", %{
    conn: conn
  } do
    use_test_agent_adapter!(adapter_opts: [wait_for: :release_agent_ui, test_pid: self()])

    {:ok, lv, _html} = open_workspace(conn)
    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "stream reasoning around a file read"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{type: :turn_started, session_id: ^session_id, turn_id: turn_id}},
                   1_000

    assert_receive {:agent_adapter_waiting, stream_pid}, 1_000
    instance_id = AcpAgent.agent_snapshot(session_id).instance_id

    base = %{session_id: session_id, instance_id: instance_id, turn_id: turn_id}

    send(
      lv.pid,
      {:agent_event, Map.merge(base, %{type: :reasoning_delta, delta: "Inspect "})}
    )

    sync_liveview(lv)
    assert liveview_assign(lv, :agent_reasoning_open?)

    send(
      lv.pid,
      {:agent_event,
       Map.merge(base, %{
         type: :tool_call_started,
         tool_call_id: "legacy-file-read",
         name: "read_text_file",
         arguments: %{"path" => "contract.jsonl"}
       })}
    )

    sync_liveview(lv)
    refute liveview_assign(lv, :agent_reasoning_open?)
    refute has_element?(lv, "#agent-tool-legacy-file-read")

    assert has_element?(
             lv,
             "#agent-file-legacy-file-read[data-role='file-activity'][data-message-status='running']",
             "Read"
           )

    assert has_element?(lv, "#agent-file-legacy-file-read", "contract.jsonl")

    send(
      lv.pid,
      {:agent_event, Map.merge(base, %{type: :reasoning_delta, delta: "workspace"})}
    )

    sync_liveview(lv)
    ref = liveview_assign(lv, :agent_reasoning_flush_ref)
    if is_reference(ref), do: send(lv.pid, {:flush_agent_reasoning, ref})
    sync_liveview(lv)

    assert has_element?(lv, "#agent-thinking-#{turn_id}-0", "Inspect")
    assert has_element?(lv, "#agent-thinking-#{turn_id}-1", "workspace")

    send(stream_pid, :release_agent_ui)
    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    assert has_element?(
             lv,
             "#agent-file-legacy-file-read[data-message-status='failed']",
             "Turn ended before the file operation finished."
           )
  end

  test "agent sidebar repairs sentence boundaries lost between streamed prose deltas", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          {:text_delta, "확인한다."},
          {:text_delta, "첫 장을 본다."},
          {:text_delta, "JSONL 검증도 한다."}
        ]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)
    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "stream Korean prose"})
    |> render_submit()

    assert_push_event(
      lv,
      "agent.stream.text_appended",
      %{message_id: message_id, piece: "확인한다."},
      1_000
    )

    assert_push_event(
      lv,
      "agent.stream.text_appended",
      %{message_id: ^message_id, piece: "첫 장을 본다."},
      1_000
    )

    assert_push_event(
      lv,
      "agent.stream.text_appended",
      %{message_id: ^message_id, piece: "JSONL 검증도 한다."},
      1_000
    )

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    final_body =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        ~s([data-role="agent-message"][data-message-role="agent"][data-message-status="sent"])
      )
      |> LazyHTML.text()

    assert final_body =~ "확인한다. 첫 장을 본다. JSONL 검증도 한다."
    refute final_body =~ "확인한다.첫"
    refute final_body =~ "본다.JSONL"
  end

  test "agent prose deltas do not create an embedded editor preview for the active document", %{
    conn: conn
  } do
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "draft"}]])

    {:ok, lv, _html} = open_workspace(conn, document: "drafts/ledger.xlsx")

    assert_canvas_state_after_open_sync(lv, ~s([data-role="office-wasm-viewer"]), %{
      "localDocumentFormat" => "xlsx"
    })

    lv
    |> form("#agent-form", agent: %{message: "edit workbook"})
    |> render_submit()

    assert_push_event(
      lv,
      "agent.stream.text_appended",
      %{message_id: _message_id, piece: "draft"},
      1_000
    )

    refute_push_event(lv, "document.preview.delta_received", %{text: "draft"}, 200)

    sync_liveview(lv)

    refute has_element?(lv, ~s([data-role="editor-preview"]))

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="agent"][data-message-status="sent"]),
             "draft"
           )
  end

  test "ACP edit updates render a document preview without a generic tool row", %{conn: conn} do
    root = WorkspaceAdapterStub.valid_path()

    use_test_agent_adapter!(
      adapter_opts: [
        script: [
          {:text_delta, "before edit"},
          %{type: :anonymous_tool_call, id: "anonymous-before-edit"},
          %{
            type: :edit_delta,
            id: "acp-edit-1",
            path: Path.join(root, ".ecrits/template.hwpx.jsonl"),
            delta: "@@ -1 +1 @@\n-old\n+new"
          },
          %{type: :anonymous_tool_call, id: "anonymous-after-edit"},
          {:text_delta, "after edit"}
        ]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "edit the document"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    assert_preview_state(lv, %{"documentPath" => "template.hwpx", "deltaCount" => 1})
    refute has_element?(lv, "#agent-tool-acp-edit-1")
    refute has_element?(lv, "#agent-tool-anonymous-before-edit")
    refute has_element?(lv, "#agent-tool-anonymous-after-edit")

    rows =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(#agent-thread > [data-chat-role="chat-message"]))
      |> Enum.map(fn node ->
        {
          node |> LazyHTML.attribute("data-message-role") |> List.first(),
          node |> LazyHTML.attribute("id") |> List.first()
        }
      end)
      |> Enum.reject(fn {role, _id} -> role == "thinking" end)

    assert [
             {"user", _user_id},
             {"agent", before_id},
             {"editor_preview", _preview_id},
             {"agent", after_id}
           ] = rows

    assert before_id =~ "-0"
    assert after_id =~ "-1"

    assert [%{items: items}] = AcpAgent.agent_snapshot(session_id).transcript
    refute Enum.any?(items, &(Map.get(&1, :role) == :tool))
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
        wait_for: :release_agent_ui,
        script: [{:text_delta, "streaming reply"}]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "go"})
    |> render_submit()

    assert_receive {:agent_adapter_waiting, stream_pid}, 1_000
    sync_liveview(lv)

    # Empty `running` placeholder: the waiting animation IS present.
    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="agent"][data-message-status="running"] [data-role="agent-loading"])
           )

    # Release the turn; deltas stream and the bubble finalizes with body text.
    send(stream_pid, :release_agent_ui)

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    # Once the reply carries body text, the waiting indicator must be gone — a
    # bubble that still rendered the dots while showing prose is the freeze bug.
    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="agent"]),
             "streaming reply"
           )

    refute has_element?(lv, ~s([data-role="agent-message"] [data-role="agent-loading"]))
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
    |> form("#agent-form", agent: %{message: "hi"})
    |> render_submit()

    # Only the two streamed deltas should reach the browser as append events —
    # the terminal `final: true` chunk must NOT produce a third append.
    assert_push_event(
      lv,
      "agent.stream.text_appended",
      %{message_id: msg_id, piece: "Hi "},
      1_000
    )

    assert_push_event(
      lv,
      "agent.stream.text_appended",
      %{message_id: ^msg_id, piece: "there?"},
      1_000
    )

    refute_push_event(lv, "agent.stream.text_appended", %{piece: "Hi there?"}, 200)

    # The accumulated turn text must be the single message, not the doubled one.
    assert_receive {:agent_event,
                    %{type: :turn_completed, session_id: ^session_id, text: "Hi there?"}},
                   1_000

    sync_liveview(lv)

    final_body =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        ~s([data-role="agent-message"][data-message-role="agent"][data-message-status="sent"])
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
    |> form("#agent-form", agent: %{message: "summarize"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_completed, session_id: ^session_id}}, 1_000
    sync_liveview(lv)

    body =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        ~s([data-role="agent-message"][data-message-role="agent"][data-message-status="sent"])
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
      ~s([data-role="agent-message"][data-message-role="agent"][data-message-status="sent"])

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
    |> form("#agent-form", agent: %{message: "no deltas"})
    |> render_submit()

    assert_push_event(
      lv,
      "agent.stream.text_appended",
      %{message_id: _msg_id, piece: "Only final."},
      1_000
    )

    assert_receive {:agent_event,
                    %{type: :turn_completed, session_id: ^session_id, text: "Only final."}},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="agent"][data-message-status="sent"]),
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
    |> form("#agent-form", agent: %{message: "markdown"})
    |> render_submit()

    assert_push_event(
      lv,
      "agent.stream.text_appended",
      %{message_id: message_id, piece: piece},
      1_000
    )

    assert piece =~ "Intro"

    sync_liveview(lv)

    # MDEx (GFM) emits standard semantic tags inside the shared prose container.
    assert has_element?(
             lv,
             "##{message_id} [data-role='chat-md-body'] p strong",
             "bold"
           )

    assert has_element?(lv, "##{message_id} [data-role='chat-md-body'] p code", "inline()")
    assert has_element?(lv, "##{message_id} [data-role='chat-md-body'] ul li", "first item")

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
        wait_for: :release_agent_ui,
        script: [{:text_delta, "late"}]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "wait"})
    |> render_submit()

    assert_receive {:agent_adapter_waiting, _stream_pid}, 1_000
    sync_liveview(lv)

    assert has_element?(lv, "#agent-sidebar[data-agent-status='running']")
    refute has_element?(lv, "#agent-cancel")
    assert has_element?(lv, "#agent-submit[data-role='chat-stop'][data-action='stop']")
    refute has_element?(lv, "#agent-submit[data-role='chat-send']")
    assert has_element?(lv, "#agent-input:not([disabled])")
    assert has_element?(lv, ~s(#agent-input[placeholder="Ask about this workspace"]))
    refute render(lv) =~ "Agent is responding"

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="agent"][data-message-status="running"] [data-role="agent-loading"])
           )

    lv
    |> element("#agent-submit[data-role='chat-stop']")
    |> render_click()

    assert_receive {:agent_event, %{type: :turn_cancelled, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    assert has_element?(lv, "#agent-sidebar[data-agent-status='cancelled']")

    refute has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="agent"][data-message-status="cancelled"])
           )
  end

  test "turn cancellation aborts its independent browser VFS request", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_agent_vfs_cancel,
        script: [{:text_delta, "late"}]
      ]
    )

    root = WorkspaceAdapterStub.valid_path()
    {:ok, lv, _html} = open_workspace(conn, root, document: "template.hwpx")
    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "edit it"})
    |> render_submit()

    assert_receive {:agent_adapter_waiting, _stream_pid}, 1_000
    sync_liveview(lv)

    turn_id = liveview_assign(lv, :agent_turn_id)
    instance_id = liveview_assign(lv, :agent_instance_id)
    expected_document_id = liveview_assign(lv, :pool_document_id)
    edit_id = "turn-cancelled-browser-vfs"

    caller =
      Task.async(fn ->
        BrowserBridge.call(
          lv.pid,
          :vfs_write,
          %{
            edit_id: edit_id,
            agent_id: session_id,
            instance_id: instance_id,
            turn_id: turn_id
          },
          expected_document_id: expected_document_id,
          timeout: 3_000
        )
      end)

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{
        document_id: view_document_id,
        verb: "vfs_write",
        payload: %{edit_id: ^edit_id, turn_id: ^turn_id}
      },
      1_000
    )

    lv
    |> element("#agent-submit[data-role='chat-stop']")
    |> render_click()

    assert_receive {:agent_event,
                    %{type: :turn_cancelled, session_id: ^session_id, turn_id: ^turn_id}},
                   1_000

    sync_liveview(lv)
    assert {:error, {:turn_cancelled, ^turn_id}} = Task.await(caller, 2_000)

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{
        document_id: ^view_document_id,
        verb: "vfs_rollback",
        payload: %{edit_id: ^edit_id}
      },
      1_000
    )

    sync_liveview(lv)
    assert liveview_assign(lv, :doc_browser_pending) == %{}
    assert liveview_assign(lv, :doc_browser_vfs_leases) == %{}
  end

  test "agent sidebar submit during running queues the next turn", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_agent_ui,
        script: [{:text_delta, "done"}]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    lv
    |> form("#agent-form", agent: %{message: "first"})
    |> render_submit()

    assert_receive {:agent_adapter_waiting, first_stream_pid}, 1_000
    sync_liveview(lv)

    assert has_element?(lv, "#agent-sidebar[data-agent-status='running']")
    assert has_element?(lv, "#agent-input:not([disabled])")
    assert has_element?(lv, "#agent-submit[data-role='chat-stop'][data-action='stop']")
    refute has_element?(lv, "#agent-submit[data-role='chat-send']")

    lv
    |> form("#agent-form", agent: %{message: "second"})
    |> render_submit()

    assert_receive {:agent_event, %{type: :turn_queued, session_id: ^session_id, pending: 1}},
                   1_000

    sync_liveview(lv)

    assert has_element?(
             lv,
             "#agent-queued-panel[data-role='queued-messages'][data-queued-count='1'][data-queued-index='1']",
             "Queue 1/1"
           )

    assert has_element?(lv, "#agent-queued-title[data-role='queued-count']", "Queue 1/1")
    assert has_element?(lv, "#agent-queued-title[class*='text-[10px]']")
    assert has_element?(lv, "#agent-queued-body[data-role='queued-body']")
    assert has_element?(lv, "#agent-queued-message[data-role='queued-message']", "second")
    assert has_element?(lv, "#agent-queued-message[class*='text-[13px]']")
    assert has_element?(lv, "#agent-queued-flush[title='Send queued']", "Send")

    refute_received {:agent_event, %{type: :turn_cancelled, session_id: ^session_id}}

    lv
    |> element("#agent-submit[data-role='chat-stop']")
    |> render_click()

    assert_receive {:agent_event, %{type: :turn_cancelled, session_id: ^session_id}},
                   1_000

    sync_liveview(lv)

    assert has_element?(lv, "#agent-sidebar[data-agent-status='cancelled']")

    assert has_element?(
             lv,
             "#agent-queued-panel[data-role='queued-messages'][data-queued-count='1'][data-queued-index='1']",
             "Queue 1/1"
           )

    assert has_element?(lv, "#agent-queued-title[data-role='queued-count']", "Queue 1/1")
    assert has_element?(lv, "#agent-queued-title[class*='text-[10px]']")
    assert has_element?(lv, "#agent-queued-body[data-role='queued-body']")
    assert has_element?(lv, "#agent-queued-message[class*='text-[13px]']")

    refute has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "second"
           )

    lv
    |> element("#agent-queued-flush")
    |> render_click()

    assert_receive {:agent_adapter_waiting, second_stream_pid}, 1_000

    sync_liveview(lv)

    assert has_element?(lv, "#agent-sidebar[data-agent-status='running']")
    refute has_element?(lv, "#agent-queued-panel")

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="user"]),
             "second"
           )

    refute has_element?(lv, "#agent-error", "turn_in_progress")

    send(first_stream_pid, :release_agent_ui)
    send(second_stream_pid, :release_agent_ui)

    assert_receive {:agent_event,
                    %{type: :turn_completed, session_id: ^session_id, text: "done"}},
                   1_000

    sync_liveview(lv)
    stop_pid(lv.pid)
  end

  test "queued turn waits for the running turn before taking over", %{conn: conn} do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_agent_ui,
        script: [{:text_delta, "B-streaming"}]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    # Turn A: start it and let it become :running (blocked on wait_for).
    lv
    |> form("#agent-form", agent: %{message: "first"})
    |> render_submit()

    assert_receive {:agent_adapter_waiting, first_stream_pid}, 1_000
    sync_liveview(lv)

    turn_a = liveview_assign(lv, :agent_turn_id)
    assert is_binary(turn_a)

    # Submit a SECOND message mid-stream: queue B behind A.
    lv
    |> form("#agent-form", agent: %{message: "second"})
    |> render_submit()

    assert_receive {:agent_event,
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
    assert liveview_assign(lv, :agent_turn_id) == turn_a
    assert liveview_assign(lv, :agent_status) == :running

    send(first_stream_pid, :release_agent_ui)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_a}}, 1_000
    assert_receive {:agent_adapter_waiting, second_stream_pid}, 1_000

    sync_liveview(lv)

    assert liveview_assign(lv, :agent_status) == :running
    assert liveview_assign(lv, :agent_turn_id) != turn_a

    assert has_element?(
             lv,
             ~s([data-role="agent-message"][data-message-role="agent"][data-message-status="running"])
           )

    send(second_stream_pid, :release_agent_ui)
  end

  test "hook sends during a running turn preserve queue order and visible pending state", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_agent_ui,
        script: [{:text_delta, "done"}]
      ]
    )

    {:ok, lv, _html} = open_workspace(conn)

    session_id = subscribe_agent(lv)

    render_hook(lv, "agent.message.submit_requested", %{"message" => "first"})

    assert_receive {:agent_adapter_waiting, first_stream_pid}, 1_000
    sync_liveview(lv)

    turn_a = liveview_assign(lv, :agent_turn_id)
    assert is_binary(turn_a)

    render_hook(lv, "agent.message.submit_requested", %{"message" => "second"})
    render_hook(lv, "agent.message.submit_requested", %{"message" => "third"})

    assert_receive {:agent_event,
                    %{
                      type: :turn_queued,
                      session_id: ^session_id,
                      turn_id: turn_b,
                      pending: 1
                    }},
                   1_000

    assert_receive {:agent_event,
                    %{
                      type: :turn_queued,
                      session_id: ^session_id,
                      turn_id: turn_c,
                      pending: 2
                    }},
                   1_000

    sync_liveview(lv)

    assert liveview_assign(lv, :agent_turn_id) == turn_a
    assert liveview_assign(lv, :agent_pending) == 2
    assert Enum.map(liveview_assign(lv, :agent_queue), & &1.body) == ["second", "third"]

    assert has_element?(
             lv,
             "#agent-queued-panel[data-role='queued-messages'][data-queued-count='2'][data-queued-index='1']",
             "Queue 1/2"
           )

    send(first_stream_pid, :release_agent_ui)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_a}}, 1_000
    assert_receive {:agent_adapter_waiting, second_stream_pid}, 1_000
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn_b}}, 1_000

    sync_liveview(lv)

    assert liveview_assign(lv, :agent_turn_id) == turn_b
    assert liveview_assign(lv, :agent_pending) == 1
    assert Enum.map(liveview_assign(lv, :agent_queue), & &1.body) == ["third"]

    send(second_stream_pid, :release_agent_ui)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_b}}, 1_000
    assert_receive {:agent_adapter_waiting, third_stream_pid}, 1_000
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn_c}}, 1_000

    sync_liveview(lv)

    assert liveview_assign(lv, :agent_turn_id) == turn_c
    assert liveview_assign(lv, :agent_pending) == 0
    assert liveview_assign(lv, :agent_queue) == []

    send(third_stream_pid, :release_agent_ui)
  end

  # Inject the test-only fake ex_mcp ACP adapter so the chat-rail rendering can be
  # driven deterministically through the real ExMCP.ACP stack (no provider CLI).
  defp use_test_agent_adapter!(opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    Application.put_env(:ecrits, :agent, provider: "codex")

    Application.put_env(:ecrits, :agent_ui,
      provider: "codex",
      adapter_opts: Keyword.put(adapter_opts, :exmcp_adapter, EcritsWeb.FakeAcpAdapter)
    )
  end

  defp put_provider_integrations!(integrations) do
    current =
      case Application.get_env(:ecrits, :agent_ui, []) do
        config when is_list(config) -> config
        _ -> []
      end

    Application.put_env(
      :ecrits,
      :agent_ui,
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

  defp open_workspace(conn), do: open_workspace(conn, WorkspaceAdapterStub.valid_path(), [])

  defp open_workspace(conn, opts) when is_list(opts),
    do: open_workspace(conn, WorkspaceAdapterStub.valid_path(), opts)

  defp open_workspace(conn, path) when is_binary(path), do: open_workspace(conn, path, [])

  defp open_workspace(conn, path, opts) do
    tab_id = Keyword.get(opts, :chat_rail_tab_id, Ecto.UUID.generate())
    conn = put_workspace_handoff(conn, path)

    {:ok, lv, html} = live(conn, ~p"/workspace")
    render_hook(lv, "workspace.chat_rail.tab_ready", %{"id" => tab_id})
    sync_liveview(lv)

    case Keyword.get(opts, :document) do
      nil ->
        {:ok, lv, html}

      document_path ->
        open_document(lv, document_path)
        {:ok, lv, render(lv)}
    end
  end

  defp open_document(lv, document_path) do
    render_hook(lv, "workspace.document.open", %{"path" => document_path})
    render_async(lv, 2_000)
    sync_liveview(lv)
    lv
  end

  defp put_workspace_handoff(conn, path) do
    live_session_id = Plug.Conn.get_session(conn, :live_session_id)
    :ok = WorkspaceHandoff.put_workspace_path(live_session_id, path)
    conn
  end

  defp init_workspace_session(
         conn,
         live_session_id,
         path \\ WorkspaceAdapterStub.valid_path()
       ) do
    conn = Phoenix.ConnTest.init_test_session(conn, %{live_session_id: live_session_id})
    put_workspace_handoff(conn, path)
  end

  defp subscribe_agent(lv) do
    session_id = agent_session_id(lv)
    :ok = AcpAgent.subscribe(session_id)
    track_agent_session(session_id)

    session_id
  end

  defp seed_known_vfs_turn(session_id, turn_id)
       when is_binary(session_id) and is_binary(turn_id) do
    :ok =
      AcpAgent.append_transcript_item(session_id, %{
        role: :thinking,
        status: :completed,
        body: "",
        turn_id: turn_id
      })
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

  defp agent_session_id(lv) do
    session_id =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#agent-sidebar")
      |> LazyHTML.attribute("data-session-id")
      |> List.first()

    assert is_binary(session_id)
    assert session_id != ""
    session_id
  end

  defp agent_instance_id(session_id) when is_binary(session_id),
    do: AcpAgent.agent_snapshot(session_id).instance_id

  defp mixed_preview_descriptor(session_id, turn_id) do
    assert [descriptor] = mixed_preview_descriptors(session_id, turn_id)
    descriptor
  end

  defp mixed_preview_descriptors(session_id, turn_id) do
    snapshot = AcpAgent.agent_snapshot(session_id)

    (Map.get(snapshot, :transcript, []) ++ List.wrap(Map.get(snapshot, :current_turn)))
    |> Enum.filter(&(Map.get(&1, :turn_id) == turn_id))
    |> Enum.flat_map(&Map.get(&1, :items, []))
    |> Enum.filter(&(Map.get(&1, :role) == :edit_preview))
  end

  defp mixed_preview_canvas_state(lv) do
    canvas_state(lv, ~s([data-role="editor-preview"] [data-component="canvas-hwp-pages"]))
  end

  defp mixed_preview_chat_rows(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#agent-thread > [data-chat-role="chat-message"]))
    |> Enum.map(fn row ->
      %{
        id: row |> LazyHTML.attribute("id") |> List.first(),
        role: row |> LazyHTML.attribute("data-message-role") |> List.first()
      }
    end)
  end

  defp mixed_preview_row_id(rows) do
    rows
    |> Enum.find(&(Map.fetch!(&1, :role) == "editor_preview"))
    |> Map.fetch!(:id)
  end

  defp mixed_preview_row_index(rows, id), do: Enum.find_index(rows, &(Map.fetch!(&1, :id) == id))

  defp prepare_acknowledged_browser_commit(lv, expected_document_id, edit_id) do
    write_ref = make_ref()

    send(
      lv.pid,
      {:doc_browser_request, self(), write_ref, :vfs_write, %{edit_id: edit_id},
       expected_document_id}
    )

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{request_id: write_request_id, verb: "vfs_write", payload: %{edit_id: ^edit_id}},
      1_000
    )

    render_hook(lv, "document.engine.operation.replied", %{
      "request_id" => write_request_id,
      "result" => %{"edit_id" => edit_id, "bytes" => "exported"}
    })

    assert_receive {:doc_browser_reply, ^write_ref, {:ok, %{"edit_id" => ^edit_id}}}
    send(lv.pid, {:doc_browser_request_completed, self(), write_ref})
    sync_liveview(lv)

    commit_ref = make_ref()

    send(
      lv.pid,
      {:doc_browser_request, self(), commit_ref, :vfs_commit, %{edit_id: edit_id},
       expected_document_id}
    )

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{
        request_id: commit_request_id,
        document_id: browser_document_id,
        verb: "vfs_commit",
        payload: %{edit_id: ^edit_id}
      },
      1_000
    )

    render_hook(lv, "document.engine.operation.replied", %{
      "request_id" => commit_request_id,
      "result" => %{"edit_id" => edit_id, "awaiting_finalize" => true}
    })

    assert_receive {:doc_browser_reply, ^commit_ref,
                    {:ok, %{"edit_id" => ^edit_id, "awaiting_finalize" => true}}}

    send(lv.pid, {:doc_browser_request_completed, self(), commit_ref})

    assert_push_event(
      lv,
      "document.engine.operation.command",
      %{request_id: finalize_request_id, verb: "vfs_finalize", payload: %{edit_id: ^edit_id}},
      1_000
    )

    {finalize_request_id, browser_document_id}
  end

  defp sync_liveview(lv) do
    _ = :sys.get_state(lv.pid)
    :ok
  end

  defp await_agent_session_change(lv, old_session_id, attempts \\ 200)

  defp await_agent_session_change(lv, old_session_id, attempts) when attempts > 0 do
    sync_workspace_session(
      liveview_assign(lv, :workspace_path) || WorkspaceAdapterStub.valid_path()
    )

    sync_liveview(lv)

    case agent_session_id(lv) do
      ^old_session_id ->
        receive do
        after
          5 -> await_agent_session_change(lv, old_session_id, attempts - 1)
        end

      new_session_id ->
        new_session_id
    end
  end

  defp await_agent_session_change(_lv, old_session_id, 0) do
    flunk("agent session did not change from #{old_session_id}")
  end

  defp send_vfs_edit_and_wait(lv, info) when is_map(info) do
    owner = self()
    target = lv.pid
    :ok = :dbg.stop()
    {:ok, _tracer} = :dbg.start()

    {:ok, _tracer} =
      :dbg.tracer(
        :process,
        {fn
           {:trace, ^target, :call,
            {EcritsWeb.Workspace.WorkspaceLive, :handle_info, [{:vfs_doc_edited, _info}, _socket]}},
           _waiting? ->
             true

           {:trace, ^target, :return_from, {EcritsWeb.Workspace.WorkspaceLive, :handle_info, 2},
            _result},
           true ->
             send(owner, {:vfs_doc_edit_handled, target})
             false

           _trace, waiting? ->
             waiting?
         end, false}
      )

    {:ok, _matched} = :dbg.p(target, :c)

    {:ok, _matched} =
      :dbg.tpl(EcritsWeb.Workspace.WorkspaceLive, :handle_info, 2, :x)

    try do
      send(target, {:vfs_doc_edited, info})
      assert_receive {:vfs_doc_edit_handled, ^target}, 2_000
    after
      :ok = :dbg.stop()
    end
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
        liveview_assign(lv, :workspace_path) || WorkspaceAdapterStub.valid_path()
      )

      sync_liveview(lv)
    end

    assert has_element?(lv, selector)
  end

  defp assert_canvas_state(lv, selector, expected) do
    assert encoded_state?(lv, selector, "data-canvas-state", expected),
           "expected #{selector} canvas state to include #{inspect(expected)}"
  end

  defp assert_canvas_state_after_open_sync(lv, selector, expected) do
    unless encoded_state?(lv, selector, "data-canvas-state", expected) do
      sync_workspace_session(
        liveview_assign(lv, :workspace_path) || WorkspaceAdapterStub.valid_path()
      )

      sync_liveview(lv)
    end

    assert_canvas_state(lv, selector, expected)
  end

  defp assert_preview_state(lv, expected) do
    assert encoded_state?(lv, ~s([data-role="editor-preview"]), "data-preview-state", expected),
           "expected editor preview state to include #{inspect(expected)}"
  end

  defp encoded_state?(lv, selector, attribute, expected) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.any?(fn state ->
      Enum.all?(expected, fn {key, value} -> Map.get(state, key) == value end)
    end)
  end

  defp canvas_state(lv, selector) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("data-canvas-state")
    |> List.first()
    |> Jason.decode!()
  end

  defp fetch_document_bytes(url) do
    build_conn()
    |> get(url)
    |> response(200)
  end

  defp rezip_hwpx(bytes, marker) do
    assert {:ok, entries} = :zip.unzip(bytes, [:memory])

    entries =
      Enum.reject(entries, fn {name, _contents} -> name == ~c"preview-version.txt" end)

    assert {:ok, {_name, rewritten}} =
             :zip.create(
               ~c"preview-version.hwpx",
               entries ++ [{~c"preview-version.txt", marker}],
               [:memory]
             )

    rewritten
  end

  defp restore_doc_vfs_env(nil), do: Application.delete_env(:ecrits, :doc_vfs)
  defp restore_doc_vfs_env(value), do: Application.put_env(:ecrits, :doc_vfs, value)

  defp liveview_assign(lv, key) do
    lv.pid
    |> :sys.get_state()
    |> Map.get(:socket)
    |> then(& &1.assigns[key])
  end

  defp put_liveview_octet(lv, id, bytes) do
    :sys.replace_state(lv.pid, fn state ->
      socket = Map.fetch!(state, :socket)
      stash = Map.put(socket.assigns.octet_stash, id, bytes)
      Map.put(state, :socket, %{socket | assigns: Map.put(socket.assigns, :octet_stash, stash)})
    end)

    :ok
  end

  defp rhwp_document_id(lv) do
    document_id =
      lv
      |> render_hwp_editor_html()
      |> hwp_document_id_from_html()

    assert is_binary(document_id)
    assert document_id != ""
    document_id
  end

  defp render_hwp_editor_html(lv) do
    html = render(lv)

    if hwp_document_id_from_html(html) do
      html
    else
      sync_liveview(lv)
      render(lv)
    end
  end

  defp hwp_document_id_from_html(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="hwp-editor"]))
    |> LazyHTML.attribute("data-canvas-state")
    |> List.first()
    |> then(fn
      nil -> nil
      encoded -> encoded |> Jason.decode!() |> Map.get("localDocumentId")
    end)
  end

  defp prepare_workspace_fixture do
    cleanup_workspace_fixture()

    root = WorkspaceAdapterStub.valid_path()
    File.mkdir_p!(Path.join(root, "drafts"))

    File.cp!("test/fixtures/hwpx/real_contract.hwpx", Path.join(root, "template.hwpx"))

    File.cp!(
      "test/fixtures/hwpx/real_contract.hwpx",
      Path.join(root, "drafts/service.hwpx")
    )

    File.write!(Path.join(root, "drafts/reference.docx"), "docx fixture")
    File.write!(Path.join(root, "drafts/ledger.xlsx"), "xlsx fixture")
  end

  defp cleanup_workspace_fixture do
    root = WorkspaceAdapterStub.valid_path()
    _ = Ecrits.Fuse.DocMount.teardown(root)

    for relative_path <- [
          "template.hwpx",
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
