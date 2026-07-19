defmodule Ecrits.Fuse.DocFs do
  @moduledoc """
  `exfuse` filesystem that projects the workspace documents the agent has OPENED
  (via the `doc.open_doc` MCP tool) as a flat directory of JSONL IR files. The
  open set lives in `Ecrits.Fuse.OpenDocs` (per-workspace ETS); a doc appears as
  `<mount-name>.jsonl` only while it is open, and the projection bytes come from
  `Ecrits.Doc.Projection.project_file/1`. Each projected file is one nested JSONL
  value: sections -> paragraphs -> editable native IR payload nodes.

  Writable: a write to a projected file is a **file-level modification of the
  document** — on commit it routes back onto the live document via
  `Ecrits.Doc.Projection.write_back/3`, which applies the change straight to the
  server document model (NOT the `doc.edit` MCP tool). So editing the mounted
  `.jsonl` IS editing the document.

  The mount behaves like a real file that an in-place editor / linter
  (`sed -i`, a formatter) can rewrite. Two write patterns are supported:

    * **in-place** — `open`/`truncate`/`write` the projected file, commit as soon
      as the buffered projected JSON becomes valid, with `release` as the final
      safety commit;
    * **atomic temp+rename** (what most linters do) — `create` a transient file
      inside this mounted directory, `write` it, then `rename` it over the
      projected `<doc>.jsonl`; the `rename` commits the temp's bytes via
      `write_back`.

  Incomplete JSON buffers may be staged so editor/linter recovery can finish a
  later whole-file rewrite. Complete JSON values with the wrong projection shape
  (for example, a single payload object instead of the nested document list)
  fail instead of replacing the mounted truth. Only a buffer that was actually
  WRITTEN commits: a read-only `cat`/`open` seeds a buffer but is never dirty, so
  it never writes back (critical — otherwise a stale read seed would revert a
  concurrent rename). A write is gated on the workspace access policy
  (`OpenDocs.writable?/1`) → `:erofs` when read-only.

  Handlers touch only ETS (`OpenDocs`) and `Projection` (which reads/writes the
  doc via the Pool/Editor) — never the BEAM `:file_server`, which a VFS handler
  must avoid (an in-BEAM `File.*` on the mount would deadlock it). See
  `docs/plans/2026-06-23-exfuse-doc-vfs-migration.md`.
  """

  use Exfuse.Fs

  require Logger

  alias Ecrits.Doc.Projection
  alias Ecrits.Fuse.DocMount
  alias Ecrits.Fuse.OpenDocs

  @projected_attr_size_floor 64 * 1024 * 1024

  @doc """
  Try to flush staged VFS JSONL buffers for `root`.

  The chat rail calls this at agent turn completion. Normal valid writes still
  commit synchronously on `release`/`rename`; this hook catches linter/editor
  workflows that left an intermediate staged buffer during the turn. A buffer
  that remains invalid here has crossed its correction boundary, so this hook
  rejects only the exact staged generation it inspected; a newer edit is never
  removed by the old turn's terminal worker.
  """
  @spec flush_staged(String.t(), keyword()) :: %{
          committed: [String.t()],
          rejected: [{String.t(), term()}],
          pending: [{String.t(), term()}]
        }
  def flush_staged(root, opts \\ []) when is_binary(root) and is_list(opts) do
    root = DocMount.canonical_root(root)
    filters = Keyword.take(opts, [:agent_id, :instance_id, :turn_id])

    root
    |> OpenDocs.staged_with_identity()
    |> Enum.filter(fn {_name, _bytes, _reason, identity} ->
      staged_identity_matches?(identity, filters)
    end)
    |> Enum.reduce(%{committed: [], rejected: [], pending: []}, fn
      {name, bytes, previous_reason, identity}, acc ->
        cond do
          not OpenDocs.member?(root, name) ->
            settle_staged_cleanup(
              acc,
              root,
              name,
              bytes,
              previous_reason,
              identity,
              filters,
              :document_closed
            )

          not match?({:ok, _source}, OpenDocs.source_path(root, name)) ->
            settle_staged_cleanup(
              acc,
              root,
              name,
              bytes,
              previous_reason,
              identity,
              filters,
              :source_missing
            )

          not source_supported?(root, name) ->
            settle_staged_cleanup(
              acc,
              root,
              name,
              bytes,
              previous_reason,
              identity,
              filters,
              :source_unsupported
            )

          true ->
            {:ok, source} = OpenDocs.source_path(root, name)
            OpenDocs.clear_write_failure(root, name)

            case write_back_unless_accepted(
                   root,
                   source,
                   name,
                   bytes,
                   Keyword.put(identity_opts(identity), :root, root)
                 ) do
              {:ok, %{accepted_noop: true}} ->
                settle_staged_commit(
                  acc,
                  root,
                  name,
                  bytes,
                  previous_reason,
                  identity,
                  filters,
                  :discard,
                  :accepted_noop
                )

              {:ok, _info} ->
                settlement =
                  accepted_projection_settlement(source, bytes, identity)

                disposition =
                  settle_staged_snapshot(
                    root,
                    name,
                    bytes,
                    previous_reason,
                    identity,
                    filters,
                    settlement
                  )

                acc
                |> Map.update!(:committed, &[name | &1])
                |> maybe_mark_replaced_stage_pending(name, disposition, :accepted_write)

              {:error, reason} ->
                record_write_failure(root, name, reason)

                if terminal_rejectable_staged_error?(reason) do
                  case settle_staged_snapshot(
                         root,
                         name,
                         bytes,
                         previous_reason,
                         identity,
                         filters,
                         :discard
                       ) do
                    :discarded ->
                      broadcast_preview_rejected(root, source, name, identity || %{}, reason)
                      Map.update!(acc, :rejected, &[{name, reason} | &1])

                    :same_owner_replaced ->
                      maybe_mark_replaced_stage_pending(
                        acc,
                        name,
                        :same_owner_replaced,
                        reason
                      )

                    :other_owner_or_gone ->
                      broadcast_preview_rejected(root, source, name, identity || %{}, reason)
                      Map.update!(acc, :rejected, &[{name, reason} | &1])
                  end
                else
                  Logger.warning(
                    "[DocFs] staged write_back still pending for #{Path.join(root, name)}: #{inspect(reason)}"
                  )

                  case settle_staged_snapshot(
                         root,
                         name,
                         bytes,
                         previous_reason,
                         identity,
                         filters,
                         :retain
                       ) do
                    :retained ->
                      Map.update!(acc, :pending, &[{name, reason} | &1])

                    :same_owner_replaced ->
                      maybe_mark_replaced_stage_pending(
                        acc,
                        name,
                        :same_owner_replaced,
                        reason
                      )

                    :other_owner_or_gone ->
                      acc
                  end
                end
            end
        end
    end)
    |> Map.update!(:committed, &Enum.reverse/1)
    |> Map.update!(:rejected, &Enum.reverse/1)
    |> Map.update!(:pending, &Enum.reverse/1)
  end

  @doc """
  Publish canonical engine projections at a fresh FSKit vnode boundary.

  Successful user renames remain byte-preserving for the rest of their ACP
  turn. At the terminal boundary this function writes each separately staged
  canonical value to a unique mounted sibling, fsyncs and closes it, then
  renames that fresh source vnode over the projected target. The DocFs handler
  recognizes the registered echo and never routes it back through semantic
  write-back or preview playback.
  """
  @spec flush_canonical(String.t(), keyword()) :: %{
          published: [String.t()],
          pending: [{String.t(), term()}]
        }
  def flush_canonical(root, opts \\ []) when is_binary(root) and is_list(opts) do
    root = DocMount.canonical_root(root)
    filters = Keyword.take(opts, [:agent_id, :instance_id, :turn_id])

    # A killed terminal worker can leave its monitor DOWN queued behind this
    # retry. Reclaim the already-dead publisher synchronously so its restored
    # pending value participates in this very flush instead of being stranded
    # after an apparent no-op success.
    _reclaimed = OpenDocs.reclaim_dead_canonical_echoes(root, filters)

    resolution =
      root
      |> OpenDocs.in_flight_canonical_entries(filters)
      |> Enum.reduce(%{published: [], pending: []}, fn entry, acc ->
        case resolve_in_flight_canonical(root, entry, filters, opts) do
          :ok -> acc
          {:error, reason} -> Map.update!(acc, :pending, &[{entry.name, reason} | &1])
        end
      end)

    root
    |> OpenDocs.pending_canonical_entries(filters)
    |> Enum.reduce(resolution, fn entry, acc ->
      case publish_pending_canonical(root, entry, opts) do
        :ok -> Map.update!(acc, :published, &[entry.name | &1])
        {:error, reason} -> Map.update!(acc, :pending, &[{entry.name, reason} | &1])
      end
    end)
    |> Map.update!(:published, &Enum.reverse/1)
    |> Map.update!(:pending, &Enum.reverse/1)
  end

  init do
    Map.update!(opts, :root, &DocMount.canonical_root/1)
  end

  readdir "/" do
    opened = OpenDocs.list(state.root)

    names =
      opened
      |> Enum.filter(&source_supported?(state.root, &1))
      |> Enum.map(&{Projection.projected_name(&1), attr(type: :file)})

    {:reply, names, socket}
  end

  getattr "/" do
    {mtime, socket} = content_mtime(socket, "/", Enum.sort(OpenDocs.list(state.root)))
    {:reply, attr(type: :dir, mtime: mtime), socket}
  end

  getattr "/:name" do
    cond do
      is_binary(name_buffer(socket, name)) ->
        buf = name_buffer(socket, name)
        {mtime, socket} = content_mtime(socket, name, buf)
        {:reply, attr(type: :file, size: byte_size(buf), mtime: mtime), socket}

      match?({:ok, _}, source_path(state.root, name)) ->
        {size, mtime, socket} = projected_attrs(socket, state.root, name)
        {:reply, attr(type: :file, size: size, mtime: mtime), socket}

      true ->
        {:error, :enoent, socket}
    end
  end

  read "/:name" do
    cond do
      match?({:ok, _}, source_path(state.root, name)) ->
        case projected_bytes(state.root, name) do
          {:ok, bytes} -> {:reply, slice(bytes, event.offset, event.size), socket}
          {:error, _reason} -> {:error, :eio, socket}
        end

      is_binary(name_buffer(socket, name)) ->
        {:reply, slice(name_buffer(socket, name), event.offset, event.size), socket}

      true ->
        {:error, :enoent, socket}
    end
  end

  open "/:name" do
    cond do
      match?({:ok, _}, source_path(state.root, name)) ->
        {handle, socket} = new_handle(socket, name)
        {:reply, handle, socket}

      buffered_name?(socket, name) ->
        {handle, socket} = new_handle(socket, name)
        {:reply, handle, socket}

      true ->
        {:error, :enoent, socket}
    end
  end

  # A new file in the mount — an in-place editor's temp file. Register a
  # transient (sourceless) buffer; it commits only when renamed over a projected
  # doc. VFS `create` is create+open, so no separate `open` follows.
  create "/:name" do
    internal_echo? = OpenDocs.canonical_echo_temp?(state.root, name)

    cond do
      canonical_temp_name?(name) and not internal_echo? ->
        {:error, :eio, socket}

      not OpenDocs.writable?(state.root) and not internal_echo? ->
        {:error, :erofs, socket}

      true ->
        {handle, socket} = new_handle(socket, name)

        socket =
          if internal_echo? do
            socket
          else
            {_identity, socket} = ensure_edit_identity(socket, state.root, name)
            socket
          end

        {:reply, handle, put_buf(socket, handle_key(handle), "")}
    end
  end

  write "/:name" do
    internal_echo? = OpenDocs.canonical_echo_temp?(state.root, name)

    cond do
      canonical_temp_name?(name) and not internal_echo? ->
        {:error, :eio, socket}

      not OpenDocs.writable?(state.root) and not internal_echo? ->
        {:error, :erofs, socket}

      not target_known?(state.root, socket, name) ->
        {:error, :enoent, socket}

      true ->
        key = event_key(event, name)

        socket =
          if internal_echo? do
            socket
          else
            {_identity, socket} = ensure_edit_identity(socket, state.root, name)
            socket
          end

        {buf, socket} = ensure_buf(socket, state.root, name, key)

        next_buf = splice(buf, event.offset, event.data)

        socket =
          socket
          |> put_buf(key, next_buf)
          |> mark_dirty(key)

        socket =
          if internal_echo? do
            socket
          else
            socket
            # Preview every valid primary-surface buffer before it mutates the
            # authoritative document. A normal in-place rewrite is just as much
            # a VFS edit as temp+rename, so withholding its rail playback would
            # make the visible result depend on the editor's save strategy.
            |> maybe_preview_buffer(state.root, name, next_buf)
            |> maybe_commit_live_buffer(state.root, name, key, next_buf)
          end

        {:reply, byte_size(event.data), socket}
    end
  end

  truncate "/:name" do
    internal_echo? = OpenDocs.canonical_echo_temp?(state.root, name)

    cond do
      canonical_temp_name?(name) and not internal_echo? ->
        {:error, :eio, socket}

      not OpenDocs.writable?(state.root) and not internal_echo? ->
        {:error, :erofs, socket}

      not target_known?(state.root, socket, name) ->
        {:error, :enoent, socket}

      true ->
        socket =
          if internal_echo? do
            socket
          else
            {_identity, socket} = ensure_edit_identity(socket, state.root, name)
            socket
          end

        {:noreply, truncate_buffers(socket, state.root, name, event.size)}
    end
  end

  chmod "/:name" do
    cond do
      canonical_temp_name?(name) and
          not OpenDocs.canonical_echo_temp?(state.root, name) ->
        {:error, :eio, socket}

      not OpenDocs.writable?(state.root) and
          not OpenDocs.canonical_echo_temp?(state.root, name) ->
        {:error, :erofs, socket}

      not target_known?(state.root, socket, name) ->
        {:error, :enoent, socket}

      true ->
        {:noreply, socket}
    end
  end

  # Some VFS backends can call flush before a large full-file rewrite has reached
  # a valid whole JSON value. Commit on release instead; it is the final close
  # for the handle. Transient temp files also survive flush so temp+rename
  # editors work.
  flush "/:_name" do
    {:noreply, socket}
  end

  # Atomic in-place edit: a tool wrote a temp file and renames it over the
  # projected `<doc>.jsonl`. Commit the temp's bytes to the document and drop both
  # buffers (the target's seed is now stale). A rename to a non-doc name (a
  # backup) just moves the buffer.
  rename "/:name" do
    target = event |> Map.get(:target) |> to_string() |> Path.basename()
    buf = name_buffer(socket, name) || ""

    case OpenDocs.canonical_echo(state.root, name) do
      {:ok, %{name: echo_target}} ->
        result =
          if target == Projection.projected_name(echo_target) do
            OpenDocs.complete_canonical_echo(state.root, name, echo_target, buf)
          else
            {:error, :wrong_target}
          end

        case result do
          :ok ->
            {:noreply, socket |> clear_name(name) |> clear_name(target)}

          {:error, reason} ->
            Logger.warning(
              "[DocFs] rejected stale canonical echo #{name} -> #{target}: #{inspect(reason)}"
            )

            OpenDocs.cancel_canonical_echo(state.root, name)
            {:error, :eio, socket}
        end

      :error ->
        cond do
          canonical_temp_name?(name) ->
            {:error, :eio, socket}

          not OpenDocs.writable?(state.root) ->
            {:error, :erofs, reject_atomic_rename(socket, state.root, name, target, :erofs)}

          match?({:ok, _}, source_path(state.root, target)) ->
            {:ok, target_source} = source_path(state.root, target)
            target_name = mounted_source_name(target)
            {identity, socket} = ensure_edit_identity(socket, state.root, name, target_source)
            preview_started? = is_integer(preview_hash(socket, name))

            commit_opts =
              identity
              |> identity_opts()
              |> Keyword.put(:preview_continuation, preview_started?)
              |> Keyword.put(:atomic_rename, true)

            result =
              state.root
              |> commit_buffer(target_source, target_name, buf, commit_opts)
              |> final_commit_result()

            case result do
              {:ok, _} ->
                {:noreply, socket |> clear_name(name) |> clear_name(target)}

              {:error, reason} ->
                Logger.error(
                  "[DocFs] write_back rename failed for #{Path.join(state.root, target)} via #{name}: #{inspect(reason)}"
                )

                # POSIX rename failure preserves the visible source temp. Clear only
                # its provisional-preview lifecycle metadata and the stale target
                # seed so rereads expose both the temp bytes and canonical target.
                socket = reject_atomic_rename(socket, state.root, name, target, reason)
                {:error, write_errno(reason), socket}
            end

          true ->
            socket =
              socket
              |> put_buf(path_key(target), buf)
              |> mark_dirty(path_key(target))
              |> move_edit_metadata(name, target)
              |> clear_name(name)

            {:noreply, socket}
        end
    end
  end

  unlink "/:name" do
    OpenDocs.cancel_canonical_echo(state.root, name)
    {:noreply, clear_name(socket, name)}
  end

  release "/:name" do
    key = event_key(event, name)

    case source_path(state.root, name) do
      {:ok, source} ->
        {result, socket} = commit_key(socket, source, name, key, state.root)

        socket =
          case result do
            {:error, reason} -> reject_release_preview(socket, state.root, name, reason)
            _other -> socket
          end

        socket = socket |> clear_key(key) |> clear_preview_metadata(name) |> delete_handle(event)

        case result do
          {:ok, _} ->
            {:noreply, socket}

          {:error, reason} ->
            Logger.error(
              "[DocFs] write_back release failed for #{Path.join(state.root, name)}: #{inspect(reason)}"
            )

            {:error, write_errno(reason), socket}
        end

      {:error, _reason} ->
        socket =
          case buffer(socket, key) do
            buf when is_binary(buf) ->
              # FSKit volume ops carry no file handle, so `key` may BE the
              # path key — clearing it after the move would drop the buffer
              # a later rename commits.
              socket
              |> put_buf(path_key(name), buf)
              |> maybe_mark_path_dirty(name, key)
              |> then(&if key == path_key(name), do: &1, else: clear_key(&1, key))
              |> delete_handle(event)

            _ ->
              socket |> clear_key(key) |> delete_handle(event)
          end

        {:noreply, socket}
    end
  end

  # ── buffer state (per-mount socket assigns) ───────────────────────────

  defp buffers(socket), do: Exfuse.Socket.get_assign(socket, :wbuf, %{})
  defp buffer(socket, key), do: Map.get(buffers(socket), key)
  defp dirties(socket), do: Exfuse.Socket.get_assign(socket, :dirty, MapSet.new())
  defp dirty?(socket, key), do: MapSet.member?(dirties(socket), key)

  defp mark_dirty(socket, key),
    do: Exfuse.Socket.assign(socket, :dirty, MapSet.put(dirties(socket), key))

  defp mark_clean(socket, key),
    do: Exfuse.Socket.assign(socket, :dirty, MapSet.delete(dirties(socket), key))

  defp ensure_buf(socket, root, name, key) do
    case buffer(socket, key) do
      buf when is_binary(buf) ->
        {buf, socket}

      _ ->
        seed =
          with {:ok, bytes} <- projected_bytes(root, name) do
            bytes
          else
            _ -> name_buffer(socket, name) || ""
          end

        {seed, socket} = pop_pending_truncate(socket, name, seed)
        {seed, put_buf(socket, key, seed)}
    end
  end

  defp put_buf(socket, key, bytes),
    do: Exfuse.Socket.assign(socket, :wbuf, Map.put(buffers(socket), key, bytes))

  defp clear_key(socket, key) do
    socket
    |> Exfuse.Socket.assign(:wbuf, Map.delete(buffers(socket), key))
    |> Exfuse.Socket.assign(:dirty, MapSet.delete(dirties(socket), key))
  end

  # A name we may write to: a projected doc in the open set, or a transient temp
  # file we already created/buffered.
  defp target_known?(root, socket, name),
    do: match?({:ok, _}, source_path(root, name)) or buffered_name?(socket, name)

  defp new_handle(socket, name), do: Exfuse.Socket.new_handle(socket, name)

  defp delete_handle(socket, %{handle: handle}) when is_integer(handle) and handle > 0,
    do: Exfuse.Socket.delete_handle(socket, handle)

  defp delete_handle(socket, _event), do: socket

  defp event_key(%{handle: handle}, _name) when is_integer(handle) and handle > 0,
    do: handle_key(handle)

  defp event_key(_event, name), do: path_key(name)

  defp handle_key(handle), do: {:handle, handle}
  defp path_key(name), do: {:path, name}

  defp handles(socket), do: Exfuse.Socket.get_assign(socket, :handles, %{})

  defp handle_keys_for_name(socket, name) do
    socket
    |> handles()
    |> Enum.flat_map(fn
      {handle, ^name} -> [handle_key(handle)]
      _other -> []
    end)
  end

  defp keys_for_name(socket, name), do: [path_key(name) | handle_keys_for_name(socket, name)]

  defp buffered_name?(socket, name) do
    Enum.any?(keys_for_name(socket, name), &is_binary(buffer(socket, &1)))
  end

  defp name_buffer(socket, name) do
    keys = keys_for_name(socket, name)

    Enum.find_value(keys, fn key ->
      buf = buffer(socket, key)
      if dirty?(socket, key) and is_binary(buf) and buf != "", do: buf
    end) ||
      Enum.find_value(keys, fn key ->
        buf = buffer(socket, key)
        if dirty?(socket, key) and is_binary(buf), do: buf
      end) ||
      Enum.find_value(keys, &buffer(socket, &1))
  end

  defp clear_name(socket, name) do
    socket =
      Enum.reduce(keys_for_name(socket, name), socket, fn key, acc -> clear_key(acc, key) end)

    socket
    |> Exfuse.Socket.assign(:pending_truncate, Map.delete(pending_truncates(socket), name))
    |> clear_preview_metadata(name)
  end

  defp truncate_buffers(socket, root, name, size) do
    keys =
      socket
      |> keys_for_name(name)
      |> Enum.filter(&is_binary(buffer(socket, &1)))

    if keys == [] do
      put_pending_truncate(socket, name, size)
    else
      Enum.reduce(keys, socket, fn key, acc ->
        {buf, acc} = ensure_buf(acc, root, name, key)

        acc
        |> put_buf(key, truncate_bytes(buf, size))
        |> mark_dirty(key)
      end)
    end
  end

  defp truncate_bytes(buf, size) do
    kept = min(size, byte_size(buf))
    binary_part(buf, 0, kept)
  end

  defp pending_truncates(socket), do: Exfuse.Socket.get_assign(socket, :pending_truncate, %{})

  defp put_pending_truncate(socket, name, size),
    do:
      Exfuse.Socket.assign(
        socket,
        :pending_truncate,
        Map.put(pending_truncates(socket), name, size)
      )

  defp pop_pending_truncate(socket, name, seed) do
    case Map.fetch(pending_truncates(socket), name) do
      {:ok, size} ->
        socket =
          Exfuse.Socket.assign(
            socket,
            :pending_truncate,
            Map.delete(pending_truncates(socket), name)
          )

        {truncate_bytes(seed, size), socket}

      :error ->
        {seed, socket}
    end
  end

  defp maybe_mark_path_dirty(socket, name, key) do
    if dirty?(socket, key), do: mark_dirty(socket, path_key(name)), else: socket
  end

  defp commit_key(socket, source, name, key, root) do
    source_name = mounted_source_name(name)
    opts = vfs_edit_opts(socket, root, name, source)

    cond do
      dirty?(socket, key) and is_binary(buffer(socket, key)) ->
        result =
          root
          |> commit_buffer(source, source_name, buffer(socket, key), opts)
          |> final_commit_result()

        {result, socket}

      dirty?(socket, path_key(name)) and is_binary(buffer(socket, path_key(name))) ->
        result =
          root
          |> commit_buffer(source, source_name, buffer(socket, path_key(name)), opts)
          |> final_commit_result()

        {result, socket}

      true ->
        {{:ok, :clean}, socket}
    end
  end

  defp maybe_commit_live_buffer(socket, root, name, key, buf) do
    case source_path(root, name) do
      {:ok, source} ->
        opts =
          socket
          |> edit_identity(name)
          |> identity_opts()
          |> Keyword.put(:preview_continuation, is_integer(preview_hash(socket, name)))

        case commit_buffer(root, source, mounted_source_name(name), buf, opts) do
          {:ok, {:staged, _reason}} -> socket
          {:ok, _info} -> mark_clean(socket, key)
          {:error, _reason} -> socket
        end

      {:error, _reason} ->
        socket
    end
  end

  # A VFS editor may save either by replacing a temp file or by rewriting the
  # projected file in place. FSKit can deliver chunks out of order in both
  # cases, so publish a semantic preview only once the accumulated bytes form a
  # complete valid projection. `Projection.preview_write_back/3` never mutates
  # the source; the subsequent direct commit or rename reuses its edit id.
  defp maybe_preview_buffer(socket, root, name, buf) do
    if OpenDocs.canonical_echo_temp?(root, name) do
      socket
    else
      preview_buffer(socket, root, name, buf)
    end
  end

  defp preview_buffer(socket, root, name, buf) do
    # Pin the complete ownership tuple before projection parsing can fail. That
    # tuple is the edit lifecycle's authority from here through release/rename;
    # OpenDocs may legitimately change when another agent opens the document,
    # but it must never retarget this already-started edit.
    {identity, socket} = ensure_edit_identity(socket, root, name)

    with {:ok, source} <- preview_source_path(root, name),
         hash <- :erlang.phash2(buf),
         false <- preview_hash(socket, name) == hash,
         {:ok, _info} <-
           Projection.preview_write_back(
             source,
             buf,
             Keyword.put(identity_opts(identity), :root, root)
           ) do
      put_preview_hash(socket, name, hash)
    else
      _reason -> socket
    end
  end

  defp preview_source_path(root, name) do
    case source_path(root, name) do
      {:ok, source} ->
        {:ok, source}

      {:error, _reason} ->
        with {:ok, target_name} <- preview_target_name(name),
             {:ok, source} <- source_path(root, target_name) do
          {:ok, source}
        end
    end
  end

  defp preview_target_name(name) when is_binary(name) do
    case String.split(name, ".jsonl", parts: 2) do
      [base, suffix] when suffix != "" ->
        if String.starts_with?(suffix, "."), do: {:ok, base <> ".jsonl"}, else: :error

      _ ->
        :error
    end
  end

  defp preview_target_name(_name), do: :error

  defp edit_identities(socket),
    do: Exfuse.Socket.get_assign(socket, :vfs_edit_identities, %{})

  defp edit_identity(socket, name), do: Map.get(edit_identities(socket), name)

  defp ensure_edit_identity(socket, root, name, known_source \\ nil) do
    case Map.fetch(edit_identities(socket), name) do
      {:ok, identity} when is_map(identity) ->
        {identity, socket}

      :error ->
        owner = edit_owner_identity(root, name, known_source)

        identity =
          Map.merge(owner, %{
            edit_id:
              "vfs-edit-" <>
                Integer.to_string(System.unique_integer([:positive, :monotonic]))
          })

        {identity,
         Exfuse.Socket.assign(
           socket,
           :vfs_edit_identities,
           Map.put(edit_identities(socket), name, identity)
         )}
    end
  end

  defp edit_owner_identity(root, _name, source) when is_binary(source),
    do: OpenDocs.owner_identity_for_source(root, source)

  defp edit_owner_identity(root, name, _source) do
    case preview_source_path(root, name) do
      {:ok, source} -> OpenDocs.owner_identity_for_source(root, source)
      _unresolved -> OpenDocs.owner_identity(root, mounted_source_name(name))
    end
  end

  defp preview_hashes(socket), do: Exfuse.Socket.get_assign(socket, :preview_hashes, %{})
  defp preview_hash(socket, name), do: Map.get(preview_hashes(socket), name)

  defp put_preview_hash(socket, name, hash),
    do: Exfuse.Socket.assign(socket, :preview_hashes, Map.put(preview_hashes(socket), name, hash))

  defp clear_preview_metadata(socket, name) do
    socket
    |> Exfuse.Socket.assign(:vfs_edit_identities, Map.delete(edit_identities(socket), name))
    |> Exfuse.Socket.assign(:preview_hashes, Map.delete(preview_hashes(socket), name))
  end

  defp move_edit_metadata(socket, source_name, target_name) do
    identities = edit_identities(socket)
    hashes = preview_hashes(socket)

    identities =
      case Map.fetch(identities, source_name) do
        {:ok, identity} -> identities |> Map.delete(source_name) |> Map.put(target_name, identity)
        :error -> Map.delete(identities, source_name)
      end

    hashes =
      case Map.fetch(hashes, source_name) do
        {:ok, hash} -> hashes |> Map.delete(source_name) |> Map.put(target_name, hash)
        :error -> Map.delete(hashes, source_name)
      end

    socket
    |> Exfuse.Socket.assign(:vfs_edit_identities, identities)
    |> Exfuse.Socket.assign(:preview_hashes, hashes)
  end

  defp vfs_edit_opts(socket, _root, name, _source),
    do: socket |> edit_identity(name) |> identity_opts()

  defp maybe_put_edit_id(opts, edit_id) when is_binary(edit_id) and edit_id != "",
    do: Keyword.put(opts, :edit_id, edit_id)

  defp maybe_put_edit_id(opts, _edit_id), do: opts

  defp maybe_put_turn_id(opts, turn_id) when is_binary(turn_id) and turn_id != "",
    do: Keyword.put(opts, :turn_id, turn_id)

  defp maybe_put_turn_id(opts, _turn_id), do: opts

  defp maybe_put_agent_id(opts, agent_id) when is_binary(agent_id) and agent_id != "",
    do: Keyword.put(opts, :agent_id, agent_id)

  defp maybe_put_agent_id(opts, _agent_id), do: opts

  defp maybe_put_instance_id(opts, instance_id)
       when is_binary(instance_id) and instance_id != "",
       do: Keyword.put(opts, :instance_id, instance_id)

  defp maybe_put_instance_id(opts, _instance_id), do: opts

  defp reject_atomic_rename(socket, root, source_name, target_name, reason) do
    if is_integer(preview_hash(socket, source_name)) do
      with identity when is_map(identity) <- edit_identity(socket, source_name),
           {:ok, source} <- source_path(root, target_name) do
        broadcast_preview_rejected(
          root,
          source,
          mounted_source_name(target_name),
          identity,
          reason
        )
      end
    end

    OpenDocs.unstage(root, mounted_source_name(target_name))
    socket |> clear_preview_metadata(source_name) |> clear_name(target_name)
  end

  defp reject_release_preview(socket, root, name, reason) do
    if is_integer(preview_hash(socket, name)) do
      with identity when is_map(identity) <- edit_identity(socket, name),
           {:ok, source} <- source_path(root, name) do
        broadcast_preview_rejected(
          root,
          source,
          mounted_source_name(name),
          identity,
          reason
        )
      end
    end

    socket
  end

  defp broadcast_preview_rejected(root, source, source_name, identity, reason) do
    info = %{
      path: source,
      doc: source_name,
      edit_id: Map.get(identity, :edit_id),
      agent_id: Map.get(identity, :agent_id),
      instance_id: Map.get(identity, :instance_id),
      turn_id: Map.get(identity, :turn_id),
      reason: inspect(reason, limit: 8, printable_limit: 240)
    }

    Phoenix.PubSub.broadcast(
      Ecrits.PubSub,
      "doc_vfs:" <> DocMount.canonical_root(root),
      {:vfs_doc_edit_rejected, info}
    )
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp identity_opts(identity) when is_map(identity) do
    []
    |> maybe_put_edit_id(Map.get(identity, :edit_id))
    |> maybe_put_agent_id(Map.get(identity, :agent_id))
    |> maybe_put_agent_session(Map.get(identity, :agent_session))
    |> maybe_put_instance_id(Map.get(identity, :instance_id))
    |> maybe_put_turn_id(Map.get(identity, :turn_id))
  end

  defp identity_opts(_identity), do: []

  if Mix.env() == :test do
    @doc false
    def __owner_identity_opts_for_test__(root, name, source) do
      root
      |> edit_owner_identity(name, source)
      |> identity_opts()
    end
  end

  defp maybe_put_agent_session(opts, agent_session) when is_pid(agent_session),
    do: Keyword.put(opts, :agent_session, agent_session)

  defp maybe_put_agent_session(opts, _agent_session), do: opts

  defp commit_buffer(root, source, source_name, buf, opts) do
    OpenDocs.clear_write_failure(root, source_name)

    # A failed atomic rename leaves its source temp in place and must not make
    # rejected bytes visible under the target. Direct rewrites still stage
    # retryable bytes on the target so the same handle can be corrected.
    {atomic_rename?, write_back_opts} = Keyword.pop(opts, :atomic_rename, false)

    case write_back_unless_accepted(
           root,
           source,
           source_name,
           buf,
           Keyword.put(write_back_opts, :root, root)
         ) do
      {:ok, %{accepted_noop: true}} = ok ->
        OpenDocs.unstage(root, source_name)
        ok

      # Semantic no-op with byte-different content: the stale-run reconciliation
      # in the projection diff heals commits that carry real changes, so a write
      # applying zero changes while differing from committed bytes can only be a
      # replay of an earlier served state (e.g. a duplicate octet delivery after
      # terminal canonical publication). Republishing it would regress the
      # served view, so fail closed without mutating anything.
      {:ok, %{applied: 0}} ->
        OpenDocs.unstage(root, source_name)
        record_write_failure(root, source_name, :stale_projection_replay)
        {:error, :stale_projection_replay}

      {:ok, _info} = ok ->
        OpenDocs.unstage(root, source_name)

        cache_accepted_projection(
          root,
          source_name,
          source,
          buf,
          identity_from_opts(write_back_opts)
        )

        ok

      {:error, reason} = error ->
        cond do
          retryable_commit_error?(reason) and atomic_rename? ->
            error

          retryable_commit_error?(reason) ->
            OpenDocs.stage(root, source_name, buf, reason, identity_from_opts(write_back_opts))
            {:ok, {:staged, reason}}

          true ->
            OpenDocs.unstage(root, source_name)
            record_write_failure(root, source_name, reason)
            error
        end
    end
  end

  # FSKit has no invalidation callback for replacing already-served inode bytes.
  # Atomically keep the successful user write's exact transport bytes globally
  # visible and stage the engine's normalized projection separately. Only the
  # fresh mounted sibling+rename echo in `flush_canonical/2` publishes those
  # canonical bytes to the live inode namespace.
  defp cache_accepted_projection(root, source_name, source, bytes, identity) do
    case accepted_projection_settlement(source, bytes, identity) do
      {:accept_projection, ^bytes, canonical_bytes, metadata} ->
        OpenDocs.accept_projection(root, source_name, bytes, canonical_bytes, metadata)

      {:accept_projection_retry, ^bytes, metadata} ->
        OpenDocs.accept_projection_retry(root, source_name, bytes, metadata)
    end
  end

  defp accepted_projection_settlement(source, bytes, identity) do
    metadata = Map.put(identity || %{}, :source_path, source)

    case Projection.project_file(source) do
      {:ok, canonical_bytes} ->
        {:accept_projection, bytes, canonical_bytes, metadata}

      {:error, reason} ->
        # The semantic write already succeeded. Preserve exact transport truth
        # even if a follow-up canonical projection cannot currently be rendered.
        Logger.warning(
          "[DocFs] canonical projection unavailable for #{source}: #{inspect(reason)}"
        )

        {:accept_projection_retry, bytes, metadata}
    end
  end

  # A client may rewrite the exact bytes it just read without a semantic change.
  # Once the engine has normalized an inserted table, diffing that accepted raw
  # shape again is structurally ambiguous; the byte-identical cache hit is the
  # authoritative no-op guard and prevents both a false EINVAL and duplication.
  defp write_back_unless_accepted(root, source, source_name, bytes, opts) do
    case OpenDocs.committed(root, source_name) do
      {:ok, ^bytes} ->
        {:ok, %{applied: 0, accepted_noop: true, doc: Path.basename(source)}}

      _other ->
        # `:root` is what write_back's broadcast_edit keys the chat-rail
        # preview publication on — without it every VFS edit commits silently
        # and no {:vfs_doc_edited, info} (and thus no persisted edit preview)
        # ever reaches a rail. Field regression 2026-07-19: the opts contract
        # drifted in a write-path restructure and previews vanished for weeks
        # of turns.
        Projection.write_back(source, bytes, Keyword.put(opts, :root, root))
    end
  end

  defp resolve_in_flight_canonical(root, entry, filters, opts) do
    result = safe_resolve_in_flight_canonical(root, entry, opts)

    if current_in_flight?(root, entry, filters) do
      result
    else
      # A concurrent newer edit superseded this token while projection was in
      # progress. Its own owner-scoped stage is now the only terminal concern.
      :ok
    end
  end

  defp safe_resolve_in_flight_canonical(root, entry, opts) do
    project_fun = Keyword.get(opts, :project_fun, &Projection.project_file/1)

    with source when is_binary(source) <- Map.get(entry, :source_path),
         {:ok, canonical_bytes} <- project_fun.(source),
         :ok <-
           OpenDocs.complete_canonical_stage(
             root,
             entry.name,
             entry.accepted_bytes,
             canonical_bytes,
             entry.generation,
             entry
           ) do
      :ok
    else
      nil -> {:error, :canonical_projection_source_missing}
      {:error, reason} -> {:error, {:canonical_projection_failed, reason}}
      other -> {:error, {:canonical_projection_invalid_result, other}}
    end
  rescue
    error -> {:error, {:canonical_projection_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:canonical_projection_caught, kind, reason}}
  end

  defp current_in_flight?(root, entry, filters) do
    root
    |> OpenDocs.in_flight_canonical_entries(filters)
    |> Enum.any?(fn current ->
      current.name == entry.name and current.generation == entry.generation
    end)
  end

  defp publish_pending_canonical(root, entry, opts) do
    target = Projection.projected_name(entry.name)

    token = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    temp = ".ecrits-canonical-" <> token <> ".tmp"

    with :ok <- OpenDocs.begin_canonical_echo(root, entry.name, temp, entry) do
      result = safe_canonical_publication(root, temp, target, entry, opts)

      case result do
        :ok ->
          :ok

        {:error, _reason} = error ->
          cancel_canonical_publication(root, temp, target)
          error
      end
    end
  end

  defp safe_canonical_publication(root, temp, target, entry, opts) do
    if canonical_mount_active?(root, opts) do
      publish_canonical_through_mount(root, temp, target, entry, opts)
    else
      OpenDocs.promote_canonical_echo(root, temp)
    end
  rescue
    error -> {:error, {:canonical_publication_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:canonical_publication_caught, kind, reason}}
  end

  defp canonical_mount_active?(root, opts) do
    case Keyword.fetch(opts, :mounted?) do
      {:ok, mounted?} when is_boolean(mounted?) -> mounted?
      {:ok, fun} when is_function(fun, 1) -> fun.(root)
      :error -> DocMount.mounted?(root)
    end
  end

  defp publish_canonical_through_mount(root, temp, target, entry, opts) do
    echo_fun = Keyword.get(opts, :echo_fun, &write_mounted_canonical_echo/4)

    result = echo_fun.(root, temp, target, entry.bytes)

    cond do
      result == :ok and OpenDocs.committed(root, entry.name) == {:ok, entry.bytes} ->
        :ok

      Keyword.get(opts, :remount?, false) ->
        remount_canonical_fallback(root, temp, entry, opts, result)

      true ->
        cancel_canonical_publication(root, temp, target)
        {:error, {:canonical_echo_failed, result}}
    end
  end

  defp remount_canonical_fallback(root, temp, entry, opts, echo_result) do
    remount_fun =
      Keyword.get(opts, :remount_fun, fn root, before_mount ->
        DocMount.refresh(root, before_mount: before_mount)
      end)

    claim_result =
      case OpenDocs.canonical_echo(root, temp) do
        {:ok, _entry} -> :ok
        :error -> OpenDocs.begin_canonical_echo(root, entry.name, temp, entry)
      end

    result =
      if claim_result == :ok do
        remount_fun.(root, fn ->
          OpenDocs.promote_canonical_echo(root, temp)
        end)
      else
        {:error, claim_result}
      end

    if match?({:ok, :mounted}, result) and
         OpenDocs.committed(root, entry.name) == {:ok, entry.bytes} do
      :ok
    else
      OpenDocs.cancel_canonical_echo(root, temp)
      {:error, {:canonical_echo_and_remount_failed, echo_result, result}}
    end
  end

  defp cancel_canonical_publication(root, temp, target) do
    OpenDocs.cancel_canonical_echo(root, temp)
    _ = File.rm(Path.join(DocMount.mount_point(root), temp))

    # The target is intentionally untouched: failed echo publication leaves the
    # successful user rename's exact bytes as the mounted truth.
    _ = target
    :ok
  end

  defp write_mounted_canonical_echo(root, temp, target, bytes) do
    mount = DocMount.mount_point(root)
    temp_path = Path.join(mount, temp)
    target_path = Path.join(mount, target)

    with {:ok, io} <-
           :file.open(String.to_charlist(temp_path), [:raw, :binary, :write, :exclusive]) do
      write_result =
        with :ok <- :file.write(io, bytes),
             :ok <- :file.sync(io) do
          :ok
        end

      close_result = :file.close(io)

      with :ok <- write_result,
           :ok <- close_result,
           :ok <- File.rename(temp_path, target_path) do
        :ok
      end
    end
  end

  defp identity_from_opts(opts) do
    %{
      edit_id: Keyword.get(opts, :edit_id),
      agent_id: Keyword.get(opts, :agent_id),
      agent_session: Keyword.get(opts, :agent_session),
      instance_id: Keyword.get(opts, :instance_id),
      turn_id: Keyword.get(opts, :turn_id)
    }
  end

  defp staged_identity_matches?(_identity, []), do: true

  defp staged_identity_matches?(identity, filters) when is_map(identity) do
    Enum.all?(filters, fn {key, value} ->
      not (is_binary(value) and value != "") or Map.get(identity, key) == value
    end)
  end

  defp staged_identity_matches?(_identity, _filters), do: false

  defp retryable_commit_error?({:invalid_ir_json, _line}), do: true
  defp retryable_commit_error?(:structural_change), do: true
  defp retryable_commit_error?(_reason), do: false

  defp final_commit_result({:ok, {:staged, :structural_change}}),
    do: {:error, :structural_change}

  defp final_commit_result(result), do: result

  # A projection validation error is bad input, not a failed filesystem or
  # engine write. Keep EIO for the latter so a client can distinguish a
  # correctable JSONL edit from a transport/runtime failure on both release and
  # temp+rename paths.
  defp write_errno(:stale_projection_replay), do: :einval
  defp write_errno({:multiple_nested_projection_values, _count}), do: :einval
  defp write_errno({:invalid_ir_json, _line}), do: :einval
  defp write_errno({:invalid_property, _key}), do: :einval
  defp write_errno({:invalid_property_type, _key}), do: :einval
  defp write_errno({:read_only_property, _key}), do: :einval
  defp write_errno({:invalid_table_payload, _reason}), do: :einval
  defp write_errno({:invalid_picture_payload, _reason}), do: :einval
  defp write_errno({:writeback_unroutable, _reason}), do: :einval
  defp write_errno({:browser_writeback_rejected, _reason}), do: :einval
  defp write_errno({:invalid_geometry, _reason}), do: :einval
  defp write_errno({:invalid_column_def, _reason}), do: :einval

  defp write_errno(reason)
       when reason in [
              :invalid_payload_node,
              :invalid_payload_layer,
              :missing_payload_layer,
              :invalid_layer_record,
              :invalid_doc_layer,
              :invalid_section_layer,
              :missing_section_layer,
              :invalid_paragraph_layer,
              :missing_paragraph_layer,
              :invalid_section_list,
              :invalid_paragraph_list,
              :invalid_ir_jsonl,
              :structural_change,
              :unroutable
            ],
       do: :einval

  defp write_errno(_reason), do: :eio

  # Only transport/engine failures are fallback evidence. Projection validation
  # failures are user-correctable JSONL input and must never unlock `doc.edit`.
  defp record_write_failure(root, source_name, reason) do
    if write_errno(reason) == :eio do
      OpenDocs.record_write_failure(root, source_name, reason)
    end
  end

  defp terminal_rejectable_staged_error?({:invalid_ir_json, _line}), do: true
  defp terminal_rejectable_staged_error?(:structural_change), do: true
  defp terminal_rejectable_staged_error?(_reason), do: false

  defp settle_staged_cleanup(
         acc,
         root,
         name,
         bytes,
         reason,
         identity,
         filters,
         cleanup_reason
       ) do
    disposition =
      settle_staged_snapshot(root, name, bytes, reason, identity, filters, :discard)

    maybe_mark_replaced_stage_pending(acc, name, disposition, cleanup_reason)
  end

  defp settle_staged_commit(
         acc,
         root,
         name,
         bytes,
         reason,
         identity,
         filters,
         settlement,
         commit_reason
       ) do
    disposition =
      settle_staged_snapshot(root, name, bytes, reason, identity, filters, settlement)

    acc
    |> Map.update!(:committed, &[name | &1])
    |> maybe_mark_replaced_stage_pending(name, disposition, commit_reason)
  end

  defp settle_staged_snapshot(root, name, bytes, reason, identity, filters, settlement) do
    case OpenDocs.settle_staged(root, name, bytes, reason, identity, settlement, filters) do
      :settled -> :discarded
      :retained -> :retained
      :same_owner_replaced -> :same_owner_replaced
      :other_owner_or_gone -> :other_owner_or_gone
    end
  end

  defp maybe_mark_replaced_stage_pending(acc, name, :same_owner_replaced, reason) do
    Map.update!(acc, :pending, &[{name, {:staged_replaced, reason}} | &1])
  end

  defp maybe_mark_replaced_stage_pending(acc, _name, _disposition, _reason), do: acc

  defp projected_bytes(root, name) do
    with {:ok, source} <- source_path(root, name) do
      source_name = mounted_source_name(name)

      case OpenDocs.staged(root, source_name) do
        {:ok, bytes, :structural_change} ->
          {:ok, bytes}

        :error ->
          case OpenDocs.committed(root, source_name) do
            {:ok, bytes} -> {:ok, bytes}
            :error -> Projection.project_file(source)
          end

        {:ok, _bytes, _reason} ->
          case OpenDocs.committed(root, source_name) do
            {:ok, bytes} -> {:ok, bytes}
            :error -> Projection.project_file(source)
          end
      end
    end
  end

  # `getattr` must report the REAL projected size plus an mtime that advances
  # when the projection changes. The FUSE-era 64MB over-estimate floor is
  # fatal under FSKit: the kernel believes the file is huge, the first `read`
  # comes back short mid-file, and UserFS turns that short read into EIO
  # (the legacy FUSE backend tolerated it). The moving mtime makes the kernel drop cached
  # pages and pick up the new size after the live document was edited
  # (browser UI, doc.* tools, write-back). Rendering the projection here
  # costs the same as one `read` op — which already re-projects per call.
  defp projected_attrs(socket, root, name) do
    with {:ok, bytes} <- projected_bytes(root, name) do
      {mtime, socket} = content_mtime(socket, name, bytes)
      {byte_size(bytes), mtime, socket}
    else
      _ -> {@projected_attr_size_floor, nil, socket}
    end
  end

  # A monotonic per-name pseudo-time that advances exactly when the content
  # changes. Monotonic (not content-hashed) because the kernel only honors
  # size updates for attributes NEWER than what it cached.
  @mtime_base 1_700_000_000
  defp content_mtime(socket, name, content) do
    gens = Exfuse.Socket.get_assign(socket, :content_gens, %{})
    hash = :erlang.phash2(content)
    clock = Map.get(gens, :clock, 0)

    case Map.get(gens, name) do
      {^hash, at} ->
        {@mtime_base + at, socket}

      _other ->
        clock = clock + 1
        gens = gens |> Map.put(name, {hash, clock}) |> Map.put(:clock, clock)
        {@mtime_base + clock, Exfuse.Socket.assign(socket, :content_gens, gens)}
    end
  end

  # Splice `data` into `buf` at `offset` (append when offset == size; zero-pad a
  # gap past EOF, which a normal editor never produces).
  defp splice(buf, offset, data) do
    size = byte_size(buf)

    cond do
      offset == size ->
        buf <> data

      offset < size ->
        head = binary_part(buf, 0, offset)
        tail_start = offset + byte_size(data)
        tail = if tail_start < size, do: binary_part(buf, tail_start, size - tail_start), else: ""
        head <> data <> tail

      true ->
        buf <> :binary.copy(<<0>>, offset - size) <> data
    end
  end

  # A projected name (`a.hwp.jsonl`) resolves through `OpenDocs` ONLY if that doc
  # is in the open set. Root-level docs map to `<root>/a.hwp`; nested workspace
  # docs map through their stored `source_path`. Guards path escapes.
  # Non-open / non-`.jsonl` names -> :enoent.
  defp source_path(root, name) do
    with false <- path_escape?(name),
         basename when is_binary(basename) <- Projection.source_basename(name),
         false <- path_escape?(basename),
         true <- OpenDocs.member?(root, basename),
         {:ok, source} <- OpenDocs.source_path(root, basename) do
      {:ok, source}
    else
      _ -> {:error, :enoent}
    end
  end

  defp source_supported?(root, name) do
    case OpenDocs.source_path(root, name) do
      {:ok, source} -> Projection.supported?(source)
      :error -> false
    end
  end

  defp mounted_source_name(name), do: Projection.source_basename(name) || name

  defp canonical_temp_name?(name) when is_binary(name),
    do: String.starts_with?(name, ".ecrits-canonical-") and String.ends_with?(name, ".tmp")

  defp canonical_temp_name?(_name), do: false

  defp path_escape?(name), do: String.contains?(name, "/") or String.contains?(name, "..")

  defp slice(bytes, offset, size) do
    total = byte_size(bytes)
    start = min(offset, total)
    count = min(size, total - start)
    binary_part(bytes, start, count)
  end
end
