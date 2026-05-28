defmodule Contract.Projects do
  @moduledoc """
  Owner-scoped project API.

  Projects are a lightweight layer above documents. Documents keep their own
  ownership and lifecycle; project membership lives in `project_documents`.
  """

  import Ecto.Query

  alias Contract.Context
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.Projects.Project
  alias Contract.Projects.ProjectDocument
  alias Contract.Repo
  alias Contract.Types, as: T

  @doc """
  List projects owned by the scope user.
  """
  @spec list_projects_for_scope(Context.t()) :: [Project.t()]
  def list_projects_for_scope(%Context{user: nil}), do: []

  def list_projects_for_scope(%Context{user: %{id: user_id}}) do
    from(p in Project,
      where: p.owner_id == ^user_id,
      order_by: [desc: p.updated_at]
    )
    |> Repo.all()
  end

  def list_projects_for_scope(_scope), do: []

  @doc """
  Fetch one project and preload linked documents.
  """
  @spec get_project(Context.t(), T.id()) ::
          {:ok, Project.t()} | {:error, :not_found | :forbidden}
  def get_project(%Context{} = scope, project_id) when is_binary(project_id) do
    with {:ok, project} <- get_owned_project(scope, project_id) do
      {:ok, preload_project(project)}
    end
  end

  def get_project(_scope, _project_id), do: {:error, :not_found}

  @doc """
  Create a project owned by `ctx.user`.
  """
  @spec create_project(Context.t(), map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def create_project(%Context{user: nil}, _attrs), do: {:error, :forbidden}

  def create_project(%Context{user: %{id: user_id}}, attrs) when is_map(attrs) do
    %Project{owner_id: user_id}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  def create_project(_scope, _attrs), do: {:error, :forbidden}

  @doc """
  Update an owned project.
  """
  @spec update_project(Context.t(), Project.t(), map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def update_project(%Context{} = scope, %Project{} = project, attrs) when is_map(attrs) do
    with :ok <- authorize_owner(scope, project) do
      project
      |> Project.changeset(attrs)
      |> Repo.update()
    end
  end

  def update_project(_scope, _project, _attrs), do: {:error, :forbidden}

  @doc """
  Attach one owned document to one owned project.

  Re-attaching the same document returns the existing join row.
  """
  @spec attach_document(Context.t(), T.id(), T.id(), map()) ::
          {:ok, ProjectDocument.t()} | {:error, term()}
  def attach_document(scope, project_id, document_id, attrs \\ %{})

  def attach_document(%Context{user: nil}, _project_id, _document_id, _attrs),
    do: {:error, :forbidden}

  def attach_document(%Context{} = scope, project_id, document_id, attrs)
      when is_binary(project_id) and is_binary(document_id) and is_map(attrs) do
    with {:ok, %Project{} = project} <- get_owned_project(scope, project_id),
         {:ok, %Document{} = document} <- Documents.get(scope, document_id) do
      case get_project_document(project.id, document.id) do
        %ProjectDocument{} = project_document ->
          {:ok, project_document}

        nil ->
          %ProjectDocument{project_id: project.id, document_id: document.id}
          |> ProjectDocument.changeset(attrs)
          |> Repo.insert()
      end
    end
  end

  def attach_document(_scope, _project_id, _document_id, _attrs), do: {:error, :not_found}

  @doc """
  Detach a document from an owned project. Missing membership is already detached.
  """
  @spec detach_document(Context.t(), T.id(), T.id()) :: :ok | {:error, term()}
  def detach_document(%Context{} = scope, project_id, document_id)
      when is_binary(project_id) and is_binary(document_id) do
    with {:ok, %Project{} = project} <- get_owned_project(scope, project_id) do
      from(pd in ProjectDocument,
        where: pd.project_id == ^project.id and pd.document_id == ^document_id
      )
      |> Repo.delete_all()

      :ok
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def detach_document(_scope, _project_id, _document_id), do: {:error, :not_found}

  @doc """
  List owned documents not already attached to the project.
  """
  @spec list_available_documents(Context.t(), T.id()) :: [Document.t()]
  def list_available_documents(%Context{user: nil}, _project_id), do: []

  def list_available_documents(%Context{user: %{id: user_id}} = scope, project_id)
      when is_binary(project_id) do
    with {:ok, %Project{} = project} <- get_owned_project(scope, project_id) do
      attached_document_ids =
        from(pd in ProjectDocument,
          where: pd.project_id == ^project.id,
          select: pd.document_id
        )

      from(d in Document,
        where: d.owner_id == ^user_id,
        where: d.id not in subquery(attached_document_ids),
        order_by: [desc: d.updated_at]
      )
      |> Repo.all()
    else
      _ -> []
    end
  rescue
    Ecto.Query.CastError -> []
  end

  def list_available_documents(_scope, _project_id), do: []

  defp get_owned_project(%Context{} = scope, project_id) do
    case fetch_project(project_id) do
      nil ->
        {:error, :not_found}

      %Project{} = project ->
        case authorize_owner(scope, project) do
          :ok -> {:ok, project}
          err -> err
        end
    end
  end

  defp fetch_project(project_id) when is_binary(project_id) do
    Repo.get(Project, project_id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp fetch_project(_project_id), do: nil

  defp preload_project(%Project{} = project) do
    Repo.preload(project, [:documents, project_documents: :document])
  end

  defp get_project_document(project_id, document_id) do
    Repo.one(
      from(pd in ProjectDocument,
        where: pd.project_id == ^project_id and pd.document_id == ^document_id
      )
    )
  end

  defp authorize_owner(%Context{user: %{id: user_id}}, %Project{owner_id: owner_id})
       when owner_id == user_id,
       do: :ok

  defp authorize_owner(_scope, _project), do: {:error, :forbidden}
end
