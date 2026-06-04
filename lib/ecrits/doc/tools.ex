defmodule Ecrits.Doc.Tools do
  @moduledoc """
  Reflective MCP tool surface for the document-editing abstraction (design §4.4).

  A *small* set of generic, document-addressed tools — every tool takes a
  `document` id and operates on that document (not just the one being viewed):

  | tool             | risk  | maps to |
  |------------------|-------|---------|
  | `doc.list`       | read  | `Pool.list/1` |
  | `doc.open`       | read  | `Pool.open/3` |
  | `doc.outline`    | read  | `Editor.outline/3` |
  | `doc.read`       | read  | `Editor.read/2` |
  | `doc.find`       | read  | `Editor.find/3` |
  | `doc.get`        | read  | `Editor.get/3` |
  | `doc.set`        | write | `Editor.set/4` (base_revision) |
  | `doc.edit`       | write | `Editor.apply/3` (base_revision) |
  | `doc.apply_style`| write | `Editor.apply_style/3` |
  | `doc.save`       | write | `Editor.save/2` |

  The deep Office tools (`office.inspect`/`office.call`/`office.dispatch`,
  design §4.4 "Office 전용 심화") are intentionally **not** part of this HWP
  surface; the LibreOffice backend is a separate effort.

  Tools run against a context map `%{pool: pool}` (defaults to the named
  `Ecrits.Doc.Pool`). Results are JSON-shaped maps so the layer is testable
  server-side without a browser or an MCP transport. Errors that the agent is
  expected to act on (conflict, capability gaps) are returned as structured
  maps mirroring the design's example payloads.
  """

  alias Ecrits.Doc.Editor
  alias Ecrits.Doc.Pool

  @namespace "doc"

  @tools [
    %{
      "namespace" => @namespace,
      "name" => "list",
      "description" => "List open/available documents (id, kind, path, revision, backing).",
      "risk" => "read",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}},
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "open",
      "description" => "Load a document into the pool. Returns {document, kind}.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "minLength" => 1},
          "kind" => %{"type" => "string", "enum" => ["hwp", "hwpx"]}
        },
        "required" => ["path"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "outline",
      "description" => "Structure tree: each node {ref, type, ...}. ref is opaque.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "depth" => %{"type" => "integer", "minimum" => 1}
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "read",
      "description" => "Read a text chunk from a document.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "at" => %{"type" => "integer", "minimum" => 0},
          "size" => %{"type" => "integer", "minimum" => 1}
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "find",
      "description" => "Literal search -> [{ref, text}].",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "pattern" => %{"type" => "string", "minLength" => 1},
          "case_sensitive" => %{"type" => "boolean", "default" => false}
        },
        "required" => ["document", "pattern"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "get",
      "description" => "Read native properties of an element (ref). props? selects names.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "props" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["document", "ref"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "set",
      "description" =>
        "Universal property edit. Routes to native setters. Honours base_revision.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "props" => %{"type" => "object"},
          "base_revision" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["document", "ref", "props"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "edit",
      "description" =>
        "Structural verb (insert_text/delete_range/replace_text/split/insert_node/...). Honours base_revision.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "op" => %{"type" => "object"},
          "base_revision" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["document", "op"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "apply_style",
      "description" => "Apply a named style to an element (ref).",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "style" => %{"type" => ["string", "object"]}
        },
        "required" => ["document", "ref", "style"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "save",
      "description" => "Persist the document to disk (export).",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"document" => %{"type" => "string"}},
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => false}
    }
  ]

  @doc "The MCP tool catalog for the document abstraction."
  @spec tools() :: [map()]
  def tools, do: @tools

  @doc "Canonical `namespace.name` for each tool."
  @spec tool_names() :: [String.t()]
  def tool_names, do: Enum.map(@tools, &(&1["namespace"] <> "." <> &1["name"]))

  @doc """
  Dispatch an MCP tool call.

  `ctx` is `%{pool: pool}` (defaults to the named `Ecrits.Doc.Pool`).
  """
  @spec call(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx \\ %{}, tool_name, args)

  def call(ctx, "doc.list", _args) do
    {:ok, %{"documents" => Enum.map(Pool.list(pool(ctx)), &entry_json/1)}}
  end

  def call(ctx, "doc.open", args) do
    with {:ok, path} <- require_string(args, "path") do
      kind = args |> get(["kind"]) |> normalize_kind()
      open_opts = args |> get(["open_opts"]) |> List.wrap()

      case Pool.open(pool(ctx), path, kind: kind, open_opts: open_opts) do
        {:ok, doc_id} ->
          {:ok, %{"document" => doc_id, "kind" => Atom.to_string(kind)}}

        {:error, reason} ->
          {:error, error_json(reason)}
      end
    end
  end

  def call(ctx, "doc.outline", args) do
    with_editor(ctx, args, fn editor ->
      ref = get(args, ["ref"])
      wrap(Editor.outline(editor, ref, depth: get(args, ["depth"])), "outline", &outline_json/1)
    end)
  end

  def call(ctx, "doc.read", args) do
    with_editor(ctx, args, fn editor ->
      opts = take_opts(args, ["at", "size", "ref"])
      wrap(Editor.read(editor, opts), &Map.merge(%{}, stringify(&1)))
    end)
  end

  def call(ctx, "doc.find", args) do
    with {:ok, pattern} <- require_string(args, "pattern") do
      with_editor(ctx, args, fn editor ->
        opts = take_opts(args, ["case_sensitive"])

        case Editor.find(editor, pattern, opts) do
          {:ok, matches} ->
            {:ok, %{"pattern" => pattern, "matches" => Enum.map(matches, &stringify/1)}}

          {:error, reason} ->
            {:error, error_json(reason)}
        end
      end)
    end
  end

  def call(ctx, "doc.get", args) do
    with {:ok, ref} <- require_string(args, "ref") do
      with_editor(ctx, args, fn editor ->
        props = get(args, ["props"])
        wrap(Editor.get(editor, ref, props), &stringify/1)
      end)
    end
  end

  def call(ctx, "doc.set", args) do
    with {:ok, ref} <- require_string(args, "ref"),
         {:ok, props} <- require_map(args, "props") do
      with_editor(ctx, args, fn editor ->
        base_rev = get(args, ["base_revision"])
        write_result(Editor.set(editor, ref, props, base_rev))
      end)
    end
  end

  def call(ctx, "doc.edit", args) do
    with {:ok, op} <- require_map(args, "op") do
      with_editor(ctx, args, fn editor ->
        base_rev = get(args, ["base_revision"])
        write_result(Editor.apply(editor, op, base_rev))
      end)
    end
  end

  def call(ctx, "doc.apply_style", args) do
    with {:ok, ref} <- require_string(args, "ref"),
         {:ok, style} <- require_present(args, "style") do
      with_editor(ctx, args, fn editor ->
        write_result(Editor.apply_style(editor, ref, style))
      end)
    end
  end

  def call(ctx, "doc.save", args) do
    with_editor(ctx, args, fn editor ->
      case Editor.save(editor, []) do
        :ok -> {:ok, %{"ok" => true}}
        {:error, reason} -> {:error, error_json(reason)}
      end
    end)
  end

  def call(_ctx, tool_name, _args), do: {:error, {:unknown_tool, tool_name}}

  # --- dispatch helpers ----------------------------------------------------

  defp with_editor(ctx, args, fun) do
    with {:ok, document} <- require_string(args, "document") do
      case Pool.route(pool(ctx), document) do
        {:server, editor} ->
          fun.(editor)

        {:browser, _lv} ->
          # Viewed-HWP authority is the browser WASM model; routing an agent op
          # to the LiveView is the live wiring left for follow-up (design §6.2).
          {:error, error_json({:not_supported, "browser-backed routing not wired yet"})}

        {:error, :not_found} ->
          {:error, error_json(:not_found)}
      end
    end
  end

  defp write_result({:ok, applied}) do
    {:ok,
     %{"ok" => true, "revision" => Map.get(applied, :revision)}
     |> maybe_put("invalidated", Map.get(applied, :invalidated))
     |> maybe_put("rebased", Map.get(applied, :rebased))}
  end

  defp write_result({:error, {:conflict, current_revision, snapshot}}) do
    {:error,
     %{
       "conflict" => true,
       "current_revision" => current_revision,
       "snapshot" => stringify(snapshot)
     }}
  end

  defp write_result({:error, reason}), do: {:error, error_json(reason)}

  defp wrap({:ok, value}, mapper) when is_function(mapper, 1), do: {:ok, mapper.(value)}
  defp wrap({:error, reason}, _mapper), do: {:error, error_json(reason)}

  defp wrap({:ok, value}, key, mapper), do: {:ok, %{key => mapper.(value)}}
  defp wrap({:error, reason}, _key, _mapper), do: {:error, error_json(reason)}

  defp outline_json(node) when is_map(node) do
    node
    |> stringify()
    |> Map.update("children", [], fn children -> Enum.map(children, &outline_json/1) end)
  end

  defp error_json({:not_supported, reason}),
    do: %{"not_supported" => true, "reason" => to_string(reason)}

  defp error_json({:stale_revision, details}),
    do: %{"error" => "stale_revision", "details" => stringify_kw(details)}

  defp error_json(:not_found), do: %{"error" => "not_found"}

  defp error_json({:unsupported_kind, kind}),
    do: %{"error" => "unsupported_kind", "kind" => to_string(kind)}

  defp error_json(reason) when is_atom(reason), do: %{"error" => to_string(reason)}
  defp error_json(reason), do: %{"error" => inspect(reason)}

  defp entry_json(%{} = entry) do
    %{
      "document" => entry.id,
      "kind" => to_string(entry.kind),
      "path" => entry.path,
      "revision" => entry.revision,
      "backing" => to_string(entry.backing)
    }
  end

  defp pool(ctx), do: Map.get(ctx, :pool, Ecrits.Doc.Pool)

  defp get(args, keys), do: get_in_args(args, keys)

  defp get_in_args(args, [key]) do
    Map.get(args, key, Map.get(args, to_string(key)))
  end

  defp take_opts(args, keys) do
    keys
    |> Enum.flat_map(fn key ->
      case get(args, [key]) do
        nil -> []
        value -> [{String.to_atom(key), value}]
      end
    end)
  end

  defp require_string(args, key) do
    case get(args, [key]) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_params, "#{key} (non-empty string) is required"}}
    end
  end

  defp require_map(args, key) do
    case get(args, [key]) do
      %{} = value -> {:ok, value}
      _ -> {:error, {:invalid_params, "#{key} (object) is required"}}
    end
  end

  defp require_present(args, key) do
    case get(args, [key]) do
      nil -> {:error, {:invalid_params, "#{key} is required"}}
      value -> {:ok, value}
    end
  end

  defp normalize_kind("hwpx"), do: :hwpx
  defp normalize_kind("hwp"), do: :hwp
  defp normalize_kind(:hwpx), do: :hwpx
  defp normalize_kind(_other), do: :hwp

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp stringify_kw(kw) when is_list(kw),
    do: Map.new(kw, fn {k, v} -> {to_string(k), v} end)

  defp stringify_kw(other), do: other
end
