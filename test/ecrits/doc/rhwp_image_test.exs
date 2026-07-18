defmodule Ecrits.Doc.RhwpImageTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.{MCPToolPolicy, Op}
  alias Ecrits.Doc.Rhwp.Image

  @png_1x1 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  setup do
    path =
      Path.join(System.tmp_dir!(), "ecrits_rhwp_image_#{System.unique_integer([:positive])}.png")

    File.write!(path, Base.decode64!(@png_1x1))
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "for_browser turns src into inline bytes and default dimensions", %{path: path} do
    assert {:ok, op} = Image.for_browser(%{op: "insert_picture", ref: "end", src: path})

    refute Map.has_key?(op, :src)
    assert op.image_base64 == @png_1x1
    assert op.extension == "png"
    assert op.natural_width_px == 1
    assert op.natural_height_px == 1
    assert op.width == 22_000
    assert op.height == 22_000
  end

  test "for_browser accepts file URL src", %{path: path} do
    assert {:ok, op} =
             Image.for_browser(%{op: "insert_picture", ref: "end", src: "file://" <> path})

    assert op.image_base64 == @png_1x1
    assert op.extension == "png"
  end

  test "for_browser preserves explicit dimensions", %{path: path} do
    assert {:ok, op} =
             Image.for_browser(%{
               op: "insert_picture",
               ref: "end",
               src: path,
               width: 3200,
               height: 2400
             })

    assert op.width == 3200
    assert op.height == 2400
  end

  test "for_browser uses a compact contextual default for a picture inside a cell", %{
    path: path
  } do
    assert {:ok, op} =
             Image.for_browser(%{
               op: "insert_picture",
               ref: %{cell: %{cellIndex: 2}},
               src: path,
               inline_in_cell: true
             })

    assert op.width == 4_500
    assert op.height == 4_500
    assert op.inline_in_cell
  end

  test "for_browser makes a cell-path ref inline without a redundant flag", %{path: path} do
    ref =
      Jason.encode!(%{
        "section" => 0,
        "paragraph" => 76,
        "offset" => 16,
        "cellPath" => [
          %{"controlIndex" => 0, "cellIndex" => 3, "cellParaIndex" => 3}
        ]
      })

    assert {:ok, op} =
             Image.for_browser(%{
               op: "insert_picture",
               ref: ref,
               src: path,
               width: 7_000
             })

    assert op.inline_in_cell
    assert op.width == 7_000
  end

  test "resolve_src gives the server arm the same compact cell default", %{path: path} do
    at = %Ehwp.Op.Ref{section: 0, paragraph: 4, offset: 3}

    assert {:ok, %Ehwp.Op.InsertPicture{} = op, [_bytes]} =
             Image.resolve_src(
               %{op: "insert_picture", src: path, inline_in_cell: true},
               at
             )

    assert op.width == 4_500
    assert op.height == 4_500
    assert op.inline_in_cell
  end

  test "resolve_src carries the server-owned signature marker length into the engine op", %{
    path: path
  } do
    at = %Ehwp.Op.Ref{
      section: 0,
      paragraph: 76,
      offset: 21,
      control: 0,
      cell: 3,
      cell_para: 3
    }

    assert {:ok, %Ehwp.Op.InsertPicture{} = op, [_bytes]} =
             Image.resolve_src(
               %{
                 op: "insert_picture",
                 src: path,
                 inline_in_cell: false,
                 overlay_marker_length: 3
               },
               at
             )

    refute op.inline_in_cell
    assert op.overlay_marker_length == 3
  end

  test "for_browser preserves the server-owned signature marker length", %{path: path} do
    assert {:ok, op} =
             Image.for_browser(%{
               op: "insert_picture",
               ref: %{cell: %{cellIndex: 3}},
               src: path,
               inline_in_cell: false,
               overlay_marker_length: 3
             })

    refute op.inline_in_cell
    assert op.overlay_marker_length == 3
  end

  test "marker policy normalizes the signature overlay to the same server and browser size" do
    path =
      Path.join(
        System.tmp_dir!(),
        "ecrits_rhwp_signature_#{System.unique_integer([:positive])}.png"
      )

    File.write!(path, png(1_337, 323))
    on_exit(fn -> File.rm(path) end)

    args = %{
      "document" => "d_contract",
      "op" => %{
        "op" => "insert_picture",
        "ref" => "signature-marker-ref",
        "src" => path
      },
      "fallback" => %{"reason" => "unrepresentable"}
    }

    prepared =
      MCPToolPolicy.prepare_vfs_call("doc.edit", args, %{
        native_marker: "(인)"
      })

    assert prepared["op"]["inline_in_cell"] == false
    assert prepared["op"]["overlay_marker_length"] == 3
    refute Map.has_key?(prepared["op"], "width")
    refute Map.has_key?(prepared["op"], "height")

    assert {:ok, normalized} = Op.normalize(prepared["op"])

    at = %Ehwp.Op.Ref{section: 0, paragraph: 76, offset: 21, control: 0, cell: 3, cell_para: 3}

    assert {:ok, %Ehwp.Op.InsertPicture{} = server_op, [_bytes]} =
             Image.resolve_src(normalized, at)

    assert {server_op.natural_width_px, server_op.natural_height_px} == {1_337, 323}
    assert {server_op.width, server_op.height} == {5_000, 1_208}

    assert {:ok, browser_op} = Image.for_browser(normalized)
    assert {browser_op.natural_width_px, browser_op.natural_height_px} == {1_337, 323}
    assert {browser_op.width, browser_op.height} == {5_000, 1_208}
  end

  test "marker overlay preserves trusted explicit dimensions", %{path: path} do
    op = %{
      op: "insert_picture",
      ref: "signature-marker-ref",
      src: path,
      inline_in_cell: false,
      overlay_marker_length: 3,
      width: 4_200,
      height: 1_100
    }

    assert {:ok, %Ehwp.Op.InsertPicture{} = server_op, [_bytes]} =
             Image.resolve_src(op, %Ehwp.Op.Ref{section: 0, paragraph: 2, offset: 0})

    assert {server_op.width, server_op.height} == {4_200, 1_100}

    assert {:ok, browser_op} = Image.for_browser(op)
    assert {browser_op.width, browser_op.height} == {4_200, 1_100}
  end

  test "for_browser normalizes natural-pixel dimensions that would render tiny" do
    path =
      Path.join(
        System.tmp_dir!(),
        "ecrits_rhwp_image_wide_#{System.unique_integer([:positive])}.png"
      )

    png =
      <<
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x14,
        0x50,
        0x00,
        0x00,
        0x0B,
        0xB8,
        0x08,
        0x02,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00
      >>

    File.write!(path, png)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, op} =
             Image.for_browser(%{
               op: "insert_picture",
               ref: "end",
               src: path,
               width: 5200,
               height: 3000
             })

    assert op.width == 22_000
    assert op.height == 12_692
  end

  test "for_browser rejects declared natural dimensions that contradict file bytes", %{path: path} do
    assert {:error, %{message: message}} =
             Image.for_browser(%{
               op: "insert_picture",
               ref: "end",
               src: path,
               natural_width_px: 3200,
               natural_height_px: 2400
             })

    assert message =~ "image bytes are 1x1px"
    assert message =~ "declare 3200x2400px"
  end

  test "resolve_src rejects inline bins that contradict declared natural dimensions" do
    assert {:error, %{message: message}} =
             Image.resolve_src(
               %{
                 op: "insert_picture",
                 bins: [@png_1x1],
                 width: 4376,
                 height: 3287,
                 extension: "png",
                 natural_width_px: 3200,
                 natural_height_px: 2400
               },
               %Ehwp.Op.Ref{section: 0, paragraph: 2, offset: 0}
             )

    assert message =~ "image bytes are 1x1px"
    assert message =~ "declare 3200x2400px"
  end

  test "for_browser inlines slide picture bytes without changing slide geometry", %{path: path} do
    assert {:ok, op} =
             Image.for_browser(%{
               op: "insert_picture",
               page: "Slide1",
               name: "logo",
               src: path,
               x: 100,
               y: 200,
               w: 3000,
               h: 1200
             })

    refute Map.has_key?(op, :src)
    assert op.image_base64 == @png_1x1
    assert op.extension == "png"
    assert op.page == "Slide1"
    assert op.name == "logo"
    assert op.x == 100
    assert op.y == 200
    assert op.w == 3000
    assert op.h == 1200
    refute Map.has_key?(op, :width)
    refute Map.has_key?(op, :height)
  end

  defp png(width, height) do
    scanline = <<0, :binary.copy(<<0, 0, 0, 0>>, width)::binary>>
    pixels = :binary.copy(scanline, height)

    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <>
      png_chunk("IHDR", <<width::32, height::32, 8, 6, 0, 0, 0>>) <>
      png_chunk("IDAT", :zlib.compress(pixels)) <>
      png_chunk("IEND", <<>>)
  end

  defp png_chunk(type, data) do
    payload = type <> data
    <<byte_size(data)::32, payload::binary, :erlang.crc32(payload)::32>>
  end
end
