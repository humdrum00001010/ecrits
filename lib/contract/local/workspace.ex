defmodule Contract.Local.Workspace do
  @moduledoc """
  Local workspace facade over safe path and metadata primitives.
  """

  alias Contract.Local.FS
  alias Contract.Local.Metadata
  alias Contract.Local.SnapshotStore

  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}

  @doc """
  Initialize a workspace root and its hidden metadata directory.
  """
  @spec init(String.t()) :: {:ok, t()} | {:error, term()}
  def init(root) when is_binary(root) do
    root = Path.expand(root)

    with :ok <- File.mkdir_p(root),
         :ok <- Metadata.ensure(root) do
      {:ok, %__MODULE__{root: root}}
    end
  end

  @doc """
  Build a workspace struct without creating directories.
  """
  @spec new(String.t()) :: t()
  def new(root) when is_binary(root), do: %__MODULE__{root: Path.expand(root)}

  @doc """
  Return supervision children for a local workspace when a root is configured.
  """
  @spec children(keyword()) :: [Supervisor.child_spec()]
  def children(opts) when is_list(opts) do
    case Keyword.fetch(opts, :root) do
      {:ok, root} when is_binary(root) -> [{Contract.Local.Workspace.Server, opts}]
      _ -> []
    end
  end

  @spec list(t() | String.t(), String.t()) :: {:ok, [FS.entry()]} | {:error, term()}
  def list(workspace_or_root, relative \\ ".")
  def list(%__MODULE__{root: root}, relative), do: FS.list(root, relative)
  def list(root, relative) when is_binary(root), do: FS.list(root, relative)

  @spec read_file(t() | String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%__MODULE__{root: root}, relative), do: FS.read(root, relative)
  def read_file(root, relative) when is_binary(root), do: FS.read(root, relative)

  @spec write_file(t() | String.t(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def write_file(workspace_or_root, relative, contents, opts \\ [])

  def write_file(%__MODULE__{root: root}, relative, contents, opts),
    do: FS.write(root, relative, contents, opts)

  def write_file(root, relative, contents, opts) when is_binary(root),
    do: FS.write(root, relative, contents, opts)

  @doc """
  Capture current file contents before saving over them.
  """
  @spec checkpoint(t() | String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def checkpoint(workspace_or_root, relative, attrs \\ %{})

  def checkpoint(%__MODULE__{root: root}, relative, attrs),
    do: SnapshotStore.checkpoint(root, relative, attrs)

  def checkpoint(root, relative, attrs) when is_binary(root),
    do: SnapshotStore.checkpoint(root, relative, attrs)
end
