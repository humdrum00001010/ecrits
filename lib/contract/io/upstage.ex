defmodule Contract.IO.Upstage do
  @moduledoc """
  Upstage Document Parse client (multipart upload + element normalization).

  See `/tmp/wave1-research.md` §4 for the verified request/response shape.
  """

  alias Contract.Types, as: T

  @default_endpoint "https://api.upstage.ai/v1/document-ai/document-parse"
  @default_timeout 60_000

  @doc """
  Streams a LiveView upload to a tempfile, uploads the raw source to R2,
  parses it with Upstage Document Parse, and returns an
  `Action(:create_document)` whose payload contains the normalized node
  tree plus the R2 artifact id.

  The `upload` argument is typically a `Phoenix.LiveView.UploadEntry`,
  consumed via `consume_uploaded_entry/3`. For tests, callers may pass a
  map `%{path: tmpfile_path, client_name: name, client_size: bytes,
  client_type: mime}`.
  """
  @spec import_upload(T.ctx(), T.matter_id(), map() | T.upload()) ::
          {:ok, Contract.Action.t()} | {:error, term()}
  def import_upload(_ctx, matter_id, upload) do
    with {:ok, info} <- read_upload(upload),
         artifact_id <- Ecto.UUID.generate(),
         {:ok, _r2} <- upload_source(matter_id, artifact_id, info),
         {:ok, parsed} <- parse(info.path, []) do
      nodes = normalize_elements(parsed.elements)
      node_order = Enum.map(nodes, & &1["id"])

      action = %Contract.Action{
        kind: :create_document,
        matter_id: matter_id,
        actor_type: :system,
        idempotency_key: "import:#{artifact_id}",
        payload: %{
          "artifact_id" => artifact_id,
          "title" => info.title,
          "mime_type" => info.mime_type,
          "byte_size" => info.byte_size,
          "nodes" => nodes,
          "node_order" => node_order,
          "source" => %{
            "kind" => "r2",
            "key" => source_key(matter_id, artifact_id, info),
            "bytes" => info.byte_size
          }
        }
      }

      {:ok, action}
    end
  end

  @doc """
  Parses a file at `path` (or in-memory binary) with Upstage Document
  Parse. Returns the raw `elements`/`content` map on success.
  """
  @spec parse(binary() | Path.t(), keyword()) ::
          {:ok, %{elements: list(), content: map(), raw: map()}} | {:error, term()}
  def parse(file_or_path, opts \\ []) do
    cfg = Application.fetch_env!(:contract, :upstage)
    endpoint = Keyword.get(opts, :endpoint) || cfg[:endpoint] || @default_endpoint
    api_key = Keyword.get(opts, :api_key) || cfg[:api_key] || env!("UPSTAGE_API_KEY")
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    {file_part, _filename} = build_file_part(file_or_path)

    form = [
      document: file_part,
      ocr: Keyword.get(opts, :ocr, "auto"),
      coordinates: to_string(Keyword.get(opts, :coordinates, true)),
      output_formats: Jason.encode!(Keyword.get(opts, :output_formats, ["html", "markdown", "text"])),
      model: Keyword.get(opts, :model, "document-parse")
    ]

    request_opts =
      Keyword.merge(
        [
          headers: [{"authorization", "Bearer #{api_key}"}],
          form_multipart: form,
          receive_timeout: timeout
        ],
        Keyword.get(opts, :req_opts, [])
      )

    case Req.post(endpoint, request_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case to_map(body) do
          {:ok, map} ->
            {:ok,
             %{
               elements: Map.get(map, "elements", []),
               content: Map.get(map, "content", %{}),
               raw: map
             }}

          :error ->
            {:error, {:upstage_http, 200, body}}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:upstage_http, status, body}}

      {:error, reason} ->
        {:error, {:upstage_transport, reason}}
    end
  end

  defp to_map(body) when is_map(body), do: {:ok, body}

  defp to_map(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp to_map(_), do: :error

  @doc """
  Lower-level entry called by `Contract.IO.parse_source/3` after the raw
  source bytes are fetched (typically from R2).
  """
  @spec parse_source(T.ctx(), String.t(), keyword()) ::
          {:ok, %{elements: list(), content: map()}} | {:error, term()}
  def parse_source(_ctx, source_ref, opts) do
    with {:ok, body} <- fetch_source(source_ref) do
      parse(body, opts)
    end
  end

  @doc """
  Normalizes Upstage `elements[]` to the projection-node shape:
  `%{id, kind, content, attrs}`. Categories map to node kinds per the
  Spec's hard-IR taxonomy.
  """
  @spec normalize_elements([map()]) :: [map()]
  def normalize_elements(elements) when is_list(elements) do
    Enum.map(elements, &normalize_element/1)
  end

  defp normalize_element(elem) do
    category = Map.get(elem, "category", "paragraph")
    kind = map_category(category)
    content_map = Map.get(elem, "content", %{})

    base_attrs = %{
      "page" => Map.get(elem, "page"),
      "coordinates" => Map.get(elem, "coordinates"),
      "category" => category
    }

    attrs = Map.merge(base_attrs, table_attrs(kind, elem))

    %{
      "id" => to_node_id(elem),
      "kind" => kind,
      "content" => %{
        "text" => Map.get(content_map, "text", ""),
        "html" => Map.get(content_map, "html"),
        "markdown" => Map.get(content_map, "markdown")
      },
      "attrs" => attrs
    }
  end

  # IR-richness (task #37): derive HWPX-grade column widths from Upstage's cell
  # bounding boxes when the element is a table. Upstage returns a `cells` list
  # with per-cell `coordinates` (normalized 0..1 polygon corners) and/or an
  # explicit `column_widths` array. We honor an explicit array first; otherwise
  # we derive widths from cell bboxes in the first row.
  defp table_attrs(:table, elem) do
    widths = derive_column_widths(elem)

    base =
      if widths == [], do: %{}, else: %{"column_widths" => widths}

    base
    |> maybe_put_str("border_fill_id", Map.get(elem, "border_fill_id"))
    |> maybe_put_int("header_row_count", Map.get(elem, "header_row_count"))
    |> maybe_put_int("footer_row_count", Map.get(elem, "footer_row_count"))
  end

  defp table_attrs(_kind, _elem), do: %{}

  defp derive_column_widths(elem) do
    cond do
      is_list(Map.get(elem, "column_widths")) ->
        elem
        |> Map.get("column_widths")
        |> Enum.filter(&(is_integer(&1) and &1 > 0))

      is_list(Map.get(elem, "cells")) ->
        derive_widths_from_cells(Map.get(elem, "cells"), Map.get(elem, "coordinates"))

      true ->
        []
    end
  end

  # Cells are expected to look like:
  #   %{"row" => r, "col" => c, "coordinates" => [%{"x" => _, "y" => _}, ...]}
  # We take only first-row cells, sort by col, and compute width per column.
  # The table bbox (`elem.coordinates`) is the [0,1]-normalized polygon for the
  # whole table; cells' coordinates use the same normalization. We scale to
  # HWP units (1/100 mm) using the table's pixel width if present, otherwise
  # we map directly to a default page width of ~16 cm (16000 HWP units).
  defp derive_widths_from_cells(cells, table_coords) do
    first_row =
      cells
      |> Enum.filter(fn c -> Map.get(c, "row", 0) == 0 end)
      |> Enum.sort_by(&Map.get(&1, "col", 0))

    case first_row do
      [] ->
        []

      cells_in_row ->
        table_span = bbox_x_span(table_coords) || 1.0
        page_width_hwp = 16_000

        Enum.map(cells_in_row, fn c ->
          span = bbox_x_span(Map.get(c, "coordinates")) || 0.0
          width = trunc(span / table_span * page_width_hwp)
          max(width, 1)
        end)
    end
  end

  defp bbox_x_span(nil), do: nil
  defp bbox_x_span([]), do: nil

  defp bbox_x_span(coords) when is_list(coords) do
    xs =
      coords
      |> Enum.map(fn pt ->
        cond do
          is_map(pt) -> Map.get(pt, "x") || Map.get(pt, :x)
          true -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&is_number/1)

    case xs do
      [] -> nil
      list -> Enum.max(list) - Enum.min(list)
    end
  end

  defp bbox_x_span(_), do: nil

  defp maybe_put_str(map, _key, nil), do: map
  defp maybe_put_str(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp maybe_put_str(map, _key, _other), do: map

  defp maybe_put_int(map, _key, nil), do: map

  defp maybe_put_int(map, key, value) when is_integer(value) and value >= 0,
    do: Map.put(map, key, value)

  defp maybe_put_int(map, _key, _other), do: map

  defp to_node_id(%{"id" => id}) when is_integer(id), do: "node:#{id}"
  defp to_node_id(%{"id" => id}) when is_binary(id), do: id
  defp to_node_id(_), do: "node:" <> Ecto.UUID.generate()

  defp map_category("paragraph"), do: :paragraph
  defp map_category("list"), do: :list
  defp map_category("list_item"), do: :list_item
  defp map_category("table"), do: :table
  defp map_category("figure"), do: :figure
  defp map_category("caption"), do: :caption
  defp map_category("footnote"), do: :footnote
  defp map_category("header"), do: :header
  defp map_category("footer"), do: :footer
  defp map_category("equation"), do: :equation

  defp map_category("heading1"), do: :heading
  defp map_category("heading2"), do: :heading
  defp map_category("heading3"), do: :heading
  defp map_category("heading4"), do: :heading
  defp map_category("heading5"), do: :heading
  defp map_category("heading6"), do: :heading
  defp map_category("heading"), do: :heading

  defp map_category(_other), do: :paragraph

  # --- upload helpers ----------------------------------------------------

  defp read_upload(%{path: path} = upload) do
    title = Map.get(upload, :client_name) || Map.get(upload, :title) || Path.basename(path)
    mime = Map.get(upload, :client_type) || Map.get(upload, :mime_type) || "application/octet-stream"

    case File.stat(path) do
      {:ok, %{size: size}} ->
        {:ok, %{path: path, title: title, mime_type: mime, byte_size: size}}

      {:error, reason} ->
        {:error, {:upload_stat_failed, reason}}
    end
  end

  defp read_upload(%Phoenix.LiveView.UploadEntry{} = entry) do
    {:error, {:upload_not_consumed, entry}}
  end

  defp read_upload(other), do: {:error, {:invalid_upload, other}}

  defp upload_source(matter_id, artifact_id, info) do
    case File.read(info.path) do
      {:ok, body} ->
        key = source_key(matter_id, artifact_id, info)
        Contract.IO.R2.put(key, body, content_type: info.mime_type)

      {:error, reason} ->
        {:error, {:upload_read_failed, reason}}
    end
  end

  defp source_key(matter_id, artifact_id, info) do
    ext = info.title |> Path.extname() |> String.trim_leading(".") |> default_ext()
    "matters/#{matter_id}/sources/#{artifact_id}.#{ext}"
  end

  defp default_ext(""), do: "bin"
  defp default_ext(ext), do: String.downcase(ext)

  defp build_file_part(path) when is_binary(path) do
    if File.exists?(path) do
      {File.read!(path), Path.basename(path)}
    else
      # Treat as raw bytes (e.g. from R2 fetch).
      {path, "document.bin"}
    end
  end

  defp build_file_part({:bytes, bytes, filename}) when is_binary(bytes),
    do: {bytes, filename}

  defp fetch_source("r2://" <> rest) do
    [_bucket, key] = String.split(rest, "/", parts: 2)
    Contract.IO.R2.get(key)
  end

  defp fetch_source(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, _} = err -> err
    end
  end

  defp env!(name) do
    case System.get_env(name) do
      val when is_binary(val) and val != "" -> val
      _ -> raise "missing required env var: #{name}"
    end
  end
end
