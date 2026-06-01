defmodule Contract.Local.Document do
  @moduledoc """
  Local HWP/HWPX document runtime facade.

  The canonical document body is the mounted workspace file. The `.contract`
  tree stores only local metadata: snapshot copies, index JSON, and context
  JSON for the editor/agent layers that consume the local runtime.
  """

  alias Contract.Local.Document.Session
  alias Contract.Local.Document.Supervisor
  alias Contract.Local.Path, as: LocalPath

  @formats ~w(hwp hwpx)
  @hwp_content_type "application/x-hwp"
  @hwpx_content_type "application/vnd.hancom.hwpx"
  @hwp_min_byte_size 512

  @type format :: String.t()
  @type t :: %__MODULE__{
          id: String.t(),
          workspace_root: String.t(),
          relative_path: String.t(),
          path: String.t(),
          format: format(),
          revision: non_neg_integer(),
          byte_size: non_neg_integer(),
          sha256: String.t(),
          metadata_dir: String.t()
        }

  defstruct [
    :id,
    :workspace_root,
    :relative_path,
    :path,
    :format,
    :revision,
    :byte_size,
    :sha256,
    :metadata_dir
  ]

  @doc """
  Open a local `.hwp`/`.hwpx` file under `workspace_root`.

  `relative_path` must be a relative path inside the workspace. Opening starts
  or reuses the per-document local session and returns its current document
  state.
  """
  @spec open(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(workspace_root, relative_path, opts \\ []) do
    with {:ok, args} <- open_args(workspace_root, relative_path, opts),
         {:ok, pid} <- Supervisor.start_document(args) do
      Session.document(pid)
    end
  end

  @doc "Return current local session document state."
  @spec document(pid() | String.t() | t()) :: {:ok, t()} | {:error, term()}
  def document(target), do: Session.document(target)

  @doc "Read canonical bytes from the mounted workspace file."
  @spec read(pid() | String.t() | t()) :: {:ok, binary()} | {:error, term()}
  def read(target), do: Session.read(target)

  @doc "Write a local `.contract` snapshot without changing the canonical file."
  @spec checkpoint(pid() | String.t() | t(), binary(), map() | keyword()) ::
          {:ok, t(), map()} | {:error, term()}
  def checkpoint(target, bytes, attrs \\ %{}), do: Session.checkpoint(target, bytes, attrs)

  @doc "Atomically replace the canonical workspace file, then record a local snapshot."
  @spec save(pid() | String.t() | t(), binary(), map() | keyword()) ::
          {:ok, t(), map()} | {:error, term()}
  def save(target, bytes, attrs \\ %{}), do: Session.save(target, bytes, attrs)

  @doc "Record an editor mutation event without changing canonical bytes."
  @spec record_mutation(pid() | String.t() | t(), map()) :: {:ok, map()} | {:error, term()}
  def record_mutation(target, envelope), do: Session.record_mutation(target, envelope)

  @doc "Stop a local document session."
  @spec close(pid() | String.t() | t()) :: :ok | {:error, term()}
  def close(target), do: Session.close(target)

  @doc "Look up a running local document session."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(document_id), do: Session.whereis(document_id)

  @doc "Subscribe the caller to local document session events."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(document_id) when is_binary(document_id) do
    Phoenix.PubSub.subscribe(Contract.PubSub, topic(document_id))
  end

  @doc "PubSub topic for a local document session."
  @spec topic(String.t()) :: String.t()
  def topic(document_id) when is_binary(document_id), do: "local_document:#{document_id}"

  @doc false
  @spec open_args(String.t(), String.t(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def open_args(workspace_root, relative_path, opts \\ []) do
    with {:ok, root} <- normalize_workspace_root(workspace_root),
         {:ok, rel} <- LocalPath.normalize(relative_path),
         {:ok, path} <- LocalPath.join(root, rel),
         :ok <- ensure_regular_file(path),
         {:ok, bytes} <- File.read(path),
         {:ok, format} <- detect_format(path, bytes) do
      id = Keyword.get(opts, :id) || id_for(root, rel)

      {:ok,
       [
         id: id,
         workspace_root: root,
         relative_path: rel,
         path: path,
         format: format
       ]}
    end
  end

  @doc false
  @spec build(keyword(), binary(), non_neg_integer()) :: t()
  def build(args, bytes, revision) when is_list(args) and is_binary(bytes) do
    root = Keyword.fetch!(args, :workspace_root)
    id = Keyword.fetch!(args, :id)

    %__MODULE__{
      id: id,
      workspace_root: root,
      relative_path: Keyword.fetch!(args, :relative_path),
      path: Keyword.fetch!(args, :path),
      format: Keyword.fetch!(args, :format),
      revision: revision,
      byte_size: byte_size(bytes),
      sha256: sha256(bytes),
      metadata_dir: metadata_dir(root, id)
    }
  end

  @doc "Detect supported local document formats by extension or file magic."
  @spec detect_format(String.t(), binary() | nil) :: {:ok, format()} | {:error, term()}
  def detect_format(path_or_name, bytes \\ nil)

  def detect_format(path_or_name, nil) when is_binary(path_or_name) do
    case extension_format(path_or_name) do
      {:ok, format} -> {:ok, format}
      :unknown -> {:error, :unsupported_format}
    end
  end

  def detect_format(path_or_name, bytes) when is_binary(path_or_name) and is_binary(bytes) do
    with {:ok, format} <- detect_magic(bytes),
         :ok <- verify_extension_format(path_or_name, format) do
      {:ok, format}
    end
  end

  @spec normalize_format(String.t()) :: {:ok, format()} | {:error, term()}
  def normalize_format(format) when format in @formats, do: {:ok, format}

  def normalize_format(format) when is_binary(format) do
    format
    |> String.trim()
    |> String.trim_leading(".")
    |> String.downcase()
    |> case do
      value when value in @formats -> {:ok, value}
      _ -> {:error, :unsupported_format}
    end
  end

  def normalize_format(_format), do: {:error, :unsupported_format}

  @spec content_type(format()) :: String.t()
  def content_type("hwp"), do: @hwp_content_type
  def content_type("hwpx"), do: @hwpx_content_type

  @spec id_for(String.t(), String.t()) :: String.t()
  def id_for(workspace_root, relative_path)
      when is_binary(workspace_root) and is_binary(relative_path) do
    root = Path.expand(workspace_root)
    rel = relative_path |> Path.expand(root) |> Path.relative_to(root)

    hash =
      :crypto.hash(:sha256, root <> <<0>> <> rel)
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 32)

    "local-" <> hash
  end

  @spec metadata_dir(String.t(), String.t()) :: String.t()
  def metadata_dir(workspace_root, document_id) do
    workspace_root
    |> Path.join(".contract")
    |> Path.join("documents")
    |> Path.join(document_id)
  end

  @spec metadata_paths(t()) :: map()
  def metadata_paths(%__MODULE__{} = document) do
    metadata_root = Path.join(document.workspace_root, ".contract")

    %{
      document: Path.join([metadata_root, "documents", "#{document.id}.json"]),
      index: Path.join([metadata_root, "indexes", "document-#{document.id}.json"]),
      context: Path.join([metadata_root, "contexts", "#{document.id}.json"]),
      mutations: Path.join([metadata_root, "operations", "document-#{document.id}.jsonl"]),
      snapshots: Path.join([metadata_root, "snapshots", document.id])
    }
  end

  @spec sha256(binary()) :: String.t()
  def sha256(bytes) when is_binary(bytes) do
    :crypto.hash(:sha256, bytes)
    |> Base.encode16(case: :lower)
  end

  defp normalize_workspace_root(root) when is_binary(root) and root != "" do
    root = Path.expand(root)

    if File.dir?(root) do
      {:ok, root}
    else
      {:error, :workspace_not_found}
    end
  end

  defp normalize_workspace_root(_root), do: {:error, :invalid_workspace_root}

  defp ensure_regular_file(path) do
    if File.regular?(path), do: :ok, else: {:error, :not_found}
  end

  defp extension_format(path_or_name) do
    case path_or_name |> Path.extname() |> String.downcase() do
      ".hwp" -> {:ok, "hwp"}
      ".hwpx" -> {:ok, "hwpx"}
      _ -> :unknown
    end
  end

  defp verify_extension_format(path_or_name, format) do
    case extension_format(path_or_name) do
      {:ok, ^format} -> :ok
      {:ok, _other} -> {:error, :unsupported_format}
      :unknown -> :ok
    end
  end

  defp detect_magic(<<0xD0, 0xCF, 0x11, 0xE0, _::binary>> = bytes)
       when byte_size(bytes) >= @hwp_min_byte_size,
       do: {:ok, "hwp"}

  defp detect_magic(<<"PK", _::binary>> = bytes), do: detect_hwpx_zip(bytes)
  defp detect_magic(_bytes), do: {:error, :unsupported_format}

  defp detect_hwpx_zip(bytes) do
    case :zip.table(bytes) do
      {:ok, entries} ->
        if Enum.any?(entries, &zip_entry_name?(&1, "Contents/header.xml")) do
          {:ok, "hwpx"}
        else
          {:error, :unsupported_format}
        end

      {:error, _reason} ->
        {:error, :unsupported_format}
    end
  end

  defp zip_entry_name?({:zip_file, name, _info, _comment, _offset, _compressed_size}, expected),
    do: to_string(name) == expected

  defp zip_entry_name?(_entry, _expected), do: false
end
