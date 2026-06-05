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
  alias Ecrits.Local.Document
  alias EcritsWeb.LocalDirectoryPickerStub
  alias EcritsWeb.LocalWorkspaceAdapterStub

  setup do
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

    on_exit(fn ->
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
  end

  test "root renders unauthenticated mount screen", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/")

    assert has_element?(lv, "#local-mount-root")
    assert has_element?(lv, "#local-mount-picker")
    assert has_element?(lv, "#local-native-directory-picker[data-role='native-directory-picker']")
    assert has_element?(lv, "#local-mount-picker-surface[data-role='mount-picker-surface']")
    assert has_element?(lv, "#local-mount-control-row[data-role='mount-control-row']")
    assert has_element?(lv, "#local-mount-control-row #local-mount-choose", "Choose folder")
    assert has_element?(lv, "#local-mount-control-row #local-path-form[method='get']")

    assert has_element?(
             lv,
             "#local-mount-control-row #local-path-input[name='path']"
           )

    assert has_element?(
             lv,
             "#local-mount-control-row #local-path-submit[type='submit'][aria-label='Open path'][title='Open path'] .hero-arrow-turn-down-left"
           )

    refute has_element?(lv, "#local-path-submit", "Open")
    refute has_element?(lv, "footer")

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

  test "invalid mount path renders inline error", %{conn: conn} do
    Application.put_env(:ecrits, :local_directory_picker_stub, {:ok, "/not-here"})

    {:ok, lv, _html} = live(conn, ~p"/")

    lv
    |> element("#local-mount-choose")
    |> render_click()

    assert has_element?(lv, "#local-mount-error", "Workspace path does not exist.")
    assert has_element?(lv, "#local-mount-picker")
  end

  test "workspace path query rejects an invalid path", %{conn: conn} do
    file_path = Path.join(LocalWorkspaceAdapterStub.valid_path(), "not-a-directory.txt")
    File.write!(file_path, "not a directory")

    {:ok, lv, _html} = live(conn, ~p"/workspace?#{[path: file_path]}")

    assert has_element?(lv, "#local-workspace-error", "Workspace path does not exist.")
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

    assert has_element?(
             lv,
             "#local-mount-error",
             "Native folder picker is unavailable on this OS."
           )
  end

  test "manual path form is a native GET to the workspace shell", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")

    assert has_element?(
             lv,
             "#local-path-form[action='/workspace'][method='get'] #local-path-input[name='path']"
           )
  end

  test "valid mount path navigates to workspace shell", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")

    lv
    |> element("#local-mount-choose")
    |> render_click()

    assert_redirect(
      lv,
      ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path()]}"
    )

    {:ok, workspace_lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path()]}"
      )

    assert has_element?(workspace_lv, "#local-workspace-root")
    assert has_element?(workspace_lv, "#local-workspace-root[class*='overflow-hidden']")
    assert has_element?(workspace_lv, "#local-workspace-grid[phx-hook='LocalChatRailResizer']")
    assert has_element?(workspace_lv, "#local-workspace-grid[class*='h-full']")
    assert has_element?(workspace_lv, "#local-workspace-grid[class*='isolate']")
    assert has_element?(workspace_lv, "#local-workspace-grid[style*='--local-editor-z']")
    assert has_element?(workspace_lv, "#local-workspace-grid[style*='--local-agent-rail-z']")
    assert has_element?(workspace_lv, "#local-workspace-grid[class*='lg:overflow-hidden']")

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
             ~s(#local-file-tree-resizer[data-role="file-tree-resizer"][aria-label="Resize file tree"][class*="lg:block"])
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
             "#local-agent-rail-resizer[data-role='chat-rail-resizer'][aria-label='Resize chat rail'][class*='lg:block']"
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
             "#local-agent-model-select button#local-agent-inline-model-claude-default"
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
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex"]}"
      )

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

    assert_patch(
      lv,
      ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex", model: "gpt-5.5", reasoning: "high", access: "read-only"]}"
    )

    assert has_element?(
             lv,
             "#local-agent-provider-options #local-agent-reasoning-select[data-selected-reasoning='high'] button#local-agent-inline-reasoning-high[data-selected='true']",
             "High - deeper reasoning, more tokens"
           )
  end

  test "workspace chat rail provider detail switches provider", %{conn: conn} do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex"]}"
      )

    lv
    |> element("#local-agent-go-to-provider")
    |> render_click()

    lv
    |> element("#local-agent-model-detail-claude")
    |> render_click()

    assert_patch(
      lv,
      ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "claude", model: "claude-default", reasoning: "medium", access: "read-only"]}"
    )

    assert has_element?(
             lv,
             "#local-agent-provider-options[data-selected-provider='claude'][data-selected-model='claude-default'] #local-agent-model-select[data-selected-provider='claude'][data-selected-model='claude-default']",
             "Claude"
           )

    refute has_element?(
             lv,
             "#local-agent-model-select button[data-role='agent-model-option'][data-provider='codex']"
           )

    refute has_element?(lv, "#local-agent-model-select option")
  end

  test "workspace chat rail submits selected inline options to the local agent", %{conn: conn} do
    use_test_agent_adapter!(adapter_opts: [echo_opts: true])

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex"]}"
      )

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

    assert_patch(
      lv,
      ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex", model: "gpt-5.3-codex-spark", reasoning: "medium", access: "read-only"]}"
    )

    lv
    |> element("#local-agent-inline-reasoning-xhigh")
    |> render_click()

    assert_patch(
      lv,
      ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex", model: "gpt-5.3-codex-spark", reasoning: "xhigh", access: "read-only"]}"
    )

    lv
    |> element("#local-agent-inline-access-full-workspace")
    |> render_click()

    assert_patch(
      lv,
      ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex", model: "gpt-5.3-codex-spark", reasoning: "xhigh", access: "full-workspace"]}"
    )

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
    assert text =~ "Test response: selected rail opts"
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

  test "workspace chat rail coerces fake provider URL to codex", %{conn: conn} do
    root = LocalWorkspaceAdapterStub.valid_path()

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/workspace?#{[path: root, provider: "fake"]}")

    assert to =~ "provider=codex"
    refute to =~ "provider=fake"
  end

  test "file tree supports metadata, expansion, row-open, and format affordances", %{conn: conn} do
    {:ok, lv, _html} =
      live(conn, ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path()]}")

    assert has_element?(lv, "#local-file-tree")
    assert has_element?(lv, ~s(#local-file-tree ul[role="tree"]))
    assert has_element?(lv, ~s([data-node-path=".ecrits"][data-metadata="true"]))
    assert has_element?(lv, ~s([data-node-path="Assignment #2"][data-expanded="false"]))
    assert has_element?(lv, ~s([data-node-path="drafts"][data-expanded="false"]))

    assert has_element?(
             lv,
             ~s([data-role="repo-browser-row"][data-node-path="template.hwp"][data-openable="true"][data-file-extension="hwp"][phx-click="open_file"][class*="hover:bg-base-200"])
           )

    assert has_element?(lv, "#local-file-node-template-hwp[phx-click='open_file']")
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
             ~s([data-node-path="drafts/service.hwpx"][data-openable="true"][phx-click="open_file"])
           )

    refute has_element?(lv, "#open-file-drafts-service-hwpx")
    refute has_element?(lv, ~s([id^="open-file-"]))
    refute has_element?(lv, "#preview-file-drafts-reference-docx")
    refute has_element?(lv, "#disabled-file-drafts-notes-xyz")

    assert has_element?(
             lv,
             ~s([data-node-path="drafts/reference.docx"][data-openable="true"][data-file-extension="docx"][phx-click="open_file"])
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
             "#local-file-node-rulebook-md-acceptance-certificate-acceptance-certificate-md[data-tree-depth='2'][phx-click='select_file']"
           )

    refute has_element?(
             lv,
             "#local-file-node-rulebook-md-acceptance-certificate #local-file-node-rulebook-md-acceptance-certificate-acceptance-certificate-md"
           )

    lv
    |> element("#local-file-node-rulebook-md-acceptance-certificate-acceptance-certificate-md")
    |> render_click()

    assert has_element?(
             lv,
             ~s([data-node-path="rulebook.md/acceptance_certificate/acceptance_certificate.md"][data-selected="true"])
           )

    assert has_element?(
             lv,
             "#local-selected-file",
             "rulebook.md/acceptance_certificate/acceptance_certificate.md"
           )

    refute has_element?(lv, "#local-rhwp-shell")
    refute has_element?(lv, "#local-rhwp-error")

    lv
    |> element("#local-file-node-drafts-service-hwpx")
    |> render_click()

    assert_patch(
      lv,
      ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), document: "drafts/service.hwpx", provider: "codex", model: "gpt-5.5", reasoning: "medium", access: "read-only"]}"
    )

    assert has_element?(lv, ~s([data-node-path="drafts/service.hwpx"][data-selected="true"]))
    assert has_element?(lv, ~s([data-node-path="drafts/service.hwpx"][class*="bg-base-300/70"]))
    refute has_element?(lv, "#local-file-tree-breadcrumb")
    assert has_element?(lv, "#local-active-document-badge", "Open")

    lv
    |> element("#local-file-node-template-hwp")
    |> render_click()

    assert_patch(
      lv,
      ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), document: "template.hwp", provider: "codex", model: "gpt-5.5", reasoning: "medium", access: "read-only"]}"
    )

    assert has_element?(lv, "#local-active-document-badge", "Open")
    refute has_element?(lv, "#local-file-tree-breadcrumb")
  end

  test "document query reopens a local HWPX in the EHWP shell without SaaS upload UI", %{
    conn: conn
  } do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), document: "drafts/service.hwpx"]}"
      )

    assert has_element?(lv, "#local-rhwp-shell")
    assert has_element?(lv, "#local-rhwp-toolbar")
    assert has_element?(lv, "#studio-root[data-component='studio-document-surface']")
    assert has_element?(lv, "#studio-document-header")
    refute has_element?(lv, "#local-file-tree-breadcrumb")
    assert has_element?(lv, "#studio-document-title-form[data-role='document-title-form']")
    assert has_element?(lv, ~s(#studio-document-title-input[value="drafts/service.hwpx"]))
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
    assert has_element?(lv, "#local-rhwp-save-state", "Loaded revision 0")
    refute has_element?(lv, "#local-rhwp-checkpoint")
    refute has_element?(lv, "#local-rhwp-save")
    refute has_element?(lv, ~s([data-role="rhwp-local-checkpoint"]))
    refute has_element?(lv, ~s([data-role="rhwp-local-save"]))
    assert has_element?(lv, "#local-rhwp-editor-frame.contents")

    assert has_element?(
             lv,
             ~s([data-role="local-hwp-editor"][data-renderer="rhwp-wasm"][data-local-document-format="hwpx"][data-local-document-revision="0"])
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
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), document: "drafts/service.hwpx"]}"
      )

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
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), document: "drafts/reference.docx"]}"
      )

    assert has_element?(lv, "#local-rhwp-shell")
    assert has_element?(lv, ~s(#studio-document-title-input[value="drafts/reference.docx"]))

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

  test "local composer upload imports a selected HWPX into the workspace and opens it", %{
    conn: conn
  } do
    root = LocalWorkspaceAdapterStub.valid_path()
    upload_name = "imported-service.hwpx"
    upload_path = Path.join(root, upload_name)
    upload_bytes = File.read!("test/fixtures/hwpx/real_contract.hwpx")

    refute File.exists?(upload_path)

    {:ok, lv, _html} = live(conn, ~p"/workspace?#{[path: root, provider: "codex"]}")

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

    assert_patch(
      lv,
      ~p"/workspace?#{[path: root, document: upload_name, provider: "codex", model: "gpt-5.5", reasoning: "medium", access: "read-only"]}"
    )

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
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), document: "template.hwp"]}"
      )

    assert has_element?(lv, "#local-rhwp-shell[data-component='studio-local-document-surface']")
    assert has_element?(lv, "#studio-root[data-local-document-id]")
    assert has_element?(lv, "#studio-document-header")
    assert has_element?(lv, "#studio-document-header.flex-wrap")
    refute has_element?(lv, "#local-file-tree-breadcrumb")
    assert has_element?(lv, "#studio-document-title-form[data-role='document-title-form']")
    assert has_element?(lv, ~s(#studio-document-title-input[value="template.hwp"]))
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

  test "local employment standard HWP exposes editable specs to the editor", %{conn: conn} do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), document: "employment_v1.hwp"]}"
      )

    assert has_element?(
             lv,
             ~s([data-role="local-hwp-editor"][data-local-document-format="hwp"][data-document-path="employment_v1.hwp"][data-contract-type-key="employment_v1"])
           )

    refute has_element?(lv, ~s([data-role="local-hwp-editor"][data-editable-spec-candidates]))
  end

  test "copied local employment standard HWP does not expose editable specs to the editor", %{
    conn: conn
  } do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), document: "employment_v1 (1).hwp"]}"
      )

    assert has_element?(
             lv,
             ~s|[data-role="local-hwp-editor"][data-local-document-format="hwp"][data-document-path="employment_v1 (1).hwp"][data-contract-type-key="employment_v1"]|
           )

    refute has_element?(lv, ~s([data-role="local-hwp-editor"][data-editable-spec-candidates]))
  end

  test "local rhwp events load bytes, checkpoint, save, and reload saved revision", %{conn: conn} do
    root = LocalWorkspaceAdapterStub.valid_path()
    relative_path = "drafts/service.hwpx"
    path = Path.join(root, relative_path)
    original = File.read!(path)

    {:ok, lv, _html} =
      live(conn, ~p"/workspace?#{[path: root, document: relative_path]}")

    document_id = local_rhwp_document_id(lv)

    render_hook(lv, "rhwp.local.load", %{"document_id" => document_id})
    assert has_element?(lv, "#local-rhwp-save-state", "Loaded revision 0")

    render_hook(lv, "rhwp.local.snapshot.checkpoint", %{
      "document_id" => document_id,
      "bytes_base64" => Base.encode64(original),
      "format" => "hwpx",
      "min_revision" => 0
    })

    assert File.read!(path) == original
    assert has_element?(lv, "#local-rhwp-save-state", "Checkpointed revision 1")

    saved = File.read!("test/fixtures/hwpx/real_contract.hwpx")

    render_hook(lv, "rhwp.local.snapshot.save", %{
      "document_id" => document_id,
      "bytes_base64" => Base.encode64(saved),
      "format" => "hwpx",
      "min_revision" => 1
    })

    assert File.read!(path) == saved
    assert has_element?(lv, "#local-rhwp-save-state", "Saved revision 2")

    {:ok, reloaded_lv, _html} =
      live(conn, ~p"/workspace?#{[path: root, document: relative_path]}")

    assert has_element?(
             reloaded_lv,
             ~s([data-role="local-hwp-editor"][data-local-document-revision="2"])
           )
  end

  test "local rhwp text mutation is acknowledged and does not remount", %{conn: conn} do
    root = LocalWorkspaceAdapterStub.valid_path()

    {:ok, lv, _html} =
      live(conn, ~p"/workspace?#{[path: root, document: "drafts/service.hwpx"]}")

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

    assert {:ok, document} = Document.document(document_id)

    records =
      document
      |> Document.metadata_paths()
      |> Map.fetch!(:mutations)
      |> read_jsonl!()

    assert [
             %{
               "event_id" => "local-edit-1",
               "site_id" => "local",
               "lamport" => 11,
               "body" => %{"type" => "TextDeleted"}
             }
           ] = records
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

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex"]}"
      )

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

  test "agent session starts with active local document id", %{conn: conn} do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), document: "template.hwp", provider: "codex"]}"
      )

    document_id = local_rhwp_document_id(lv)
    session_id = subscribe_agent(lv)

    assert {:ok, %{document_id: ^document_id}} = AcpAgent.status(nil, session_id)
  end

  test "selecting a document preserves the chat-rail conversation and session", %{conn: conn} do
    # Regression for the reset-on-document-select bug: opening/selecting a
    # document must NOT recreate the ACP session or wipe the chat stream. The
    # conversation, the session_id, and the backing Session PID must all survive
    # — exactly like the #54 access-change decoupling.
    use_test_agent_adapter!(adapter_opts: [script: [{:text_delta, "streaming reply"}]])

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), document: "template.hwp", provider: "codex"]}"
      )

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
    lv
    |> element(~s([data-node-path="drafts/service.hwpx"][phx-click="open_file"]))
    |> render_click()

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
    lv
    |> element(~s([data-node-path="template.hwp"][phx-click="open_file"]))
    |> render_click()

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
    # so the agent's doc.* tools still target what the user is viewing.
    new_document_id = local_rhwp_document_id(lv)
    assert {:ok, %{document_id: ^new_document_id}} = AcpAgent.status(nil, session_id)
  end

  test "agent rail shows provider logo in model selector for codex route display", %{conn: conn} do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex"]}"
      )

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
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex"]}"
      )

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

    assert has_element?(
             lv,
             "#local-agent-title-label[value='Pricing review']"
           )
  end

  test "agent generated title replaces the untouched default title", %{conn: conn} do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex"]}"
      )

    session_id = local_agent_session_id(lv)

    send(
      lv.pid,
      {:local_agent_event,
       %{session_id: session_id, type: :title_generated, title: "Employment review"}}
    )

    sync_liveview(lv)

    assert has_element?(
             lv,
             "#local-agent-title-label[value='Employment review']"
           )
  end

  test "agent refresh belongs to chat rail and starts a fresh local agent session", %{conn: conn} do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex"]}"
      )

    old_session_id = subscribe_agent(lv)

    lv
    |> element("#local-agent-refresh")
    |> render_click()

    sync_liveview(lv)

    new_session_id = local_agent_session_id(lv)
    refute new_session_id == old_session_id
    track_agent_session(new_session_id)

    refute has_element?(lv, "#local-agent-system")

    assert has_element?(lv, "#local-agent-sidebar[data-agent-status='idle']")
  end

  test "agent selector supports codex route favicon without provider badge", %{conn: conn} do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex"]}"
      )

    assert has_element?(lv, "#local-agent-sidebar[data-provider-key='codex']")

    assert has_element?(
             lv,
             ~s(#local-agent-model-select[data-role="agent-model-select"] [data-role="agent-model-provider-favicon"][src="/images/icons/openai-blossom.svg"])
           )

    refute has_element?(lv, "#local-agent-title [data-role='chat-title-favicon']")
    refute has_element?(lv, "#local-agent-provider")
    refute has_element?(lv, "#local-agent-provider-icon")
  end

  test "unsupported provider coerces to codex", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(
               conn,
               ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "bogus"]}"
             )

    assert to =~ "provider=codex"
    refute to =~ "provider=fake"
  end

  test "agent status is internal and has no icon or provider badge structure", %{conn: conn} do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path(), provider: "codex"]}"
      )

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
    {:ok, lv, _html} =
      live(conn, ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path()]}")

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
              ],
              "revision" => 3
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
              ],
              "revision" => 3
            }
          },
          {:text_delta, "done"}
        ]
      ]
    )

    {:ok, lv, _html} =
      live(conn, ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path()]}")

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
             ~s("revision": 3)
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

    {:ok, lv, _html} =
      live(conn, ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path()]}")

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

    {:ok, lv, _html} =
      live(conn, ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path()]}")

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

    {:ok, lv, _html} =
      live(conn, ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path()]}")

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

    {:ok, lv, _html} =
      live(conn, ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path()]}")

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

    {:ok, lv, _html} =
      live(conn, ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path()]}")

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

    {:ok, lv, _html} =
      live(conn, ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path()]}")

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

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="agent"][data-message-status="cancelled"]),
             "Cancelled."
           )
  end

  test "agent sidebar submit during running cancels current turn and starts new turn", %{
    conn: conn
  } do
    use_test_agent_adapter!(
      adapter_opts: [
        test_pid: self(),
        wait_for: :release_local_agent_ui,
        script: [{:text_delta, "done"}]
      ]
    )

    {:ok, lv, _html} =
      live(conn, ~p"/workspace?#{[path: LocalWorkspaceAdapterStub.valid_path()]}")

    session_id = subscribe_agent(lv)

    lv
    |> form("#local-agent-form", agent: %{message: "first"})
    |> render_submit()

    assert_receive {:local_agent_adapter_waiting, _first_stream_pid}, 1_000
    sync_liveview(lv)

    assert has_element?(lv, "#local-agent-sidebar[data-agent-status='running']")
    assert has_element?(lv, "#local-agent-input:not([disabled])")
    assert has_element?(lv, "#local-agent-submit[data-role='chat-stop'][data-action='stop']")
    refute has_element?(lv, "#local-agent-submit[data-role='chat-send']")

    lv
    |> form("#local-agent-form", agent: %{message: "second"})
    |> render_submit()

    assert_receive {:local_agent_event, %{type: :turn_cancelled, session_id: ^session_id}}, 1_000
    assert_receive {:local_agent_adapter_waiting, second_stream_pid}, 1_000

    sync_liveview(lv)

    assert has_element?(lv, "#local-agent-sidebar[data-agent-status='running']")

    assert has_element?(
             lv,
             ~s([data-role="local-agent-message"][data-message-role="user"]),
             "second"
           )

    refute has_element?(lv, "#local-agent-error", "turn_in_progress")

    send(second_stream_pid, :release_local_agent_ui)

    assert_receive {:local_agent_event,
                    %{type: :turn_completed, session_id: ^session_id, text: "done"}},
                   1_000
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

  defp subscribe_agent(lv) do
    session_id = local_agent_session_id(lv)
    :ok = AcpAgent.subscribe(session_id)
    track_agent_session(session_id)

    session_id
  end

  defp track_agent_session(session_id) do
    on_exit(fn ->
      case AcpAgent.whereis(session_id) do
        pid when is_pid(pid) -> GenServer.stop(pid)
        nil -> :ok
      end
    end)
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

  defp assert_eventually_has_element(lv, selector) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    assert_eventually_has_element(lv, selector, deadline)
  end

  defp assert_eventually_has_element(lv, selector, deadline) do
    if has_element?(lv, selector) do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        assert_eventually_has_element(lv, selector, deadline)
      else
        assert has_element?(lv, selector)
      end
    end
  end

  defp assert_eventually_assign(lv, key, expected) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    assert_eventually_assign(lv, key, expected, deadline)
  end

  defp assert_eventually_assign(lv, key, expected, deadline) do
    if liveview_assign(lv, key) == expected do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        assert_eventually_assign(lv, key, expected, deadline)
      else
        assert liveview_assign(lv, key) == expected
      end
    end
  end

  defp liveview_assign(lv, key) do
    lv.pid
    |> :sys.get_state()
    |> Map.get(:socket)
    |> then(& &1.assigns[key])
  end

  defp read_jsonl!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp local_rhwp_document_id(lv) do
    document_id =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="local-hwp-editor"]))
      |> LazyHTML.attribute("data-local-document-id")
      |> List.first()

    assert is_binary(document_id)
    assert document_id != ""
    document_id
  end

  defp employment_party_paragraph(employer, worker) do
    "  " <>
      String.pad_trailing(employer, 14) <>
      "(이하 “사업주”라 함)과 " <>
      "   " <>
      String.pad_trailing(worker, 11) <>
      "(이하 “근로자”라 함)은 근로계약을 체결한다."
  end

  defp local_agent_edit_ir(paragraphs, opts) do
    title = Keyword.get(opts, :title, "service.hwpx")
    contract_type = Keyword.get(opts, :contract_type, "local_hwpx")

    %{
      "version" => 1,
      "title" => title,
      "contract_type" => contract_type,
      "sections" => [
        %{
          "idx" => 0,
          "paragraphs" =>
            paragraphs
            |> Enum.with_index()
            |> Enum.map(fn {text, index} -> %{"idx" => index, "text" => text} end)
        }
      ],
      "positional_index" => %{
        "version" => 1,
        "paragraphs" =>
          paragraphs
          |> Enum.with_index()
          |> Enum.map(fn {text, index} ->
            %{
              "sec" => 0,
              "para" => index,
              "page" => 0,
              "off_start" => 0,
              "off_end" => String.length(text)
            }
          end),
        "tables" => []
      }
    }
  end

  defp local_agent_context_texts(%Document{} = document) do
    %{"context" => %{"sections" => [%{"paragraphs" => paragraphs}]}} =
      document
      |> Document.metadata_paths()
      |> Map.fetch!(:context)
      |> File.read!()
      |> Jason.decode!()

    Enum.map(paragraphs, &Map.fetch!(&1, "text"))
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
  end

  defp cleanup_local_workspace_fixture do
    root = LocalWorkspaceAdapterStub.valid_path()

    for relative_path <- [
          "template.hwp",
          "employment_v1.hwp",
          "employment_v1 (1).hwp",
          "drafts/service.hwpx",
          "drafts/reference.docx",
          "imported-service.hwpx"
        ] do
      document_id = Document.id_for(root, relative_path)
      _ = Document.close(document_id)
    end

    File.rm_rf!(root)
  end
end
