defmodule Ecrits.Test.FakeEhwpRuntime do
  @moduledoc """
  In-process fake of the headless EHWP runtime NIF for `Ecrits.Doc` tests.

  Mirrors the *return shapes* of the real `ehwp_runtime` NIF (confirmed against
  `deps/ehwp/test/ehwp_test.exs`):

    * `read/2`  -> `{:ok, text :: binary}`
    * `find/3`  -> `{:ok, json :: binary}` where json is an array of matches
    * `write/3` for `{:replace_one, q, r}` -> `{:ok, json}` containing `"ok":true`

  Document content is held in an ETS-backed agent keyed by the native handle so
  that `write` is observable by a subsequent `read` (the real NIF mutates an
  in-memory model the same way). Injected via `config :ehwp, :runtime`.
  """

  @behaviour_funs ~w(available? open new page_count profile render_page_svg read find write
                     apply_op query export close)a

  def funs, do: @behaviour_funs

  def available?, do: true

  def open(path_or_binary, opts) when is_binary(path_or_binary) do
    text = Keyword.get(opts, :__text__, default_text(path_or_binary))

    handle = %{
      __fake_ehwp__: true,
      agent: start_agent(text),
      owner: Keyword.get(opts, :owner),
      elements: Keyword.get(opts, :__elements__)
    }

    metadata = %{page_count: 1, source_bytes: byte_size(path_or_binary)}
    {:ok, handle, metadata}
  end

  def open(_other, _opts), do: {:error, :invalid_input}

  def page_count(_handle), do: 1
  def profile(%{agent: agent}), do: %{text: text(agent)}

  def render_page_svg(_handle, page_index),
    do: {:ok, "<svg data-page=\"#{page_index}\"></svg>", %{page_index: page_index}}

  def read(%{agent: agent}, _opts), do: {:ok, text(agent)}
  def read(_handle, _opts), do: {:error, :invalid_handle}

  def find(%{agent: agent}, pattern, opts) do
    case_sensitive = Keyword.get(opts, :case_sensitive, false)
    body = text(agent)
    matches = literal_matches(body, pattern, case_sensitive)
    {:ok, Jason.encode!(matches)}
  end

  def find(_handle, _pattern, _opts), do: {:error, :invalid_handle}

  def write(%{agent: agent}, {:replace_one, query, replacement}, opts) do
    case_sensitive = Keyword.get(opts, :case_sensitive, false)
    body = text(agent)

    case do_replace_one(body, query, replacement, case_sensitive) do
      {:ok, new_body} ->
        put_text(agent, new_body)
        {:ok, Jason.encode!(%{ok: true, replaced: 1})}

      :not_found ->
        {:ok, Jason.encode!(%{ok: false, replaced: 0})}
    end
  end

  def write(_handle, _op, _opts), do: {:error, :unsupported_write}

  # Mint a NEW blank document (engine template analogue): an empty text buffer.
  def new(opts \\ []) do
    handle = %{__fake_ehwp__: true, agent: start_agent(""), owner: Keyword.get(opts, :owner)}
    {:ok, handle, %{page_count: 1, source_bytes: 0}}
  end

  # IR-direct edit surface (the real NIF's `apply_op`). Mirrors its contract:
  # `ops` is a list of atom-keyed verb maps with the ref pre-flattened onto each
  # op (section/paragraph/offset/...); returns `{:ok, results_json}` on success
  # (a JSON array of per-op results, like the native NIF) or
  # `{:error, {index, kind, message}}` for the first op the engine cannot apply.
  # Edits mutate the agent-held text so a subsequent `read` observes them — the
  # same way the real in-memory IR mutates.
  def apply_op(%{agent: agent}, ops, _bins) when is_list(ops) do
    apply_ops(agent, ops, 0, [])
  end

  def apply_op(_handle, _ops, _bins), do: {:error, :invalid_handle}

  # Property read/query surface (`get_properties`, etc.). The fake holds only
  # plain text — it has no property model — so report an honest unsupported
  # error, mirroring the headless NIF's current capability gap.
  def query(%{agent: agent} = handle, query) when is_map(query) do
    case Map.get(query, :q) || Map.get(query, "q") do
      "elements" ->
        if is_pid(Map.get(handle, :owner)), do: send(handle.owner, {:fake_ehwp_query, "elements"})

        elements =
          case Map.get(handle, :elements) do
            elements when is_list(elements) -> elements
            _ -> fake_elements(text(agent))
          end

        {:ok, Jason.encode!(elements)}

      _ ->
        {:error,
         {:unsupported_query, to_string(Map.get(query, :q) || Map.get(query, "q") || "query")}}
    end
  end

  def query(_handle, _query), do: {:error, :invalid_handle}

  defp fake_elements(body) do
    body
    |> paragraphs()
    |> Enum.with_index()
    |> Enum.map(fn {text, index} ->
      %{
        "type" => "paragraph",
        "text" => text,
        "ref" => %{"section" => 0, "paragraph" => index, "offset" => 0}
      }
    end)
  end

  # Serialize the current document back to bytes (the real NIF's `export`). The
  # fake's "canonical bytes" are simply the current text, which is enough to
  # exercise the save -> File.write round-trip server-side.
  def export(%{agent: agent}, format) when format in [:hwp, :hwpx] do
    _ = format
    {:ok, text(agent)}
  end

  def export(_handle, _format), do: {:error, :unsupported_format}

  def close(%{agent: agent} = handle) do
    if Process.alive?(agent), do: Agent.stop(agent)
    if is_pid(handle[:owner]), do: send(handle.owner, {:closed, handle})
    :ok
  end

  def close(_handle), do: :ok

  # --- apply_op interpreter ------------------------------------------------

  # Apply each op in order against the agent's text buffer. The first op the
  # fake cannot model yields `{:error, {index, kind, message}}` (the native
  # error tuple shape `Ecrits.Doc.Rhwp.edit/2` decodes). All-applied -> the
  # JSON results array.
  defp apply_ops(_agent, [], _index, acc),
    do: {:ok, Jason.encode!(Enum.reverse(acc))}

  defp apply_ops(agent, [op | rest], index, acc) do
    case apply_one_op(agent, op) do
      {:ok, result} -> apply_ops(agent, rest, index + 1, [result | acc])
      {:error, kind, message} -> {:error, {index, kind, message}}
    end
  end

  defp apply_one_op(agent, op) do
    op = stringify_op(op)
    verb = op["op"] || inferred_op(op)
    body = text(agent)

    case do_op(verb, body, op) do
      {:ok, new_body, result} ->
        put_text(agent, new_body)
        {:ok, result}

      {:error, kind, message} ->
        {:error, kind, message}
    end
  end

  # Coerce typed ops and atom-keyed op maps to string keys (the fake works in
  # string keys, matching how the JSON the real NIF receives is keyed).
  defp stringify_op(%{__struct__: module} = op) when is_atom(module) do
    if function_exported?(module, :to_map, 1) do
      module.to_map(op)
    else
      op |> Map.from_struct() |> stringify_op()
    end
  end

  defp stringify_op(op) when is_map(op) do
    Map.new(op, fn {k, v} -> {to_string(k), v} end)
  end

  defp inferred_op(%{"kind" => _kind, "props" => _props}), do: "set_properties"
  defp inferred_op(%{"to" => _to, "props" => _props}), do: "apply_char_format"
  defp inferred_op(_op), do: nil

  defp do_op("replace_text", body, op) do
    query = op["query"]
    replacement = op["replacement"] || ""

    case do_replace_one(body, query, replacement, false) do
      {:ok, new_body} -> {:ok, new_body, %{"ok" => true, "replaced" => 1}}
      :not_found -> {:ok, body, %{"ok" => false, "replaced" => 0}}
    end
  end

  defp do_op("insert_text", body, op) do
    text_to_insert = op["text"] || ""
    paras = paragraphs(body)
    p = op["paragraph"] || 0
    off = op["offset"] || 0

    case Enum.at(paras, p) do
      nil ->
        {:error, :out_of_range, "paragraph #{p} out of range"}

      para ->
        new_para = insert_at(para, off, text_to_insert)
        {:ok, join(List.replace_at(paras, p, new_para)), %{"ok" => true}}
    end
  end

  defp do_op("delete_range", body, op) do
    paras = paragraphs(body)
    p = op["paragraph"] || 0
    off = op["offset"] || 0
    count = op["count"] || 0

    case Enum.at(paras, p) do
      nil -> {:error, :out_of_range, "paragraph #{p} out of range"}
      para -> {:ok, join(List.replace_at(paras, p, delete_at(para, off, count))), %{"ok" => true}}
    end
  end

  defp do_op("split", body, op) do
    paras = paragraphs(body)
    p = op["paragraph"] || 0
    off = op["offset"] || 0

    case Enum.at(paras, p) do
      nil ->
        {:error, :out_of_range, "paragraph #{p} out of range"}

      para ->
        {head, tail} = String.split_at(para, off)
        new_paras = List.replace_at(paras, p, head) |> List.insert_at(p + 1, tail)
        {:ok, join(new_paras), %{"ok" => true}}
    end
  end

  defp do_op(verb, _body, _op),
    do: {:error, :unsupported, "fake apply_op does not model verb #{verb}"}

  defp paragraphs(body), do: String.split(body, "\n")
  defp join(paras), do: Enum.join(paras, "\n")

  defp insert_at(str, off, ins) do
    {head, tail} = String.split_at(str, off)
    head <> ins <> tail
  end

  defp delete_at(str, off, count) do
    {head, rest} = String.split_at(str, off)
    {_dropped, tail} = String.split_at(rest, count)
    head <> tail
  end

  # --- helpers -------------------------------------------------------------

  defp default_text(path_or_binary) do
    if String.printable?(path_or_binary) and not String.contains?(path_or_binary, "/") and
         byte_size(path_or_binary) < 4096 do
      path_or_binary
    else
      "제1조 (목적)\n제2조 (계약기간)\n제3조 (대금지급)"
    end
  end

  defp start_agent(text) do
    {:ok, pid} = Agent.start_link(fn -> text end)
    pid
  end

  defp text(agent), do: Agent.get(agent, & &1)
  defp put_text(agent, text), do: Agent.update(agent, fn _ -> text end)

  defp literal_matches(body, pattern, case_sensitive) do
    {hay, needle} =
      if case_sensitive,
        do: {body, pattern},
        else: {String.downcase(body), String.downcase(pattern)}

    do_matches(hay, needle, body, 0, [])
  end

  defp do_matches(_hay, "", _body, _from, acc), do: Enum.reverse(acc)

  defp do_matches(hay, needle, body, from, acc) do
    case :binary.match(hay, needle, scope: {from, byte_size(hay) - from}) do
      {start, len} ->
        text = binary_part(body, start, len)
        match = %{"off" => start, "count" => len, "text" => text}
        do_matches(hay, needle, body, start + len, [match | acc])

      :nomatch ->
        Enum.reverse(acc)
    end
  end

  defp do_replace_one(body, query, replacement, case_sensitive) do
    {hay, needle} =
      if case_sensitive, do: {body, query}, else: {String.downcase(body), String.downcase(query)}

    case :binary.match(hay, needle) do
      {start, len} ->
        new_body =
          binary_part(body, 0, start) <>
            replacement <> binary_part(body, start + len, byte_size(body) - start - len)

        {:ok, new_body}

      :nomatch ->
        :not_found
    end
  end
end
