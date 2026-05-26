defmodule Contract.IO.IRRefiner do
  @moduledoc """
  Enriches Upstage's IR with field bindings (live-editable slots) and
  targeted clause polish patches. Source of truth for body content stays
  Upstage; this layer only adds slots and fixes Upstage's structural
  flattening for Korean legal documents.

  Two outputs only:

    1. `fields` + `field_bindings` — live-editable spans (money, dates,
       durations, percentages, party names, addresses, registration
       numbers) bound to character offsets inside specific nodes.
    2. `nodes_patch` — narrow surgical patches against Upstage's IR for
       cases where the document parser flattened structure (e.g.
       "제N조 (제목)" emitted as a paragraph rather than a heading, or
       multiple numbered items concatenated into one paragraph, or
       page-chrome paragraphs like "- 1 -").

  See task spec for the JSON schema and prompt; the LLM MUST NOT rewrite
  the whole document, only emit small additive patches.
  """

  require Logger

  @default_timeout 60_000

  # Cap the total node-content payload to keep prompts within the model's
  # context budget. Tail nodes beyond this are dropped and the final
  # retained node is marked truncated so the model knows the input was
  # capped.
  @char_budget 24_000

  @type node_map :: %{required(String.t()) => term()}
  @type refinement :: %{
          nodes_patch: [map()],
          fields: [map()],
          field_bindings: [map()]
        }

  @spec refine([node_map()], keyword()) :: {:ok, refinement()} | {:error, term()}
  def refine(nodes, opts \\ [])

  def refine(nodes, opts) when is_list(nodes) do
    cfg = Application.get_env(:contract, :openai, [])
    api_key = Keyword.get(opts, :api_key) || cfg[:api_key]

    if is_binary(api_key) and api_key != "" do
      do_refine(nodes, api_key, cfg, opts)
    else
      {:error, :no_api_key}
    end
  end

  def refine(_other, _opts), do: {:error, :invalid_nodes}

  # ----- internals --------------------------------------------------------

  defp do_refine(nodes, api_key, cfg, opts) do
    base_url = Keyword.get(opts, :base_url) || cfg[:base_url] || "https://api.openai.com/v1"
    endpoint = Keyword.get(opts, :endpoint) || endpoint_from(base_url)
    model = Keyword.get(opts, :model) || cfg[:default_model] || "gpt-5-mini"
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    body = build_request_body(nodes, model, cfg)

    req_opts =
      Keyword.merge(
        [
          headers: [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"}
          ],
          json: body,
          receive_timeout: timeout
        ],
        Keyword.get(opts, :req_opts, [])
      )

    case Req.post(endpoint, req_opts) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        response_body
        |> extract_text()
        |> parse_refinement()

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:openai_http, status, response_body}}

      {:error, reason} ->
        {:error, {:openai_transport, reason}}
    end
  end

  defp endpoint_from(base_url) do
    base_url
    |> String.trim_trailing("/")
    |> Kernel.<>("/responses")
  end

  defp build_request_body(nodes, model, cfg) do
    {budgeted_nodes, truncated?} = budget_nodes(nodes)
    user_payload = Jason.encode!(%{"nodes" => budgeted_nodes, "truncated" => truncated?})

    %{
      model: model,
      reasoning: %{effort: cfg[:reasoning_effort] || "high"},
      input: [
        %{role: "system", content: system_prompt()},
        %{role: "user", content: user_payload}
      ],
      text: %{
        format: %{
          type: "json_schema",
          name: "ir_refinement",
          strict: true,
          schema: json_schema()
        }
      }
    }
  end

  # Trim node-content to ~@char_budget characters total. We always keep
  # every node entry (so node_ids stay referenceable) but truncate or
  # drop content for tail nodes; the final retained node carries a
  # truncated marker.
  defp budget_nodes(nodes) do
    {acc, _used, truncated?} =
      Enum.reduce(nodes, {[], 0, false}, fn node, {acc, used, trunc?} ->
        text = node_text(node)
        size = byte_size(text)

        cond do
          trunc? ->
            {[shrink_node(node, "", true) | acc], used, true}

          used + size > @char_budget ->
            remaining = max(@char_budget - used, 0)
            head = String.slice(text, 0, remaining)
            {[shrink_node(node, head, true) | acc], used + byte_size(head), true}

          true ->
            {[shrink_node(node, text, false) | acc], used + size, false}
        end
      end)

    {Enum.reverse(acc), truncated?}
  end

  defp shrink_node(node, content, truncated?) do
    base = %{
      "id" => Map.get(node, "id"),
      "kind" => to_string(Map.get(node, "kind", "paragraph")),
      "content" => content
    }

    if truncated?, do: Map.put(base, "truncated", true), else: base
  end

  defp node_text(node) do
    case Map.get(node, "content") do
      %{} = m -> Map.get(m, "text") || ""
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  defp system_prompt do
    """
    You refine a Korean legal/regulatory IR that was extracted by Upstage Document Parse.

    Output ONLY a small set of patches; do NOT rewrite the whole document. Most nodes will already be correct — leave them alone. If nothing needs changing, return empty arrays.

    Two jobs:

    1) Extract live-editable fields (slots): money, dates, durations, percentages, party names, addresses, registration numbers. Emit one `field` per distinct slot, with a stable `key` (snake_case English: rent, due_date, term, late_penalty, party_a, ...). Bind each field to its appearance in a node via `field_bindings` (character offsets into that node's content).

    2) Clause polish — ONLY when Upstage flattened structure:
       - If a paragraph's content starts with "제N조 (...)" and includes the article title, replace it with a heading (level: 1) carrying just the article header + a paragraph for the body.
       - If a paragraph contains multiple numbered items concatenated ("1. ... 2. ... 11. ..."), replace it with a sequence of list_item nodes (ordered: true, number: "<n>"), one per item.
       - Drop page-chrome paragraphs whose only content is "- N -".

    Do NOT split well-formed paragraphs. Do NOT translate. Do NOT add commentary. Output JSON matching the schema.

    If the input was marked `truncated: true`, the tail of the document was clipped — focus on what you can see and do not invent ids for content you cannot read.
    """
  end

  defp json_schema do
    # OpenAI strict mode requires: every key in `properties` must also be in
    # `required`. To make a field "optional" we use nullable types
    # (e.g. ["string", "null"]). When the LLM has nothing to say it sends
    # null; we treat null and missing the same downstream.
    field_attrs_schema = %{
      "type" => ["object", "null"],
      "additionalProperties" => false,
      "required" => ["kind", "label"],
      "properties" => %{
        "kind" => %{
          "type" => ["string", "null"],
          "enum" => [
            "money",
            "date",
            "duration",
            "percent",
            "party",
            "address",
            "registration",
            "other",
            nil
          ]
        },
        "label" => %{"type" => ["string", "null"]}
      }
    }

    patch_with_node_schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["kind", "content", "attrs"],
      "properties" => %{
        "kind" => %{"type" => "string"},
        "content" => %{"type" => "string"},
        "attrs" => patch_attrs_schema()
      }
    }

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["nodes_patch", "fields", "field_bindings"],
      "properties" => %{
        "nodes_patch" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["action", "node_id", "kind", "attrs", "with"],
            "properties" => %{
              "action" => %{"type" => "string", "enum" => ["replace", "drop", "set_kind"]},
              "node_id" => %{"type" => "string"},
              "kind" => %{
                "type" => ["string", "null"],
                "enum" => [
                  "paragraph",
                  "heading",
                  "list",
                  "list_item",
                  "table",
                  "caption",
                  "equation",
                  "footer",
                  nil
                ]
              },
              "attrs" => patch_attrs_schema(),
              "with" => %{
                "type" => ["array", "null"],
                "items" => patch_with_node_schema
              }
            }
          }
        },
        "fields" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["id", "key", "value", "attrs"],
            "properties" => %{
              "id" => %{"type" => "string"},
              "key" => %{"type" => "string"},
              "value" => %{"type" => "string"},
              "attrs" => field_attrs_schema
            }
          }
        },
        "field_bindings" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["node_id", "field_id", "start", "end"],
            "properties" => %{
              "node_id" => %{"type" => "string"},
              "field_id" => %{"type" => "string"},
              "start" => %{"type" => "integer", "minimum" => 0},
              "end" => %{"type" => "integer", "minimum" => 0}
            }
          }
        }
      }
    }
  end

  # Responses-API shape: prefer `output_text` shortcut when present,
  # otherwise walk `output[].content[].text`. Returns "" on any shape
  # we don't recognise (treated as a parse failure → empty refinement).
  defp extract_text(body) when is_map(body) do
    cond do
      is_binary(body["output_text"]) ->
        body["output_text"]

      is_list(body["output"]) ->
        body["output"]
        |> Enum.flat_map(fn
          %{"content" => content} when is_list(content) -> content
          _ -> []
        end)
        |> Enum.map(fn
          %{"text" => text} when is_binary(text) -> text
          %{"text" => %{"value" => v}} when is_binary(v) -> v
          _ -> ""
        end)
        |> Enum.join("")

      true ->
        ""
    end
  end

  defp extract_text(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> extract_text(map)
      _ -> ""
    end
  end

  defp extract_text(_), do: ""

  defp parse_refinement(""), do: {:error, :empty_response}

  defp parse_refinement(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> {:ok, normalize_refinement(map)}
      {:error, _} = err -> err
    end
  end

  defp normalize_refinement(map) do
    %{
      nodes_patch: List.wrap(map["nodes_patch"]),
      fields: List.wrap(map["fields"]),
      field_bindings: List.wrap(map["field_bindings"])
    }
  end

  defp patch_attrs_schema do
    %{
      "anyOf" => [
        %{"type" => "null"},
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [],
          "properties" => %{}
        },
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["level"],
          "properties" => %{
            "level" => %{"type" => "integer", "minimum" => 1, "maximum" => 6}
          }
        },
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["number"],
          "properties" => %{"number" => %{"type" => "string"}}
        },
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["ordered"],
          "properties" => %{"ordered" => %{"type" => "boolean"}}
        },
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["ordered", "number"],
          "properties" => %{
            "ordered" => %{"type" => "boolean"},
            "number" => %{"type" => "string"}
          }
        }
      ]
    }
  end

  # ----- patch application ------------------------------------------------

  @doc """
  Applies a refinement's `nodes_patch` against the original nodes list +
  node_order. Returns `{updated_nodes, updated_node_order}`.

    * `"drop"` removes the target node entirely.
    * `"replace"` substitutes one or more new nodes (synthesized ids
      `"<orig>:1"`, `"<orig>:2"`, …) preserving the original position.
    * `"set_kind"` rewrites the target node's kind/attrs in place.

  Unknown actions and patches that reference missing node_ids are
  silently skipped (defensive — the LLM should not be able to break the
  pipeline).
  """
  @spec apply_patches([map()], [String.t()], [map()]) :: {[map()], [String.t()]}
  def apply_patches(nodes, node_order, patches)
      when is_list(nodes) and is_list(node_order) and is_list(patches) do
    by_id = Map.new(nodes, fn n -> {Map.get(n, "id"), n} end)

    {by_id, node_order} =
      Enum.reduce(patches, {by_id, node_order}, fn patch, {nodes_acc, order_acc} ->
        apply_patch(patch, nodes_acc, order_acc)
      end)

    new_nodes = Enum.map(node_order, &Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
    {new_nodes, node_order}
  end

  def apply_patches(nodes, node_order, _), do: {nodes, node_order}

  defp apply_patch(%{"action" => "drop", "node_id" => id}, by_id, order) do
    {Map.delete(by_id, id), Enum.reject(order, &(&1 == id))}
  end

  defp apply_patch(%{"action" => "set_kind", "node_id" => id} = patch, by_id, order) do
    case Map.fetch(by_id, id) do
      {:ok, node} ->
        kind = patch["kind"]
        extra_attrs = patch["attrs"] || %{}
        existing_attrs = Map.get(node, "attrs") || %{}
        merged_attrs = Map.merge(existing_attrs, extra_attrs)

        node =
          node
          |> maybe_put_kind(kind)
          |> Map.put("attrs", merged_attrs)

        {Map.put(by_id, id, node), order}

      :error ->
        {by_id, order}
    end
  end

  defp apply_patch(%{"action" => "replace", "node_id" => id, "with" => with_nodes}, by_id, order)
       when is_list(with_nodes) do
    case Enum.find_index(order, &(&1 == id)) do
      nil ->
        {by_id, order}

      idx ->
        new_nodes =
          with_nodes
          |> Enum.with_index(1)
          |> Enum.map(fn {node, n} -> mint_replacement(node, id, n) end)

        new_ids = Enum.map(new_nodes, &Map.get(&1, "id"))

        by_id =
          new_nodes
          |> Enum.reduce(Map.delete(by_id, id), fn n, acc -> Map.put(acc, n["id"], n) end)

        order = List.delete_at(order, idx) |> List.flatten() |> insert_ids_at(idx, new_ids)
        {by_id, order}
    end
  end

  defp apply_patch(_other, by_id, order), do: {by_id, order}

  defp maybe_put_kind(node, nil), do: node
  defp maybe_put_kind(node, kind) when is_binary(kind), do: Map.put(node, "kind", kind)
  defp maybe_put_kind(node, _), do: node

  defp mint_replacement(node, orig_id, ordinal) do
    %{
      "id" => "#{orig_id}:#{ordinal}",
      "kind" => Map.get(node, "kind", "paragraph"),
      "content" => Map.get(node, "content", ""),
      "attrs" => Map.get(node, "attrs", %{})
    }
  end

  defp insert_ids_at(list, idx, new_ids) do
    {head, tail} = Enum.split(list, idx)
    head ++ new_ids ++ tail
  end
end
