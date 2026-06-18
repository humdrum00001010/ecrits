defmodule Ecrits.Doc.Rhwp.Image do
  @moduledoc """
  Resolves an `insert_picture` op's `src` (a file path) into the fields each
  document arm needs — pure byte handling, no NIF.

    * `resolve_src/2` — the SERVER arm: produces the typed `%Ehwp.Op.InsertPicture{}`
      (at the given resolved ref) + the raw `bins` the NIF takes out-of-band by
      `:bin_index`, plus the natural pixel size. The engine PLACES the picture
      (fit-to-width capped to the paragraph's real placeable width); a
      caller-supplied `width`/`height` is honored verbatim (#46).
    * `for_browser/1` — the BROWSER (WASM) arm, which can't read the server
      filesystem, so it gets the bytes inline as `:image_base64`.

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
        {nw, nh} =
          if is_integer(op[:natural_width_px]) and is_integer(op[:natural_height_px]) do
            {op[:natural_width_px], op[:natural_height_px]}
          else
            pixel_dims(bytes, ext_hint)
          end

        # (#46) width/height absent (nil) = "let the ENGINE fit to the paragraph's
        # real placeable width"; a caller override passes through.
        pic = %Ehwp.Op.InsertPicture{
          at: at,
          bin_index: op[:bin_index] || 0,
          extension: present_string(op[:extension]) || ext_hint || "",
          width: op[:width],
          height: op[:height],
          natural_width_px: nw,
          natural_height_px: nh,
          description: op[:description] || ""
        }

        {:ok, pic, [bytes]}

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
  the WASM handler (`wasm_hwp_editor.applyOneOp` insert_picture) can decode and
  call `insertPicture`. Only fires for the INLINE form (`src`, no `page`); the
  pptx slide form (`page` set) is left for the office arm. Non-picture / no-`src`
  ops pass through.
  """
  @spec for_browser(map()) :: {:ok, map()} | {:error, map()}
  def for_browser(%{op: "insert_picture", src: src} = op)
      when is_binary(src) and src != "" do
    if Map.has_key?(op, :page) do
      {:ok, op}
    else
      with {:ok, bytes} <- read_file(src) do
        ext = extension(src)
        {nw, nh} = pixel_dims(bytes, ext)

        op =
          op
          |> Map.delete(:src)
          |> Map.put(:image_base64, Base.encode64(bytes))
          |> Map.put(:extension, present_string(op[:extension]) || ext)
          |> Map.put(:natural_width_px, op[:natural_width_px] || nw)
          |> Map.put(:natural_height_px, op[:natural_height_px] || nh)

        {:ok, op}
      end
    end
  end

  def for_browser(op), do: {:ok, op}

  # ── internals ──────────────────────────────────────────────────────────────

  defp extension(src), do: src |> Path.extname() |> String.trim_leading(".") |> String.downcase()

  defp read_file(src) do
    case File.read(src) do
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
