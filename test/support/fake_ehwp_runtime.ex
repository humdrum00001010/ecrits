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

  @behaviour_funs ~w(available? open page_count profile render_page_svg read find write close)a

  def funs, do: @behaviour_funs

  def available?, do: true

  def open(path_or_binary, opts) when is_binary(path_or_binary) do
    text = Keyword.get(opts, :__text__, default_text(path_or_binary))
    handle = %{__fake_ehwp__: true, agent: start_agent(text), owner: Keyword.get(opts, :owner)}
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

  def close(%{agent: agent} = handle) do
    if Process.alive?(agent), do: Agent.stop(agent)
    if is_pid(handle[:owner]), do: send(handle.owner, {:closed, handle})
    :ok
  end

  def close(_handle), do: :ok

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
