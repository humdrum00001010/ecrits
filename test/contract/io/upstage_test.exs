defmodule Contract.IO.UpstageTest do
  use ExUnit.Case, async: false

  alias Contract.IO.Upstage

  setup do
    bypass = Bypass.open()

    Application.put_env(:contract, :upstage,
      endpoint: "http://localhost:#{bypass.port}/v1/document-ai/document-parse",
      api_key: "test-upstage-key"
    )

    on_exit(fn -> Application.delete_env(:contract, :upstage) end)

    {:ok, bypass: bypass}
  end

  describe "parse/2" do
    test "POSTs multipart form, sends auth header, parses response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/document-ai/document-parse", fn conn ->
        assert ["Bearer test-upstage-key"] = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        assert body =~ ~r/form-data; name="document"/i
        # Upstage rejects requests where the `document` part lacks a filename
        # (HTTP 400 "no_document"), so this is the regression assertion.
        assert body =~ ~r/form-data;\s*name="document";\s*filename="/i
        assert body =~ ~r/name="ocr"/
        assert body =~ "auto"
        assert body =~ ~r/name="coordinates"/
        assert body =~ "true"
        assert body =~ ~r/name="output_formats"/
        assert body =~ "html"
        assert body =~ "markdown"
        assert body =~ ~r/name="model"/
        assert body =~ "document-parse"

        response = %{
          "elements" => [
            %{
              "id" => 0,
              "category" => "paragraph",
              "content" => %{"text" => "hello"}
            }
          ],
          "content" => %{"text" => "hello"},
          "model" => "document-parse",
          "usage" => %{"pages" => 1}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      tmpfile = write_tempfile("hello")
      assert {:ok, parsed} = Upstage.parse(tmpfile)
      assert is_list(parsed.elements)
      assert hd(parsed.elements)["category"] == "paragraph"
      assert parsed.content == %{"text" => "hello"}
    end

    test "document part carries filename + hwpx content_type when path ends in .hwpx",
         %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/document-ai/document-parse", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        send(parent, {:body, body})

        Plug.Conn.resp(conn, 200, Jason.encode!(%{"elements" => [], "content" => %{}}))
      end)

      tmpfile = write_tempfile_with_ext("hwpx-bytes", ".hwpx")
      assert {:ok, _} = Upstage.parse(tmpfile)

      assert_receive {:body, body}, 5_000
      basename = Path.basename(tmpfile)
      # The document part must include a `filename=` directive AND a
      # `Content-Type: application/vnd.hancom.hwpx` header for Upstage to
      # accept the upload.
      assert body =~ ~s|filename="#{basename}"|
      assert body =~ ~r/Content-Type:\s*application\/vnd\.hancom\.hwpx/i
    end

    test "raw bytes path honors :filename override and derives content_type",
         %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/document-ai/document-parse", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        send(parent, {:body, body})
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"elements" => [], "content" => %{}}))
      end)

      assert {:ok, _} =
               Upstage.parse(<<0, 1, 2, 3>>, filename: "real_contract.hwpx")

      assert_receive {:body, body}, 5_000
      assert body =~ ~s|filename="real_contract.hwpx"|
      assert body =~ ~r/Content-Type:\s*application\/vnd\.hancom\.hwpx/i
    end

    test "raw bytes without :filename fall back to document.bin + octet-stream",
         %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/document-ai/document-parse", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        send(parent, {:body, body})
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"elements" => [], "content" => %{}}))
      end)

      assert {:ok, _} = Upstage.parse(<<0, 1, 2, 3>>)

      assert_receive {:body, body}, 5_000
      assert body =~ ~s|filename="document.bin"|
      assert body =~ ~r/Content-Type:\s*application\/octet-stream/i
    end

    test "non-200 returns {:error, {:upstage_http, ...}}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/document-ai/document-parse", fn conn ->
        Plug.Conn.resp(conn, 502, ~s({"error":"bad gateway"}))
      end)

      tmpfile = write_tempfile("hello")
      assert {:error, {:upstage_http, 502, _}} = Upstage.parse(tmpfile)
    end

    test "transport failure returns {:error, {:upstage_transport, ...}}", %{bypass: bypass} do
      Bypass.down(bypass)

      tmpfile = write_tempfile("hello")
      assert {:error, {:upstage_transport, _}} = Upstage.parse(tmpfile)
    end

    test "honors api_key override", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/document-ai/document-parse", fn conn ->
        assert ["Bearer override-key"] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"elements" => [], "content" => %{}}))
      end)

      tmpfile = write_tempfile("hello")
      assert {:ok, _} = Upstage.parse(tmpfile, api_key: "override-key")
    end
  end

  describe "normalize_elements/1" do
    test "maps every Upstage category onto the right node kind (with paragraph fallback)" do
      cases =
        [{"paragraph", :paragraph}, {"list", :list}, {"list_item", :list_item},
         {"table", :table}, {"figure", :figure}, {"obscure-thing", :paragraph}] ++
          for(level <- 1..6, do: {"heading#{level}", :heading})

      for {cat, kind} <- cases do
        elements = [%{"id" => 0, "category" => cat, "content" => %{"text" => "x"}}]
        [node] = Upstage.normalize_elements(elements)
        assert node["kind"] == kind, "expected #{cat} -> #{kind}, got #{inspect(node["kind"])}"
      end

      # Stable id derivation + content passthrough.
      [single] =
        Upstage.normalize_elements([
          %{"id" => 0, "category" => "paragraph", "content" => %{"text" => "hi"}}
        ])

      assert single["id"] == "node:0"
      assert single["content"] == "hi"
    end

    test "preserves page + coordinates + original category in attrs" do
      coords = [%{"x" => 0.1, "y" => 0.1}, %{"x" => 0.9, "y" => 0.9}]

      elements = [
        %{
          "id" => 1,
          "category" => "table",
          "content" => %{"html" => "<table></table>"},
          "page" => 3,
          "coordinates" => coords
        }
      ]

      [node] = Upstage.normalize_elements(elements)
      assert node["attrs"]["page"] == 3
      assert node["attrs"]["coordinates"] == coords
      assert node["attrs"]["category"] == "table"
    end
  end

  describe "import_upload/3" do
    test "returns Action(:create_document) with normalized nodes + source ref", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/document-ai/document-parse", fn conn ->
        response = %{
          "elements" => [
            %{"id" => 0, "category" => "heading1", "content" => %{"text" => "TITLE"}},
            %{"id" => 1, "category" => "paragraph", "content" => %{"text" => "body"}}
          ],
          "content" => %{}
        }

        Plug.Conn.resp(conn, 200, Jason.encode!(response))
      end)

      tmpfile = write_tempfile("PDFBYTES")
      owner_id = Ecto.UUID.generate()

      upload = %{
        path: tmpfile,
        client_name: "contract.pdf",
        client_type: "application/pdf",
        client_size: 8
      }

      # Stub R2: rewire to a fake bucket-less endpoint that 200s.
      bypass_r2 = Bypass.open()

      Bypass.expect(bypass_r2, fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      original = Application.get_env(:contract, :r2)

      Application.put_env(:contract, :r2,
        bucket: "test-bucket",
        access_key_id: "k",
        secret_access_key: "s",
        endpoint: "http://localhost:#{bypass_r2.port}"
      )

      on_exit(fn -> Application.put_env(:contract, :r2, original) end)

      assert {:ok, %Contract.Command{} = action} =
               Upstage.import_upload(nil, owner_id, upload)

      assert action.kind == :create_document
      assert is_list(action.payload["nodes"])
      assert length(action.payload["nodes"]) == 2
      assert hd(action.payload["nodes"])["kind"] == :heading
      assert action.payload["title"] == "contract.pdf"
      assert action.payload["mime_type"] == "application/pdf"
      assert is_binary(action.payload["artifact_id"])
      assert String.starts_with?(action.payload["source"]["key"], "uploads/#{owner_id}/")
    end
  end

  # --------------------------------------------------------------------------
  # IR-richness (task #37): table column_widths derived from cell bboxes.
  # --------------------------------------------------------------------------

  describe "normalize_elements/1 — table IR-richness" do
    test "honors an explicit numeric column_widths array on a table element" do
      elements = [
        %{
          "id" => 7,
          "category" => "table",
          "content" => %{"html" => "<table/>"},
          "column_widths" => [1500, 3000, 4500]
        }
      ]

      [node] = Upstage.normalize_elements(elements)
      assert node["kind"] == :table
      assert node["attrs"]["column_widths"] == [1500, 3000, 4500]
    end

    test "derives column_widths from 3-column cell bboxes in the first row" do
      # Three columns occupying x in [0..0.2], [0.2..0.6], [0.6..1.0] — so the
      # widths should be roughly proportional to 0.2, 0.4, 0.4.
      cells = [
        %{
          "row" => 0,
          "col" => 0,
          "coordinates" => [
            %{"x" => 0.0, "y" => 0.0},
            %{"x" => 0.2, "y" => 0.0},
            %{"x" => 0.2, "y" => 0.1},
            %{"x" => 0.0, "y" => 0.1}
          ]
        },
        %{
          "row" => 0,
          "col" => 1,
          "coordinates" => [
            %{"x" => 0.2, "y" => 0.0},
            %{"x" => 0.6, "y" => 0.0},
            %{"x" => 0.6, "y" => 0.1},
            %{"x" => 0.2, "y" => 0.1}
          ]
        },
        %{
          "row" => 0,
          "col" => 2,
          "coordinates" => [
            %{"x" => 0.6, "y" => 0.0},
            %{"x" => 1.0, "y" => 0.0},
            %{"x" => 1.0, "y" => 0.1},
            %{"x" => 0.6, "y" => 0.1}
          ]
        }
      ]

      elements = [
        %{
          "id" => 1,
          "category" => "table",
          "content" => %{"html" => "<table/>"},
          "coordinates" => [
            %{"x" => 0.0, "y" => 0.0},
            %{"x" => 1.0, "y" => 0.0},
            %{"x" => 1.0, "y" => 0.1},
            %{"x" => 0.0, "y" => 0.1}
          ],
          "cells" => cells
        }
      ]

      [node] = Upstage.normalize_elements(elements)
      widths = node["attrs"]["column_widths"]
      assert is_list(widths)
      assert length(widths) == 3
      [w1, w2, w3] = widths
      # All positive HWP units.
      assert w1 > 0 and w2 > 0 and w3 > 0
      # Total is roughly the assumed page width (~16000), within rounding.
      assert (w1 + w2 + w3) in 15_995..16_005
      # Middle and last columns are wider than the first (0.4 vs 0.2 ratios).
      assert w2 > w1
      assert w3 > w1
    end

    test "no column_widths key on tables without bbox info / non-table elements" do
      no_bbox_table = [%{"id" => 2, "category" => "table", "content" => %{"text" => "x"}}]
      [t] = Upstage.normalize_elements(no_bbox_table)
      assert t["kind"] == :table
      refute Map.has_key?(t["attrs"], "column_widths")

      paragraph = [%{"id" => 3, "category" => "paragraph", "content" => %{"text" => "ok"}}]
      [p] = Upstage.normalize_elements(paragraph)
      refute Map.has_key?(p["attrs"], "column_widths")
    end
  end

  defp write_tempfile(contents) do
    path = Path.join(System.tmp_dir!(), "upstage-test-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    path
  end

  defp write_tempfile_with_ext(contents, ext) do
    path =
      Path.join(
        System.tmp_dir!(),
        "upstage-test-#{System.unique_integer([:positive])}#{ext}"
      )

    File.write!(path, contents)
    path
  end
end
