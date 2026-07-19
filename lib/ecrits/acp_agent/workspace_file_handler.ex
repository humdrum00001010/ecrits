defmodule Ecrits.AcpAgent.WorkspaceFileHandler do
  @moduledoc false

  @behaviour ExMCP.ACP.Client.Handler

  @max_read_bytes 64 * 1024 * 1024
  alias Ecrits.Doc.Projection
  alias Ecrits.Fuse.DocMount
  alias Ecrits.Fuse.OpenDocs
  alias Ecrits.AcpAgent.Session
  alias Ecrits.Workspace.FileIndex

  @impl true
  def init(opts) do
    root = opts |> Keyword.fetch!(:workspace_root) |> DocMount.canonical_root()
    document_path = Keyword.get(opts, :document_path)

    {:ok,
     %{
       root: root,
       document_path: document_path,
       expected_identity: Keyword.get(opts, :expected_identity),
       session_pid: Keyword.get(opts, :session_pid),
       read_only?: Keyword.get(opts, :read_only?, false),
       ask?: Keyword.get(opts, :ask?, false),
       session_id: nil
     }}
  end

  @impl true
  def handle_session_update(_session_id, _update, state), do: {:ok, state}

  # The rail's access mode is the user's standing answer to permission
  # requests: Full workspace opts out of per-op prompts (2026-07-19 field bug —
  # a blanket reject here made the agent report "승인이 거절되어" and degrade to
  # sandbox-only fallbacks), while a read-only rail must keep refusing
  # escalations. Prefer single-use options so each request is decided on its
  # own rather than granted or refused forever.
  @impl true
  def handle_permission_request(_session_id, _tool_call, options, %{read_only?: true} = state),
    do: {:ok, select_option(options, ["reject_once", "reject_always"]), state}

  def handle_permission_request(_session_id, _tool_call, options, state),
    do: {:ok, select_option(options, ["allow_once", "allow_always"]), state}

  defp select_option(options, kinds) do
    kinds
    |> Enum.find_value(fn kind -> Enum.find(options, &(Map.get(&1, "kind") == kind)) end)
    |> case do
      nil -> %{"outcome" => "cancelled"}
      option -> %{"outcome" => "selected", "optionId" => option["optionId"]}
    end
  end

  @impl true
  def handle_file_read(session_id, path, opts, state) do
    with {:ok, state} <- bind_session(state, session_id),
         {:ok, target} <- authorize_read(state, path),
         {:ok, content} <- read_utf8(target),
         {:ok, content} <- select_lines(content, opts) do
      {:ok, content, state}
    else
      {:error, reason} -> {:error, format_error(reason), state}
    end
  end

  @impl true
  def handle_file_write(session_id, path, content, state) do
    handle_file_write(session_id, path, content, %{}, state)
  end

  @impl true
  def handle_file_write(session_id, path, content, opts, state) do
    with {:ok, state} <- bind_session(state, session_id),
         :ok <- writable(state),
         {:ok, target} <- authorize_projection(state, path),
         {:ok, expected_sha256} <- expected_sha256(opts),
         :ok <- valid_utf8(content),
         :ok <- valid_jsonl(content),
         :ok <- write_projection(state, target, content, expected_sha256) do
      {:ok, state}
    else
      {:error, reason} -> {:error, format_error(reason), state}
    end
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp bind_session(%{session_id: nil} = state, session_id) when is_binary(session_id),
    do: {:ok, %{state | session_id: session_id}}

  defp bind_session(%{session_id: session_id} = state, session_id), do: {:ok, state}
  defp bind_session(_state, _session_id), do: {:error, :wrong_acp_session}

  defp authorize_read(state, path) do
    with {:ok, target} <- resolve_path(state.root, path),
         :ok <- regular_single_link_file(target),
         :ok <- readable_target(state, target) do
      {:ok, target}
    end
  end

  defp readable_target(state, target) do
    relative = Path.relative_to(target, state.root)

    cond do
      hidden_path?(relative) ->
        case active_projection(state) do
          {:ok, ^target} -> :ok
          {:ok, _other_projection} -> {:error, :hidden_path_denied}
          {:error, _reason} = error -> error
        end

      FileIndex.office_path?(target) ->
        {:error, :raw_document_denied}

      FileIndex.text_path?(target) ->
        :ok

      true ->
        {:error, :non_text_file_denied}
    end
  end

  defp authorize_projection(%{root: root} = state, path) do
    with {:ok, target} <- resolve_path(root, path),
         {:ok, projection} <- active_projection(state),
         true <- target == projection || {:error, :wrong_projection},
         :ok <- regular_single_link_file(target) do
      {:ok, target}
    end
  end

  # Ask mode is not Read only: the write is refusable but the refusal must
  # carry the path forward — the agent relays the approval request to the user
  # in chat, which IS the round-trip until a dedicated approval UI exists.
  defp writable(%{read_only?: true, ask?: true}), do: {:error, :approval_required_ask_mode}
  defp writable(%{read_only?: true}), do: {:error, :read_only}
  defp writable(_state), do: :ok

  defp resolve_path(root, path) when is_binary(path) and path != "" do
    expanded = Path.expand(path, root)
    relative = Path.relative_to(expanded, root)

    with {:ok, safe_relative} <- Path.safe_relative(relative, root),
         :ok <- deny_workspace_root(safe_relative),
         target = Path.join(root, safe_relative),
         :ok <- reject_symlink_components(root, safe_relative) do
      {:ok, target}
    else
      :error -> {:error, :path_outside_workspace}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_path(_root, _path), do: {:error, :invalid_path}

  defp deny_workspace_root(relative) when relative in ["", "."],
    do: {:error, :workspace_root_denied}

  defp deny_workspace_root(_relative), do: :ok

  defp reject_symlink_components(root, relative) do
    relative
    |> Path.split()
    |> Enum.reduce_while(root, fn component, current ->
      current = Path.join(current, component)

      case File.lstat(current) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink_denied}}
        {:ok, _stat} -> {:cont, current}
        {:error, :enoent} -> {:cont, current}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _path -> :ok
    end
  end

  defp regular_single_link_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, links: 1, size: size}} when size <= @max_read_bytes -> :ok
      {:ok, %File.Stat{type: :regular, links: links}} when links > 1 -> {:error, :hardlink_denied}
      {:ok, %File.Stat{type: :regular}} -> {:error, :file_too_large}
      {:ok, _stat} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_utf8(path) do
    with {:ok, content} <- File.read(path),
         :ok <- valid_utf8(content) do
      {:ok, content}
    end
  end

  defp valid_utf8(content) when is_binary(content) do
    if String.valid?(content), do: :ok, else: {:error, :invalid_utf8}
  end

  defp valid_utf8(_content), do: {:error, :invalid_content}

  defp select_lines(content, opts) when is_map(opts) do
    line = Map.get(opts, "line") || Map.get(opts, :line)
    limit = Map.get(opts, "limit") || Map.get(opts, :limit)

    cond do
      is_nil(line) and is_nil(limit) ->
        {:ok, content}

      is_integer(line) and line >= 1 and is_integer(limit) and limit >= 1 and limit <= 2_000 ->
        selected =
          content
          |> String.split("\n", trim: false)
          |> Enum.drop(line - 1)
          |> Enum.take(limit)
          |> Enum.join("\n")

        {:ok, selected}

      true ->
        {:error, :invalid_line_range}
    end
  end

  defp select_lines(_content, _opts), do: {:error, :invalid_read_options}

  # The projection is one JSON value formatted one-paragraph-group-per-line
  # (board #460), so validate the whole content first — newlines are
  # inter-token whitespace there. The per-line pass remains for the legacy
  # line-record encodings and pinpoints the first broken line.
  defp valid_jsonl(content) do
    case Jason.decode(content) do
      {:ok, _value} ->
        :ok

      {:error, _reason} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_trailing(&1, "\r"))
        |> Enum.with_index(1)
        |> Enum.reduce_while(:ok, fn {line, line_number}, :ok ->
          case Jason.decode(line) do
            {:ok, _value} -> {:cont, :ok}
            {:error, _reason} -> {:halt, {:error, {:invalid_jsonl, line_number}}}
          end
        end)
    end
  end

  # DocFs recognizes one exact staging protocol: `<mounted_at>.tmp` followed by
  # rename onto `<mounted_at>`. The exclusive create blocks link substitution;
  # the content hash and owner checks make this a compare-and-swap commit.
  defp write_projection(state, target, content, expected_sha256) do
    lock = {__MODULE__, target}

    case :global.trans(lock, fn ->
           with {:ok, ^target} <- active_projection(state),
                :ok <- unchanged_projection(target, expected_sha256),
                {:ok, temp} <- stage_temp(state, target, content) do
             result =
               with :ok <- projection_still_current(state, target, expected_sha256),
                    :ok <- File.rename(temp, target) do
                 :ok
               end

             if result != :ok, do: File.rm(temp)
             result
           end
         end) do
      :ok -> :ok
      {:aborted, reason} -> {:error, {:write_lock_aborted, reason}}
      {:error, _reason} = error -> error
      other -> {:error, {:write_failed, other}}
    end
  end

  defp create_temp_exclusive(target, content) do
    temp = target <> ".tmp"

    case File.open(temp, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result = :file.write(io, content)
        close_result = File.close(io)

        case {result, close_result} do
          {:ok, :ok} -> {:ok, temp}
          {{:error, reason}, _close} -> cleanup_temp_error(temp, reason)
          {_write, {:error, reason}} -> cleanup_temp_error(temp, reason)
        end

      {:error, :eexist} ->
        {:error, :projection_temp_exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A commit whose canonical stage failed mid-flight (e.g. a Pool open timing
  # out under load) leaves DocFs's in-flight entry unresolved and wedges every
  # later exclusive create with :projection_temp_exists — sometimes without any
  # lstat-visible `.tmp` at all (take10: the reservation lives in OpenDocs, not
  # on disk). Whichever shape the wedge takes, give the existing canonical
  # retry one chance to resolve the stuck commit, then re-stage once.
  defp stage_temp(state, target, content) do
    case stage_temp_once(target, content) do
      {:error, :projection_temp_exists} ->
        _ = Ecrits.Fuse.DocFs.flush_canonical(state.root)
        stage_temp_once(target, content)

      other ->
        other
    end
  end

  defp stage_temp_once(target, content) do
    with :ok <- clear_stale_temp(target) do
      create_temp_exclusive(target, content)
    end
  end

  # The exact `.tmp` name is reserved by the DocFs commit protocol. A killed
  # handler can leave a regular single-link staging file behind; remove only
  # that safe shape while rejecting links and every other filesystem object.
  defp clear_stale_temp(target) do
    temp = target <> ".tmp"

    case File.lstat(temp) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        case File.stat(temp) do
          {:ok, %File.Stat{type: :regular, links: 1}} -> File.rm(temp)
          {:ok, %File.Stat{type: :regular}} -> {:error, :projection_temp_exists}
          {:ok, _stat} -> {:error, :projection_temp_exists}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _stat} ->
        {:error, :projection_temp_exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp projection_still_current(state, target, expected_sha256) do
    result =
      with {:ok, ^target} <- active_projection(state),
           :ok <- unchanged_projection(target, expected_sha256) do
        :ok
      end

    if result != :ok, do: File.rm(target <> ".tmp")
    result
  end

  defp cleanup_temp_error(temp, reason) do
    _ = File.rm(temp)
    {:error, reason}
  end

  defp unchanged_projection(target, expected_sha256) do
    with {:ok, content} <- File.read(target) do
      if sha256(content) == expected_sha256,
        do: :ok,
        else: {:error, :stale_projection}
    end
  end

  defp expected_sha256(opts) when is_map(opts) do
    case Map.get(opts, "expectedSha256") || Map.get(opts, :expected_sha256) do
      hash when is_binary(hash) and byte_size(hash) == 64 -> {:ok, String.downcase(hash)}
      _missing -> {:error, :conditional_write_required}
    end
  end

  defp expected_sha256(_opts), do: {:error, :conditional_write_required}

  defp sha256(content),
    do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp source_path(_root, nil), do: nil
  defp source_path(_root, ""), do: nil

  defp source_path(root, document_path) when is_binary(document_path) do
    expanded = Path.expand(document_path, root)
    relative = Path.relative_to(expanded, root)

    case Path.safe_relative(relative, root) do
      {:ok, safe_relative} -> Path.join(root, safe_relative)
      :error -> nil
    end
  end

  # `doc.open_doc` is the authority for the projection name. Nested source paths
  # are flattened (and collisions may be disambiguated), so deriving a mount
  # path from the source string would authorize a path that does not exist.
  defp active_projection(state) do
    with {:ok, context} <- access_context(state),
         source when is_binary(source) <- source_path(state.root, context.document_path),
         {:ok, name} <- OpenDocs.name_for_source(state.root, source),
         :ok <- owner_matches(context, OpenDocs.owner_identity_for_source(state.root, source)) do
      {:ok, Path.join(DocMount.mount_point(state.root), Projection.projected_name(name))}
    else
      nil -> {:error, :no_active_projection}
      :error -> {:error, :document_not_open}
      {:error, _reason} = error -> error
    end
  end

  defp access_context(%{session_pid: pid, root: root}) when is_pid(pid) do
    if Process.alive?(pid) do
      context = Session.tool_context(pid)

      if DocMount.canonical_root(context.workspace_root || "") == root do
        {:ok, context}
      else
        {:error, :wrong_workspace}
      end
    else
      {:error, :agent_session_unavailable}
    end
  catch
    :exit, _reason -> {:error, :agent_session_unavailable}
  end

  defp access_context(%{document_path: path, expected_identity: identity})
       when is_binary(path) and is_map(identity) do
    {:ok, Map.put(identity, :document_path, path)}
  end

  defp access_context(_state), do: {:error, :missing_edit_identity}

  # Ownership is a compare-and-swap guard, but its two failure modes need
  # different words: the SAME agent whose new turn merely has not re-opened
  # yet gets an actionable instruction (2026-07-19 field report — the vague
  # "owner changed" made the agent guess at reconnection), while a genuinely
  # foreign owner stays a hard refusal.
  defp owner_matches(context, owner) do
    same? = fn key ->
      expected = Map.get(context, key)
      is_binary(expected) and expected != "" and Map.get(owner, key) == expected
    end

    cond do
      Enum.all?([:agent_id, :instance_id, :turn_id], same?) -> :ok
      Enum.all?([:agent_id, :instance_id], same?) -> {:error, :projection_reopen_required}
      true -> {:error, :projection_owner_changed}
    end
  end

  defp hidden_path?(relative) do
    relative
    |> Path.split()
    |> Enum.any?(&String.starts_with?(&1, "."))
  end

  defp format_error({:invalid_jsonl, line_number}), do: "invalid JSONL at line #{line_number}"

  # The detailed structural rejection is the #452 payoff: the ACP write reply
  # tells the agent WHAT was structural instead of a bare EINVAL-shaped atom.
  # The paragraph pointer matters: agents read "structural" as "impossible"
  # when adding paragraphs is a supported native op (2026-07-19 field:
  # "문서에 새 문단을 구조적으로 추가할 수는 없어서").
  defp format_error({:structural_change, detail}) when is_binary(detail),
    do:
      "structural_change: #{detail} — reread the mounted file and restage from " <>
        "the fresh read; to ADD a new paragraph, use doc.find for the anchor " <>
        "then doc.edit {op: \"insert_paragraph\", ref, text} instead"

  defp format_error(:approval_required_ask_mode),
    do:
      "the rail is in Ask mode: this write needs the user's approval — relay the " <>
        "exact change you want to make and ask them to approve it in chat or switch " <>
        "the rail to Full workspace, then retry"

  defp format_error(:projection_reopen_required),
    do:
      "this turn has not opened the document projection yet — call doc.open_doc " <>
        "{path: \"current\"} once, then retry this file operation"

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
