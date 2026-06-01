defmodule ContractWeb.LocalWorkspaceAdapterStub do
  @behaviour ContractWeb.Local.WorkspaceAdapter

  @valid_path "/tmp/contract-local-ui"

  def valid_path, do: @valid_path

  @impl true
  def mount(@valid_path) do
    {:ok,
     %{
       root_path: @valid_path,
       title: "contract-local-ui",
       tree: tree()
     }}
  end

  def mount(_path), do: {:error, {:invalid_path, "Workspace path does not exist."}}

  @impl true
  def list_tree(%{tree: tree}, _expanded_paths), do: {:ok, tree}

  def tree do
    [
      %{
        type: :directory,
        name: ".contract",
        path: ".contract",
        metadata?: true,
        children: [
          %{type: :file, name: "local.json", path: ".contract/local.json"}
        ]
      },
      %{type: :directory, name: "Assignment #2", path: "Assignment #2", children: []},
      %{type: :file, name: "template.hwp", path: "template.hwp"},
      %{type: :file, name: "Antigravity.dmg", path: "Antigravity.dmg"},
      %{
        type: :directory,
        name: "drafts",
        path: "drafts",
        children: [
          %{type: :file, name: "service.hwpx", path: "drafts/service.hwpx"},
          %{type: :file, name: "reference.docx", path: "drafts/reference.docx"}
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
