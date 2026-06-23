defmodule Ecrits.Fuse.DocFs do
  @moduledoc """
  `exfuse` filesystem that projects the workspace documents the agent has OPENED
  (via the `doc.open_doc` MCP tool) as a flat directory of markdown files. The
  open set lives in `Ecrits.Fuse.OpenDocs` (per-workspace ETS); a doc appears as
  `<docname>.md` only while it is open, and the projection bytes come from
  `Ecrits.Doc.Projection.project_file/1`.

  Writable: a write to a projected file is a **file-level modification of the
  document** — on commit it routes back onto the live document via
  `Ecrits.Doc.Projection.write_back/3`, which applies the change straight to the
  server document model (NOT the `doc.edit` MCP tool). So editing the mounted
  `.md` IS editing the document.

  The mount behaves like a real file that an in-place editor / linter
  (`sed -i`, a formatter) can rewrite. Two write patterns are supported:

    * **in-place** — `open`/`truncate`/`write` the projected file, commit on `flush`;
    * **atomic temp+rename** (what most linters do) — `create` a transient file,
      `write` it, then `rename` it over the projected `<doc>.md`; the `rename`
      commits the temp's bytes via `write_back`.

  Only a buffer that was actually WRITTEN commits: a read-only `cat`/`open` seeds
  a buffer but is never dirty, so it never writes back (critical — otherwise a
  stale read seed would revert a concurrent rename). A write is gated on the
  workspace access policy (`OpenDocs.writable?/1`) → `:erofs` when read-only.

  Handlers touch only ETS (`OpenDocs`) and `Projection` (which reads/writes the
  doc via the Pool/Editor) — never the BEAM `:file_server`, which a FUSE handler
  must avoid (an in-BEAM `File.*` on the mount would deadlock it). See
  `docs/plans/2026-06-23-exfuse-doc-vfs-migration.md`.
  """

  use Exfuse.Fs

  alias Ecrits.Doc.Projection
  alias Ecrits.Fuse.OpenDocs

  init do
    opts
  end

  readdir "/" do
    names =
      state.root
      |> OpenDocs.list()
      |> Enum.filter(&Projection.supported?/1)
      |> Enum.map(&Projection.projected_name/1)

    {:reply, names, socket}
  end

  getattr "/" do
    {:reply, dir(), socket}
  end

  getattr "/:name" do
    cond do
      match?({:ok, _}, source_path(state.root, name)) ->
        with {:ok, source} <- source_path(state.root, name),
             {:ok, bytes} <- Projection.project_file(source) do
          {:reply, file(size: byte_size(bytes)), socket}
        else
          _ -> {:error, :enoent, socket}
        end

      is_binary(buffer(socket, name)) ->
        {:reply, file(size: byte_size(buffer(socket, name))), socket}

      true ->
        {:error, :enoent, socket}
    end
  end

  read "/:name" do
    cond do
      match?({:ok, _}, source_path(state.root, name)) ->
        {:ok, source} = source_path(state.root, name)

        case Projection.project_file(source) do
          {:ok, bytes} -> {:reply, slice(bytes, event.offset, event.size), socket}
          {:error, _reason} -> {:error, :eio, socket}
        end

      is_binary(buffer(socket, name)) ->
        {:reply, slice(buffer(socket, name), event.offset, event.size), socket}

      true ->
        {:error, :enoent, socket}
    end
  end

  open "/:name" do
    cond do
      match?({:ok, _}, source_path(state.root, name)) ->
        # Seed the buffer with the live projection so a partial / in-place edit
        # starts from current content. Seeding does NOT mark dirty.
        {_buf, socket} = ensure_buf(socket, state.root, name)
        {:noreply, socket}

      is_binary(buffer(socket, name)) ->
        {:noreply, socket}

      true ->
        {:error, :enoent, socket}
    end
  end

  # A new file in the mount — an in-place editor's temp file. Register a
  # transient (sourceless) buffer; it commits only when renamed over a projected
  # doc. FUSE `create` is create+open, so no separate `open` follows.
  create "/:name" do
    if OpenDocs.writable?(state.root) do
      {:noreply, put_buf(socket, name, "")}
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
        {buf, socket} = ensure_buf(socket, state.root, name)

        socket =
          socket
          |> put_buf(name, splice(buf, event.offset, event.data))
          |> mark_dirty(name)

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
        {buf, socket} = ensure_buf(socket, state.root, name)
        kept = min(event.size, byte_size(buf))

        socket =
          socket
          |> put_buf(name, binary_part(buf, 0, kept))
          |> mark_dirty(name)

        {:noreply, socket}
    end
  end

  # In-place commit: a projected file that was actually written routes its buffer
  # back onto the document, then the buffer is dropped. A non-dirty buffer (a
  # read-only open seed) is dropped WITHOUT a write-back. A transient temp file's
  # buffer is left intact — it commits via `rename`, not `flush`.
  flush "/:name" do
    case source_path(state.root, name) do
      {:ok, source} ->
        buf = buffer(socket, name)

        result =
          if dirty?(socket, name) and is_binary(buf) do
            Projection.write_back(source, buf, root: state.root)
          else
            {:ok, :clean}
          end

        socket = clear_buf(socket, name)

        case result do
          {:ok, _} -> {:noreply, socket}
          {:error, _reason} -> {:error, :eio, socket}
        end

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  # Atomic in-place edit: a tool wrote a temp file and renames it over the
  # projected `<doc>.md`. Commit the temp's bytes to the document and drop both
  # buffers (the target's seed is now stale). A rename to a non-doc name (a
  # backup) just moves the buffer.
  rename "/:name" do
    target = event |> Map.get(:target) |> to_string() |> Path.basename()

    cond do
      not OpenDocs.writable?(state.root) ->
        {:error, :erofs, socket}

      match?({:ok, _}, source_path(state.root, target)) ->
        {:ok, target_source} = source_path(state.root, target)
        buf = buffer(socket, name) || ""
        result = Projection.write_back(target_source, buf, root: state.root)
        socket = socket |> clear_buf(name) |> clear_buf(target)

        case result do
          {:ok, _} -> {:noreply, socket}
          {:error, _reason} -> {:error, :eio, socket}
        end

      true ->
        buf = buffer(socket, name) || ""
        socket = socket |> put_buf(target, buf) |> mark_dirty(target) |> clear_buf(name)
        {:noreply, socket}
    end
  end

  unlink "/:name" do
    {:noreply, clear_buf(socket, name)}
  end

  release "/:_name" do
    # Buffers are dropped by `flush` (projected) or `rename`/`unlink` (transient
    # temp), never here — a temp's buffer must survive close→rename.
    {:noreply, socket}
  end

  # ── buffer state (per-mount socket assigns) ───────────────────────────

  defp buffers(socket), do: Exfuse.Socket.get_assign(socket, :wbuf, %{})
  defp buffer(socket, name), do: Map.get(buffers(socket), name)
  defp dirties(socket), do: Exfuse.Socket.get_assign(socket, :dirty, MapSet.new())
  defp dirty?(socket, name), do: MapSet.member?(dirties(socket), name)

  defp mark_dirty(socket, name),
    do: Exfuse.Socket.assign(socket, :dirty, MapSet.put(dirties(socket), name))

  defp ensure_buf(socket, root, name) do
    case buffer(socket, name) do
      buf when is_binary(buf) ->
        {buf, socket}

      _ ->
        seed =
          with {:ok, source} <- source_path(root, name),
               {:ok, bytes} <- Projection.project_file(source) do
            bytes
          else
            _ -> ""
          end

        {seed, put_buf(socket, name, seed)}
    end
  end

  defp put_buf(socket, name, bytes),
    do: Exfuse.Socket.assign(socket, :wbuf, Map.put(buffers(socket), name, bytes))

  defp clear_buf(socket, name) do
    socket
    |> Exfuse.Socket.assign(:wbuf, Map.delete(buffers(socket), name))
    |> Exfuse.Socket.assign(:dirty, MapSet.delete(dirties(socket), name))
  end

  # A name we may write to: a projected doc in the open set, or a transient temp
  # file we already created/buffered.
  defp target_known?(root, socket, name),
    do: match?({:ok, _}, source_path(root, name)) or is_binary(buffer(socket, name))

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

  # A projected name (`a.hwp.md`) resolves to `<root>/a.hwp` ONLY if that doc is
  # in the open set. Guards path escapes. Non-open / non-`.md` names -> :enoent.
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
