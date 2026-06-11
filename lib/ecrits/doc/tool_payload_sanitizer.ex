defmodule Ecrits.Doc.ToolPayloadSanitizer do
  @moduledoc """
  Presentation guard for `doc.*` tool payloads shown in chat rails.

  The document API is addressed by path/ref/attrs. Any legacy optimistic
  concurrency fields in old agent payloads are display noise and should not
  survive into public/tool payloads.
  """

  def encode_tool_payload(name, payload) when is_binary(payload) do
    sanitize_tool_body(name, payload)
  end

  def encode_tool_payload(name, payload) do
    payload = sanitize_tool_payload(name, payload)

    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(payload, pretty: true)
    end
  end

  def sanitize_tool_payload(name, payload) do
    cond do
      create_tool?(name) -> payload |> scrub() |> compact_create_payload()
      save_tool?(name) -> payload |> scrub() |> compact_save_payload()
      doc_tool?(name) -> scrub(payload)
      true -> payload
    end
  end

  def sanitize_tool_body(name, body) when is_binary(body) do
    if doc_tool?(name), do: sanitize_encoded_body(name, body), else: body
  end

  def sanitize_tool_body(_name, body), do: body

  defp doc_tool?("doc." <> _), do: true

  defp doc_tool?(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> doc_tool?()
  end

  defp doc_tool?(_name), do: false

  defp save_tool?("doc.save"), do: true

  defp save_tool?(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> save_tool?()
  end

  defp save_tool?(_name), do: false

  defp create_tool?("doc.create"), do: true

  defp create_tool?(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> create_tool?()
  end

  defp create_tool?(_name), do: false

  defp scrub(%{} = map) do
    map
    |> Enum.reject(fn {key, _value} -> legacy_doc_payload_key?(key) end)
    |> Map.new(fn {key, value} -> {key, scrub(value)} end)
  end

  defp scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)
  defp scrub(binary) when is_binary(binary), do: sanitize_embedded_json(binary)
  defp scrub(other), do: other

  defp sanitize_encoded_body(name, body) do
    with true <- json_container?(body),
         {:ok, decoded} <- Jason.decode(body),
         sanitized <- sanitize_tool_payload(name, decoded),
         {:ok, encoded} <- Jason.encode(sanitized, pretty: true) do
      encoded
    else
      _ -> body
    end
  end

  defp sanitize_embedded_json(binary) do
    with true <- json_container?(binary),
         {:ok, decoded} <- Jason.decode(binary),
         {:ok, encoded} <- Jason.encode(scrub(decoded)) do
      encoded
    else
      _ -> binary
    end
  end

  defp json_container?(binary) do
    binary
    |> String.trim_leading()
    |> String.starts_with?(["{", "["])
  end

  defp legacy_doc_payload_key?(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> legacy_doc_payload_key?()
  end

  defp legacy_doc_payload_key?(key) when is_binary(key) do
    key == "version" or key == "revision" or key == "rebased" or
      String.ends_with?(key, "_version") or String.ends_with?(key, "_revision")
  end

  defp legacy_doc_payload_key?(_key), do: false

  defp compact_save_payload(%{} = payload) do
    cond do
      ok_payload?(payload) ->
        %{"ok" => true}

      is_map(static_get(payload, "structuredContent")) and
          ok_payload?(static_get(payload, "structuredContent")) ->
        %{"ok" => true}

      content_ok_payload?(static_get(payload, "content")) ->
        %{"ok" => true}

      error = static_get(payload, "error") ->
        %{"error" => error}

      true ->
        payload
    end
  end

  defp compact_save_payload(payload), do: payload

  defp compact_create_payload(%{} = payload) do
    case static_get(payload, "deck") do
      %{} = deck -> Map.put(payload, "deck", compact_deck(deck))
      _other -> payload
    end
  end

  defp compact_create_payload(payload), do: payload

  defp compact_deck(deck) do
    slides =
      deck
      |> static_get("slides")
      |> case do
        list when is_list(list) -> list
        _other -> []
      end

    %{
      "title" => static_get(deck, "title"),
      "subtitle" => static_get(deck, "subtitle"),
      "slides" => length(slides),
      "slide_titles" =>
        slides
        |> Enum.map(&static_get(&1, "title"))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(8)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp ok_payload?(%{} = payload), do: static_get(payload, "ok") == true
  defp ok_payload?(_payload), do: false

  defp content_ok_payload?(content) when is_list(content) do
    Enum.any?(content, fn
      %{} = item ->
        with text when is_binary(text) <- static_get(item, "text"),
             true <- json_container?(text),
             {:ok, decoded} <- Jason.decode(text) do
          ok_payload?(decoded)
        else
          _ -> false
        end

      _other ->
        false
    end)
  end

  defp content_ok_payload?(_content), do: false

  defp static_get(map, "ok"), do: Map.get(map, "ok") || Map.get(map, :ok)
  defp static_get(map, "error"), do: Map.get(map, "error") || Map.get(map, :error)

  defp static_get(map, "structuredContent"),
    do: Map.get(map, "structuredContent") || Map.get(map, :structuredContent)

  defp static_get(map, "content"), do: Map.get(map, "content") || Map.get(map, :content)
  defp static_get(map, "text"), do: Map.get(map, "text") || Map.get(map, :text)
  defp static_get(map, "deck"), do: Map.get(map, "deck") || Map.get(map, :deck)
  defp static_get(map, "slides"), do: Map.get(map, "slides") || Map.get(map, :slides)
  defp static_get(map, "title"), do: Map.get(map, "title") || Map.get(map, :title)
  defp static_get(map, "subtitle"), do: Map.get(map, "subtitle") || Map.get(map, :subtitle)
end
