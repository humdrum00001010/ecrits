defmodule Contract.Local.Agent.DocumentTools do
  @moduledoc """
  Local agent document tools backed by live local RHWP positional snapshots.
  """

  alias Contract.Local.Metadata
  alias Contract.Local.Document
  alias Contract.MCP.Projection
  alias Contract.RhwpSnapshot.Materializer

  @read_default_size 5
  @read_max_size 10
  @materializer_timeout 15_000

  @doc "Read a compact positional paragraph window from the active local document."
  def read(target, args) when is_map(args) do
    with {:ok, %Document{} = document} <- document(target),
         {:ok, ir} <- current_ir(document, args) do
      sec = int_arg(args, "sec", 0)
      at = int_arg(args, "at", 0)
      size = args |> int_arg("size", @read_default_size) |> bounded_limit(@read_max_size)
      index = Projection.positional_index(ir)

      read = Projection.read_window(ir, sec, at, size)

      read =
        Map.put(
          read,
          "items",
          annotate_items_with_positions(Map.get(read, "items", []), index)
        )

      {:ok,
       read
       |> Map.put("document_id", document.id)
       |> Map.put("relative_path", document.relative_path)
       |> Map.put("format", document.format)
       |> Map.put("revision", document.revision)
       |> Map.put("counts", counts(ir, index))}
    end
  end

  def read(target, _args), do: read(target, %{})

  @doc "Apply a text edit through the active local document's live RHWP positional index."
  def write(target, args) when is_map(args) do
    with {:ok, %Document{} = document} <- document(target),
         {:ok, ir} <- current_ir(document, args),
         {:ok, write} <- normalize_write_args(args),
         :ok <- verify_base_revision(document, write),
         {:ok, events} <- write_events(ir, write),
         {:ok, committed} <- materialize_write(document, events, args) do
      {:ok,
       %{
         "ok" => true,
         "document_id" => document.id,
         "relative_path" => document.relative_path,
         "revision" => committed.revision,
         "events" => length(events)
       }}
    end
  end

  def write(_target, _args), do: {:error, :invalid_document_tool_args}

  defp document({:document_id, document_id}) when is_binary(document_id),
    do: Document.document(document_id)

  defp document(target), do: Document.document(target)

  defp current_ir(%Document{} = document, args) do
    case context_ir(document) do
      {:ok, ir} ->
        {:ok, normalize_ir(ir, document)}

      {:error, _reason} ->
        refresh_current_ir(document, args)
    end
  end

  defp context_ir(%Document{} = document) do
    with {:ok, %{"context" => %{} = ir}} <-
           Metadata.read_json(
             document.workspace_root,
             Path.join(["contexts", "#{document.id}.json"])
           ),
         true <- map_size(ir) > 0,
         true <- is_list(Map.get(ir, "sections")) do
      {:ok, ir}
    else
      _ -> {:error, :positional_index_unavailable}
    end
  end

  defp refresh_current_ir(%Document{} = document, args) do
    min_revision = int_arg(args, "min_revision", document.revision)
    timeout = int_arg(args, "timeout_ms", @materializer_timeout)

    with {:ok, _snapshot} <-
           Materializer.ensure_committed(document.id, min_revision,
             timeout: timeout,
             text_events: []
           ),
         {:ok, %Document{} = document} <- Document.document(document.id),
         {:ok, ir} <- context_ir(document) do
      {:ok, normalize_ir(ir, document)}
    else
      {:error, reason} -> {:error, {:positional_index_unavailable, reason}}
    end
  end

  defp normalize_ir(ir, %Document{} = document) do
    ir
    |> Map.put("revision", document.revision)
    |> Map.put_new("title", Path.basename(document.relative_path))
    |> Map.put_new("contract_type", nil)
    |> Map.update("sections", [], &List.wrap/1)
  end

  defp counts(ir, index) do
    %{
      "sections" => length(Map.get(ir, "sections", [])),
      "paragraphs" => Projection.paragraph_count(ir),
      "pages" => length(Map.get(index, "pages", [])),
      "paragraph_refs" => length(Map.get(index, "paragraph_refs", [])),
      "table_controls" => length(Map.get(index, "table_controls", [])),
      "table_cells" => Map.get(index, "table_cell_count", 0)
    }
  end

  defp annotate_items_with_positions(items, index) do
    refs =
      index
      |> Map.get("paragraph_refs", [])
      |> Enum.group_by(&{Map.get(&1, "sec"), Map.get(&1, "para")})

    Enum.map(items, fn item ->
      case Map.get(refs, {Map.get(item, "sec"), Map.get(item, "para")}) do
        [ref | _] ->
          item
          |> maybe_put("page", Map.get(ref, "page"))
          |> maybe_put("off_start", Map.get(ref, "off_start"))
          |> maybe_put("off_end", Map.get(ref, "off_end"))

        _ ->
          item
      end
    end)
  end

  defp normalize_write_args(args) do
    with {:ok, sec} <- required_int(args, "sec"),
         {:ok, para} <- required_int(args, "para"),
         {:ok, type} <- required_string(args, "type"),
         {:ok, base_revision} <- required_int(args, "base_revision"),
         {:ok, payload} <- required_map(args, "payload"),
         {:ok, cmd} <- required_string(payload, "cmd"),
         {:ok, inner_payload} <- required_map(payload, "payload"),
         :ok <- validate_write_type(type) do
      {:ok,
       %{
         "sec" => sec,
         "para" => para,
         "type" => type,
         "base_revision" => base_revision,
         "payload" => %{"cmd" => cmd, "payload" => stringify_keys(inner_payload)}
       }}
    end
  end

  defp validate_write_type("paragraph"), do: :ok

  defp validate_write_type(type),
    do: {:error, {:not_supported, "write type=#{type} is not supported"}}

  defp verify_base_revision(%Document{revision: revision}, %{"base_revision" => base_revision})
       when base_revision <= revision,
       do: :ok

  defp verify_base_revision(%Document{revision: revision}, %{"base_revision" => base_revision}) do
    {:error, {:stale_revision, expected: revision, got: base_revision}}
  end

  defp write_events(ir, %{
         "sec" => sec,
         "para" => para,
         "payload" => %{"cmd" => cmd, "payload" => payload}
       })
       when cmd in ["insert_after_match", "insert_before_match"] do
    with {:ok, paragraph_text} <- paragraph_text(ir, sec, para),
         {:ok, match} <- required_string(payload, "match"),
         {:ok, text} <- required_string(payload, "text"),
         {:ok, match_start} <- unique_match_offset(paragraph_text, match) do
      off =
        case cmd do
          "insert_after_match" -> match_start + String.length(match)
          "insert_before_match" -> match_start
        end

      {:ok, [insert_text_event(sec, para, off, text)]}
    end
  end

  defp write_events(ir, %{
         "sec" => sec,
         "para" => para,
         "payload" => %{"cmd" => "insert_at_offset", "payload" => payload}
       }) do
    with {:ok, paragraph_text} <- paragraph_text(ir, sec, para),
         {:ok, off} <- required_int(payload, "off"),
         :ok <- validate_insert_offset(paragraph_text, off),
         {:ok, text} <- required_string(payload, "text") do
      {:ok, [insert_text_event(sec, para, off, text)]}
    end
  end

  defp write_events(ir, %{
         "sec" => sec,
         "para" => para,
         "payload" => %{"cmd" => "insert_paragraph_after", "payload" => payload}
       }) do
    with {:ok, paragraph_text} <- paragraph_text(ir, sec, para),
         {:ok, text} <- required_string(payload, "text") do
      off = String.length(paragraph_text)

      {:ok,
       [
         %{"kind" => "insert_paragraph", "sec" => sec, "para" => para, "off" => off},
         insert_text_event(sec, para + 1, 0, text)
       ]}
    end
  end

  defp write_events(ir, %{
         "sec" => sec,
         "para" => para,
         "payload" => %{"cmd" => "replace_range", "payload" => payload}
       }) do
    with {:ok, paragraph_text} <- paragraph_text(ir, sec, para),
         {:ok, off} <- required_int(payload, "off"),
         {:ok, count} <- required_int(payload, "count"),
         :ok <- validate_replace_range(paragraph_text, off, count),
         {:ok, text} <- required_string(payload, "text") do
      {:ok,
       [
         delete_text_event(sec, para, off, count),
         insert_text_event(sec, para, off, text)
       ]}
    end
  end

  defp write_events(ir, %{
         "sec" => sec,
         "para" => para,
         "payload" => %{"cmd" => "replace_paragraph", "payload" => payload}
       }) do
    with {:ok, paragraph_text} <- paragraph_text(ir, sec, para),
         {:ok, text} <- required_string(payload, "text") do
      {:ok,
       [
         delete_text_event(sec, para, 0, String.length(paragraph_text)),
         insert_text_event(sec, para, 0, text)
       ]}
    end
  end

  defp write_events(_ir, %{"payload" => %{"cmd" => cmd}}),
    do: {:error, {:invalid_params, "unsupported write command #{inspect(cmd)}"}}

  defp paragraph_text(ir, sec, para) do
    case Projection.paragraph_text_at(ir, sec, para) do
      text when is_binary(text) -> {:ok, text}
      _ -> {:error, {:invalid_params, "paragraph not found at sec=#{sec}, para=#{para}"}}
    end
  end

  defp unique_match_offset(text, match) do
    offsets = match_offsets(text, match)

    case offsets do
      [offset] -> {:ok, offset}
      [] -> {:error, {:invalid_params, "match not found in paragraph"}}
      _ -> {:error, {:invalid_params, "match is ambiguous in paragraph"}}
    end
  end

  defp match_offsets(text, match) do
    text_graphemes = String.graphemes(text)
    match_graphemes = String.graphemes(match)
    match_len = length(match_graphemes)
    max_start = length(text_graphemes) - match_len

    if match_len == 0 or max_start < 0 do
      []
    else
      for idx <- 0..max_start,
          Enum.slice(text_graphemes, idx, match_len) == match_graphemes,
          do: idx
    end
  end

  defp validate_insert_offset(text, off) do
    if off <= String.length(text) do
      :ok
    else
      {:error, {:invalid_params, "off is outside paragraph bounds"}}
    end
  end

  defp validate_replace_range(text, off, count) do
    if off + count <= String.length(text) do
      :ok
    else
      {:error, {:invalid_params, "range is outside paragraph bounds"}}
    end
  end

  defp insert_text_event(sec, para, off, text) do
    %{
      "kind" => "insert_text",
      "sec" => sec,
      "para" => para,
      "off" => off,
      "text" => text,
      "len" => String.length(text),
      "event_id" => "local-agent-#{Ecto.UUID.generate()}"
    }
  end

  defp delete_text_event(sec, para, off, count) do
    %{
      "kind" => "delete_text",
      "sec" => sec,
      "para" => para,
      "off" => off,
      "count" => count,
      "len" => count,
      "event_id" => "local-agent-#{Ecto.UUID.generate()}"
    }
  end

  defp materialize_write(%Document{} = document, events, args) do
    min_revision = document.revision + 1
    timeout = int_arg(args, "timeout_ms", @materializer_timeout)

    with {:ok, committed} <-
           Materializer.ensure_committed(document.id, min_revision,
             timeout: timeout,
             text_events: events
           ),
         {:ok, %Document{} = document} <- Document.document(document.id) do
      {:ok, Map.put(committed, :revision, document.revision)}
    end
  end

  defp required_int(args, key) do
    case Map.get(args, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_params, "#{key} (non-negative integer) is required"}}
    end
  end

  defp required_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_params, "#{key} (non-empty string) is required"}}
    end
  end

  defp required_map(args, key) do
    case Map.get(args, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_params, "#{key} (object) is required"}}
    end
  end

  defp int_arg(args, key, default) do
    case Map.get(args, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp bounded_limit(value, max_value) when is_integer(value), do: max(1, min(value, max_value))
  defp bounded_limit(_value, _max_value), do: @read_default_size

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
