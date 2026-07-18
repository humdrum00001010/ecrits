defmodule Ecrits.Doc.Rhwp.Image do
  @moduledoc """
  Resolves an `insert_picture` op's `src` (a file path) into the fields each
  document arm needs — pure byte handling, no NIF.

    * `resolve_src/2` — the SERVER arm: produces the typed `%Ehwp.Op.InsertPicture{}`
      (at the given resolved ref) + the raw `bins` the NIF takes out-of-band by
      `:bin_index`, plus the natural pixel size. The engine PLACES the picture
      (fit-to-width capped to the paragraph's real placeable width); a
      caller-supplied `width`/`height` is honored unless it exactly matches the
      image's natural pixel dimensions and is too small for a readable document
      placement; that case is treated as a pixel/HWPUNIT mixup and normalized to
      the default placed size.
    * `for_browser/1` — the BROWSER (WASM) arm, which can't read the server
      filesystem, so it gets the bytes inline as `:image_base64` plus concrete
      placed dimensions when the agent supplied only `src`.

  Both read the file, derive the `extension`, and sniff the natural pixel dims
  from the image header (PNG IHDR / JPEG SOF / GIF). Ops without a `src` (or that
  already carry `:bins`) pass through untouched.
  """

  @doc """
  SERVER arm producer. Resolves an `insert_picture` op into the TYPED engine op:
  `{:ok, %Ehwp.Op.InsertPicture{}, bins}` where `bins` is the 1-element list of RAW
  image bytes the NIF batch consumes by `bin_index`. `at` is the already-resolved
  position (the caller owns ref flattening). The natural pixel size is sniffed
  from the header; the engine fits `width`/`height` from it (a caller may override
  either). Bytes come from caller-supplied `:bins` (base64) or `:src` on disk; a
  picture op with neither passes through as a map (the engine errors meaningfully).
  """
  @spec resolve_src(map(), Ehwp.Op.Ref.t()) ::
          {:ok, Ehwp.Op.InsertPicture.t(), [binary()]} | {:ok, map()} | {:error, map()}
  def resolve_src(%{op: "insert_picture"} = op, %Ehwp.Op.Ref{} = at) do
    case picture_bytes(op) do
      {:ok, bytes, ext_hint} ->
        actual_dims = pixel_dims(bytes, ext_hint)

        with :ok <- validate_declared_dims(op, actual_dims) do
          {nw, nh} = natural_dims(op, actual_dims)

          {width, height} = placed_size(op, nw, nh)

          pic =
            %Ehwp.Op.InsertPicture{
              at: at,
              bin_index: op[:bin_index] || 0,
              extension: present_string(op[:extension]) || ext_hint || "",
              width: width,
              height: height,
              natural_width_px: nw,
              natural_height_px: nh,
              description: op[:description] || "",
              inline_in_cell: op[:inline_in_cell] == true
            }
            |> Map.put(:overlay_marker_length, op[:overlay_marker_length] || 0)

          {:ok, pic, [bytes]}
        end

      :passthrough ->
        {:ok, op}

      {:error, _} = error ->
        error
    end
  end

  def resolve_src(op, _at), do: {:ok, op}

  # Raw image bytes (+ extension hint) for a picture op: prefer caller-supplied
  # `:bins` (base64), else read `:src` from disk. `:passthrough` when neither is
  # present (an insert_picture with no source — the engine reports it).
  defp picture_bytes(%{bins: [b64 | _]}) when is_binary(b64) and b64 != "" do
    case Base.decode64(b64) do
      {:ok, bytes} -> {:ok, bytes, nil}
      :error -> {:error, %{kind: "insert_picture", message: "invalid base64 in :bins"}}
    end
  end

  defp picture_bytes(%{src: src}) when is_binary(src) and src != "" do
    case read_file(src) do
      {:ok, bytes} -> {:ok, bytes, extension(src)}
      {:error, _} = error -> error
    end
  end

  defp picture_bytes(_op), do: :passthrough

  @doc """
  BROWSER arm producer. Emits `:image_base64` instead of the NIF `:bins` slice, so
  the browser editor can materialize the image in its WASM filesystem. If the
  agent supplied a bare inline `src`, fill `width`/`height` from the natural aspect
  ratio so browser HWP accepts the same minimal op the server arm accepts. Slide
  picture ops keep their `page`/`x`/`y`/`w`/`h` fields and only swap `src` for
  bytes. Non-picture / no-`src` ops pass through.
  """
  @spec for_browser(map()) :: {:ok, map()} | {:error, map()}
  def for_browser(%{op: "insert_picture", src: src} = op)
      when is_binary(src) and src != "" do
    with {:ok, bytes} <- read_file(src) do
      ext = extension(src)
      actual_dims = pixel_dims(bytes, ext)

      with :ok <- validate_declared_dims(op, actual_dims) do
        {nw, nh} = natural_dims(op, actual_dims)

        op =
          op
          |> default_inline_in_cell()
          |> Map.delete(:src)
          |> Map.put(:image_base64, Base.encode64(bytes))
          |> Map.put(:extension, present_string(op[:extension]) || ext)
          |> Map.put(:natural_width_px, nw)
          |> Map.put(:natural_height_px, nh)
          |> maybe_put_inline_browser_size(nw, nh)

        {:ok, op}
      end
    end
  end

  def for_browser(op), do: {:ok, op}

  # ── internals ──────────────────────────────────────────────────────────────

  @default_max_unit 22_000
  @marker_overlay_default_max_unit 5_000
  @inline_cell_default_max_unit 4_500

  defp default_inline_in_cell(%{inline_in_cell: inline} = op) when is_boolean(inline), do: op

  defp default_inline_in_cell(%{ref: ref} = op) do
    if cell_ref?(ref), do: Map.put(op, :inline_in_cell, true), else: op
  end

  defp default_inline_in_cell(op), do: op

  defp cell_ref?(%{cell: %{} = _cell}), do: true
  defp cell_ref?(%{"cell" => %{} = _cell}), do: true

  defp cell_ref?(ref) when is_binary(ref) do
    case Jason.decode(ref) do
      {:ok, %{} = decoded} ->
        cell_path = Map.get(decoded, "cellPath") || Map.get(decoded, "cell_path")
        is_list(cell_path) and cell_path != []

      _ ->
        false
    end
  end

  defp cell_ref?(_ref), do: false

  defp extension(src) do
    src
    |> file_source_path()
    |> Path.extname()
    |> String.trim_leading(".")
    |> String.downcase()
  end

  defp read_file(src) do
    path = file_source_path(src)

    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) > 0 ->
        {:ok, bytes}

      {:ok, _empty} ->
        {:error, %{kind: "insert_picture", message: "image file is empty: #{src}"}}

      {:error, reason} ->
        {:error,
         %{
           kind: "insert_picture",
           message: "cannot read image #{src}: #{:file.format_error(reason)}"
         }}
    end
  end

  defp present_string(s) when is_binary(s) and s != "", do: s
  defp present_string(_), do: nil

  defp declared_dims(%{natural_width_px: w, natural_height_px: h})
       when is_integer(w) and w > 0 and is_integer(h) and h > 0,
       do: {w, h}

  defp declared_dims(_op), do: nil

  defp natural_dims(op, {actual_w, actual_h} = actual) when actual_w > 0 and actual_h > 0 do
    declared_dims(op) || actual
  end

  defp natural_dims(op, _actual), do: declared_dims(op) || {0, 0}

  defp validate_declared_dims(_op, {0, 0}), do: :ok

  defp validate_declared_dims(op, actual) do
    case declared_dims(op) do
      nil ->
        :ok

      ^actual ->
        :ok

      {declared_w, declared_h} ->
        {actual_w, actual_h} = actual

        {:error,
         %{
           kind: "insert_picture",
           message:
             "image bytes are #{actual_w}x#{actual_h}px but natural_width_px/natural_height_px declare #{declared_w}x#{declared_h}px"
         }}
    end
  end

  defp maybe_put_inline_browser_size(%{page: page} = op, _nw, _nh) when is_binary(page),
    do: op

  defp maybe_put_inline_browser_size(op, nw, nh) do
    {width, height} = placed_size(op, nw, nh)

    op
    |> Map.put(:width, width)
    |> Map.put(:height, height)
  end

  defp file_source_path("file://" <> _ = url) do
    case URI.parse(url) do
      %URI{scheme: "file", host: host, path: path} when host in [nil, "", "localhost"] ->
        path |> to_string() |> URI.decode()

      _ ->
        url
    end
  end

  defp file_source_path(src), do: src

  defp placed_size(op, natural_width, natural_height) do
    width = positive_int(op[:width])
    height = positive_int(op[:height])
    max_unit = default_max_unit(op)

    cond do
      pixel_sized?(width, height, natural_width, natural_height) ->
        fit_size(natural_width, natural_height, max_unit)

      width && height ->
        {width, height}

      width ->
        {width, scaled_height(width, natural_width, natural_height)}

      height ->
        {scaled_width(height, natural_width, natural_height), height}

      true ->
        fit_size(natural_width, natural_height, max_unit)
    end
  end

  defp default_max_unit(%{overlay_marker_length: length})
       when is_integer(length) and length > 0,
       do: @marker_overlay_default_max_unit

  defp default_max_unit(%{inline_in_cell: true}), do: @inline_cell_default_max_unit
  defp default_max_unit(_op), do: @default_max_unit

  defp pixel_sized?(width, height, natural_width, natural_height) do
    is_integer(width) and is_integer(height) and
      natural_width > 0 and natural_height > 0 and
      width == natural_width and height == natural_height and
      max(width, height) < @default_max_unit
  end

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil

  defp scaled_height(width, natural_width, natural_height)
       when natural_width > 0 and natural_height > 0 do
    max(1, round(width * natural_height / natural_width))
  end

  defp scaled_height(_width, _natural_width, _natural_height), do: @default_max_unit

  defp scaled_width(height, natural_width, natural_height)
       when natural_width > 0 and natural_height > 0 do
    max(1, round(height * natural_width / natural_height))
  end

  defp scaled_width(_height, _natural_width, _natural_height), do: @default_max_unit

  defp fit_size(natural_width, natural_height, max_unit)
       when natural_width > 0 and natural_height > 0 do
    if natural_width >= natural_height do
      {max_unit, max(1, round(max_unit * natural_height / natural_width))}
    else
      {max(1, round(max_unit * natural_width / natural_height)), max_unit}
    end
  end

  defp fit_size(_natural_width, _natural_height, max_unit), do: {max_unit, max_unit}

  # Sniff the natural pixel size from the image header. PNG: IHDR width/height are
  # the two big-endian u32s right after the 8-byte signature + "IHDR" length/type.
  # JPEG: scan the marker segments for an SOF (0xC0..0xCF except C4/C8/CC) whose
  # payload holds height/width as big-endian u16s. GIF: bytes 6..9 are LE u16
  # width/height. Falls back to {0, 0} when the header can't be parsed (the engine
  # then has no natural size hint but still places the image at width/height).
  defp pixel_dims(
         <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _len::32, "IHDR", w::32, h::32,
           _rest::binary>>,
         _ext
       ),
       do: {w, h}

  defp pixel_dims(<<0xFF, 0xD8, rest::binary>>, _ext), do: jpeg_sof_dims(rest)

  defp pixel_dims(<<"GIF", _v::24, w::little-16, h::little-16, _rest::binary>>, _ext),
    do: {w, h}

  defp pixel_dims(_bytes, _ext), do: {0, 0}

  # Walk JPEG marker segments looking for a Start-Of-Frame. A segment starts with
  # 0xFF then a type byte; SOF markers (C0..CF, excluding the non-frame C4/C8/CC)
  # carry [length:16, precision:8, height:16, width:16, ...]. Every other framed
  # marker carries a 16-bit length (which INCLUDES the 2 length bytes), so we skip
  # `length - 2` payload bytes to land on the next marker. Padding 0xFF fill bytes
  # are skipped; standalone RSTn/SOI/EOI markers (D0..D9) have no payload.
  defp jpeg_sof_dims(<<0xFF, 0xFF, rest::binary>>), do: jpeg_sof_dims(<<0xFF, rest::binary>>)

  defp jpeg_sof_dims(<<0xFF, marker, len::16, payload::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC] do
    _ = len

    case payload do
      <<_precision::8, h::16, w::16, _tail::binary>> -> {w, h}
      _ -> {0, 0}
    end
  end

  defp jpeg_sof_dims(<<0xFF, marker, len::16, payload::binary>>)
       when marker not in 0xD0..0xD9 do
    body = max(len - 2, 0)

    case payload do
      <<_seg::binary-size(^body), next::binary>> -> jpeg_sof_dims(next)
      _ -> {0, 0}
    end
  end

  defp jpeg_sof_dims(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD9,
    do: jpeg_sof_dims(rest)

  defp jpeg_sof_dims(_), do: {0, 0}
end
