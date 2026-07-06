defmodule Ecrits.Fuse.DocFs do
  @moduledoc """
  `exfuse` filesystem that projects the workspace documents the agent has OPENED
  (via the `doc.open_doc` MCP tool) as a flat directory of JSONL IR files. The
  open set lives in `Ecrits.Fuse.OpenDocs` (per-workspace ETS); a doc appears as
  `<docname>.jsonl` only while it is open, and the projection bytes come from
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
  workflows that left an intermediate staged buffer during the turn.
  """
  @spec flush_staged(String.t()) :: %{committed: [String.t()], pending: [{String.t(), term()}]}
  def flush_staged(root) when is_binary(root) do
    root = DocMount.canonical_root(root)

    root
    |> OpenDocs.staged()
    |> Enum.reduce(%{committed: [], pending: []}, fn {name, bytes, _previous_reason}, acc ->
      source = Path.join(root, name)

      cond do
        not OpenDocs.member?(root, name) ->
          OpenDocs.unstage(root, name)
          acc

        not Projection.supported?(source) ->
          OpenDocs.unstage(root, name)
          acc

        true ->
          case Projection.write_back(source, bytes, root: root) do
            {:ok, _info} ->
              OpenDocs.unstage(root, name)
              Map.update!(acc, :committed, &[name | &1])

            {:error, reason} ->
              Logger.warning(
                "[DocFs] staged write_back still pending for #{Path.join(root, name)}: #{inspect(reason)}"
              )

              if discard_staged_error?(reason), do: OpenDocs.unstage(root, name)

              Map.update!(acc, :pending, &[{name, reason} | &1])
          end
      end
    end)
    |> Map.update!(:committed, &Enum.reverse/1)
    |> Map.update!(:pending, &Enum.reverse/1)
  end

  init do
    Map.update!(opts, :root, &DocMount.canonical_root/1)
  end

  readdir "/" do
    opened = OpenDocs.list(state.root)

    names =
      opened
      |> Enum.filter(fn name -> Projection.supported?(Path.join(state.root, name)) end)
      |> Enum.map(&Projection.projected_name/1)

    {:reply, names, socket}
  end

  getattr "/" do
    {mtime, socket} = content_mtime(socket, "/", Enum.sort(OpenDocs.list(state.root)))
    {:reply, dir(mtime: mtime), socket}
  end

  getattr "/:name" do
    cond do
      is_binary(name_buffer(socket, name)) ->
        buf = name_buffer(socket, name)
        {mtime, socket} = content_mtime(socket, name, buf)
        {:reply, file(size: byte_size(buf), mtime: mtime), socket}

      match?({:ok, _}, source_path(state.root, name)) ->
        {size, mtime, socket} = projected_attrs(socket, state.root, name)
        {:reply, file(size: size, mtime: mtime), socket}

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
    if OpenDocs.writable?(state.root) do
      {handle, socket} = new_handle(socket, name)
      {:reply, handle, put_buf(socket, handle_key(handle), "")}
    else
      {:error, :erofs, socket}
    end
  end

  write "/:name" do
    cond do
      not OpenDocs.writable?(state.root) ->
        {:error, :erofs, socket}

      not target_known?(state.root, socket, name) ->
        {:error, :enoent, socket}

      true ->
        key = event_key(event, name)
        {buf, socket} = ensure_buf(socket, state.root, name, key)

        next_buf = splice(buf, event.offset, event.data)

        socket =
          socket
          |> put_buf(key, next_buf)
          |> mark_dirty(key)
          |> maybe_commit_live_buffer(state.root, name, key, next_buf)

        {:reply, byte_size(event.data), socket}
    end
  end

  truncate "/:name" do
    cond do
      not OpenDocs.writable?(state.root) ->
        {:error, :erofs, socket}

      not target_known?(state.root, socket, name) ->
        {:error, :enoent, socket}

      true ->
        {:noreply, truncate_buffers(socket, state.root, name, event.size)}
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

    cond do
      not OpenDocs.writable?(state.root) ->
        {:error, :erofs, socket}

      match?({:ok, _}, source_path(state.root, target)) ->
        {:ok, target_source} = source_path(state.root, target)
        target_name = Path.basename(target_source)
        buf = name_buffer(socket, name) || ""
        result = commit_buffer(state.root, target_source, target_name, buf)
        socket = socket |> clear_name(name) |> clear_name(target)

        case result do
          {:ok, _} ->
            {:noreply, socket}

          {:error, reason} ->
            Logger.error(
              "[DocFs] write_back rename failed for #{Path.join(state.root, target)} via #{name}: #{inspect(reason)}"
            )

            {:error, :eio, socket}
        end

      true ->
        buf = name_buffer(socket, name) || ""

        socket =
          socket
          |> put_buf(path_key(target), buf)
          |> mark_dirty(path_key(target))
          |> clear_name(name)

        {:noreply, socket}
    end
  end

  unlink "/:name" do
    {:noreply, clear_name(socket, name)}
  end

  release "/:name" do
    key = event_key(event, name)

    case source_path(state.root, name) do
      {:ok, source} ->
        {result, socket} = commit_key(socket, source, name, key, state.root)
        socket = socket |> clear_key(key) |> delete_handle(event)

        case result do
          {:ok, _} ->
            {:noreply, socket}

          {:error, reason} ->
            Logger.error(
              "[DocFs] write_back release failed for #{Path.join(state.root, name)}: #{inspect(reason)}"
            )

            {:error, :eio, socket}
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

    Exfuse.Socket.assign(socket, :pending_truncate, Map.delete(pending_truncates(socket), name))
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
    cond do
      dirty?(socket, key) and is_binary(buffer(socket, key)) ->
        result = commit_buffer(root, source, Path.basename(source), buffer(socket, key))
        {result, socket}

      dirty?(socket, path_key(name)) and is_binary(buffer(socket, path_key(name))) ->
        result =
          commit_buffer(root, source, Path.basename(source), buffer(socket, path_key(name)))

        {result, socket}

      true ->
        {{:ok, :clean}, socket}
    end
  end

  defp maybe_commit_live_buffer(socket, root, name, key, buf) do
    case source_path(root, name) do
      {:ok, source} ->
        source_name = Path.basename(source)

        case commit_buffer(root, source, source_name, buf) do
          {:ok, {:staged, _reason}} -> socket
          {:ok, _info} -> mark_clean(socket, key)
          {:error, _reason} -> socket
        end

      {:error, _reason} ->
        socket
    end
  end

  defp commit_buffer(root, source, source_name, buf) do
    case Projection.write_back(source, buf, root: root) do
      {:ok, _info} = ok ->
        OpenDocs.unstage(root, source_name)
        ok

      {:error, reason} = error ->
        if retryable_commit_error?(reason) do
          OpenDocs.stage(root, source_name, buf, reason)
          {:ok, {:staged, reason}}
        else
          error
        end
    end
  end

  defp retryable_commit_error?({:invalid_ir_json, _line}), do: true
  defp retryable_commit_error?(:structural_change), do: true
  defp retryable_commit_error?(_reason), do: false

  defp discard_staged_error?({:invalid_ir_json, _line}), do: true
  defp discard_staged_error?(_reason), do: false

  defp projected_bytes(root, name) do
    with {:ok, source} <- source_path(root, name) do
      source_name = Path.basename(source)

      case OpenDocs.staged(root, source_name) do
        {:ok, _bytes, _reason} ->
          OpenDocs.unstage(root, source_name)
          Projection.project_file(source)

        :error ->
          Projection.project_file(source)
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
    with {:ok, source} <- source_path(root, name),
         {:ok, bytes} <- Projection.project_file(source) do
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

  # A projected name (`a.hwp.jsonl`) resolves to `<root>/a.hwp` ONLY if that doc is
  # in the open set. Guards path escapes. Non-open / non-`.jsonl` names -> :enoent.
  defp source_path(root, name) do
    with false <- path_escape?(name),
         basename when is_binary(basename) <- Projection.source_basename(name),
         false <- path_escape?(basename),
         true <- OpenDocs.member?(root, basename) do
      {:ok, Path.join(root, basename)}
    else
      _ -> {:error, :enoent}
    end
  end

  defp path_escape?(name), do: String.contains?(name, "/") or String.contains?(name, "..")

  defp slice(bytes, offset, size) do
    total = byte_size(bytes)
    start = min(offset, total)
    count = min(size, total - start)
    binary_part(bytes, start, count)
  end
end
