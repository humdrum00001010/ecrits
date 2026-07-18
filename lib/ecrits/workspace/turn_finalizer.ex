defmodule Ecrits.Workspace.TurnFinalizer do
  @moduledoc """
  Persists document work that may still be pending when an agent turn ends.

  `Ecrits.Workspace.Session` invokes this module after it has atomically claimed
  a terminal turn. Keeping the claim in the durable workspace coordinator means
  simultaneous LiveViews can all render the terminal event without saving the
  same document or flushing the same mounted projection more than once.
  """

  require Logger

  alias Ecrits.Doc.Editor, as: DocEditor
  alias Ecrits.Doc.Pool, as: DocPool
  alias Ecrits.Fuse.DocFs
  alias Ecrits.Fuse.OpenDocs

  @type result :: %{
          saved: [String.t()],
          failed: [{String.t(), term()}],
          staged: %{
            committed: [String.t()],
            rejected: [{String.t(), term()}],
            pending: [{String.t(), term()}]
          },
          canonical: %{published: [String.t()], pending: [{String.t(), term()}]}
        }

  @spec run(String.t(), keyword()) :: result()
  def run(workspace_path, opts \\ []) when is_binary(workspace_path) and is_list(opts) do
    case turn_owner(opts) do
      {:error, reason} ->
        %{
          saved: [],
          failed: [{workspace_path, reason}],
          staged: %{committed: [], rejected: [], pending: []},
          canonical: %{published: [], pending: []}
        }

      write_owner ->
        run_scoped(workspace_path, opts, write_owner)
    end
  end

  defp run_scoped(workspace_path, opts, write_owner) do
    pool = Keyword.get(opts, :pool, DocPool)

    projection_opts =
      Keyword.take(opts, [
        :agent_id,
        :instance_id,
        :turn_id,
        :mounted?,
        :echo_fun,
        :remount?,
        :remount_fun
      ])

    # A staged ACP buffer first mutates the live editor. Save that mutation to
    # the native document before publishing its canonical projection through a
    # fresh mounted vnode.
    staged = flush_staged(workspace_path, projection_opts)

    {saved, failed} =
      case dirty_docs_in_workspace(workspace_path, pool) do
        {:ok, docs} ->
          Enum.reduce(docs, {[], []}, fn doc, {paths, failures} ->
            case save_doc(doc, write_owner) do
              :ok -> {[doc.path | paths], failures}
              :skipped -> {paths, failures}
              {:error, reason} -> {paths, [{doc.path, reason} | failures]}
            end
          end)

        {:error, reason} ->
          {[], [{workspace_path, reason}]}
      end

    saved = Enum.reverse(saved)
    failed = Enum.reverse(failed)

    canonical = flush_canonical_after_save(workspace_path, projection_opts, failed)

    clear_durable_dirty_owners(
      workspace_path,
      projection_opts,
      failed,
      staged,
      canonical
    )

    %{
      saved: saved,
      failed: failed,
      staged: staged,
      canonical: canonical
    }
  end

  defp dirty_docs_in_workspace(workspace_path, pool) do
    docs =
      pool
      |> DocPool.dirty_docs()
      |> Enum.filter(&Ecrits.Path.inside?(workspace_path, &1.path))

    {:ok, docs}
  rescue
    error ->
      Logger.warning("turn finalizer: dirty_docs enumeration failed: #{inspect(error)}")
      {:error, {:dirty_docs_exception, Exception.message(error)}}
  catch
    :exit, reason ->
      Logger.warning("turn finalizer: dirty_docs enumeration exited: #{inspect(reason)}")
      {:error, {:dirty_docs_exit, reason}}
  end

  defp save_doc(%{editor: editor} = doc, nil) do
    save_doc_result(doc, fn opts -> DocEditor.save(editor, opts) end)
  end

  defp save_doc(%{editor: editor} = doc, owner) when is_map(owner) do
    snapshot = DocEditor.dirty_snapshot(editor)

    case DocEditor.owner_status(snapshot, owner) do
      :exclusive ->
        save_doc_result(doc, fn opts -> DocEditor.save_if_owner(editor, snapshot, opts) end)

      :mixed ->
        {:error, :mixed_unsaved_writers}

      status when status in [:clean, :other] ->
        :skipped
    end
  end

  defp save_doc_result(%{kind: kind, path: path}, save) do
    case save.(format: save_format(kind), path: path) do
      :ok ->
        Logger.info("turn finalizer: persisted dirty doc to #{path}")
        :ok

      {:ok, _value} ->
        Logger.info("turn finalizer: persisted dirty doc to #{path}")
        :ok

      {:error, reason} ->
        Logger.warning("turn finalizer: failed to persist #{path}: #{inspect(reason)}")
        {:error, reason}

      {:skipped, :clean} ->
        :skipped

      {:skipped, :owner_changed} ->
        {:error, :owner_changed}
    end
  rescue
    error ->
      Logger.warning("turn finalizer: exception persisting doc: #{inspect(error)}")
      {:error, {:exception, Exception.message(error)}}
  catch
    :exit, reason ->
      Logger.warning("turn finalizer: editor exited while persisting: #{inspect(reason)}")
      {:error, {:exit, reason}}
  end

  defp turn_owner(opts) do
    keys = [:agent_id, :instance_id, :turn_id]

    if Enum.any?(keys, &Keyword.has_key?(opts, &1)) do
      owner = Map.new(keys, &{&1, Keyword.get(opts, &1)})

      if Enum.all?(Map.values(owner), &(is_binary(&1) and &1 != "")) do
        owner
      else
        {:error, :incomplete_turn_identity}
      end
    end
  end

  defp save_format(kind) when kind in [:hwp, :hwpx, :docx, :pptx, :xlsx], do: kind
  defp save_format(_kind), do: :hwp

  if Mix.env() == :test do
    @doc false
    def __save_format_for_test__(kind), do: save_format(kind)
  end

  defp clear_durable_dirty_owners(workspace_path, opts, failed, staged, canonical) do
    failed_paths = MapSet.new(Enum.map(failed, &elem(&1, 0)))

    pending_names =
      staged.pending
      |> Enum.map(&elem(&1, 0))
      |> Kernel.++(Enum.map(canonical.pending, &elem(&1, 0)))
      |> MapSet.new()

    unless MapSet.member?(failed_paths, workspace_path) do
      workspace_path
      |> OpenDocs.dirty_owner_entries(opts)
      |> Enum.each(fn entry ->
        source_path = Map.get(entry, :source_path)

        if not MapSet.member?(failed_paths, source_path) and
             not MapSet.member?(pending_names, entry.name) do
          _ = OpenDocs.clear_dirty_owner(workspace_path, entry.name, entry)
        end
      end)
    end
  end

  defp flush_staged(workspace_path, opts) do
    DocFs.flush_staged(workspace_path, opts)
  rescue
    error ->
      Logger.warning("turn finalizer: staged projection flush failed: #{inspect(error)}")
      %{committed: [], rejected: [], pending: [{workspace_path, error}]}
  catch
    :exit, reason ->
      Logger.warning("turn finalizer: staged projection flush exited: #{inspect(reason)}")
      %{committed: [], rejected: [], pending: [{workspace_path, reason}]}
  end

  defp flush_canonical(workspace_path, opts) do
    DocFs.flush_canonical(workspace_path, opts)
  rescue
    error ->
      Logger.warning("turn finalizer: canonical projection flush failed: #{inspect(error)}")
      %{published: [], pending: [{workspace_path, error}]}
  catch
    :exit, reason ->
      Logger.warning("turn finalizer: canonical projection flush exited: #{inspect(reason)}")
      %{published: [], pending: [{workspace_path, reason}]}
  end

  defp flush_canonical_after_save(workspace_path, opts, []),
    do: flush_canonical(workspace_path, opts)

  defp flush_canonical_after_save(workspace_path, opts, failed) do
    filters = Keyword.take(opts, [:agent_id, :instance_id, :turn_id])

    pending =
      (OpenDocs.in_flight_canonical_entries(workspace_path, filters) ++
         OpenDocs.pending_canonical_entries(workspace_path, filters))
      |> Enum.uniq_by(& &1.name)
      |> Enum.map(fn entry ->
        reason =
          case Enum.find(failed, fn {path, _reason} -> path == Map.get(entry, :source_path) end) do
            {_path, reason} -> {:native_save_failed, reason}
            nil -> {:native_save_blocked, failed}
          end

        {entry.name, reason}
      end)

    Logger.warning(
      "turn finalizer: canonical publication deferred after native save failure: #{inspect(failed)}"
    )

    %{published: [], pending: pending}
  end
end
