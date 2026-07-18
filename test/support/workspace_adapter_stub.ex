defmodule EcritsWeb.WorkspaceAdapterStub do
  @behaviour EcritsWeb.Workspace.Adapter

  @valid_path "/tmp/ecrits-ui"

  def valid_path,
    do: Application.get_env(:ecrits, :workspace_adapter_stub_path, @valid_path)

  @impl true
  def mount(path) do
    if path == valid_path() do
      {:ok,
       %{
         root_path: path,
         title: Path.basename(path),
         tree: tree()
       }}
    else
      {:error, {:invalid_path, "Workspace path does not exist."}}
    end
  end

  @impl true
  def list_tree(%{tree: tree}, _expanded_paths), do: {:ok, tree}

  def tree do
    [
      %{type: :directory, name: "Assignment #2", path: "Assignment #2", children: []},
      %{type: :file, name: "template.hwpx", path: "template.hwpx"},
      %{type: :file, name: "Antigravity.dmg", path: "Antigravity.dmg"},
      %{
        type: :directory,
        name: "drafts",
        path: "drafts",
        children: [
          %{type: :file, name: "service.hwpx", path: "drafts/service.hwpx"},
          %{type: :file, name: "reference.docx", path: "drafts/reference.docx"},
          %{type: :file, name: "ledger.xlsx", path: "drafts/ledger.xlsx"}
        ]
      },
      %{
        type: :directory,
        name: "rulebook.md",
        path: "rulebook.md",
        children: [
          %{
            type: :directory,
            name: "acceptance_certificate",
            path: "rulebook.md/acceptance_certificate",
            children: [
              %{
                type: :file,
                name: "acceptance_certificate.md",
                path: "rulebook.md/acceptance_certificate/acceptance_certificate.md"
              }
            ]
          }
        ]
      }
    ]
  end
end
