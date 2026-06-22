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
    assert op.width == 8504
    assert op.height == 8504
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
