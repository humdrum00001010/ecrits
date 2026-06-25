defmodule Ecrits.Doc.RhwpImageTest do
  use ExUnit.Case, async: true

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
end
