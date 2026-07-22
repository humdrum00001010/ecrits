defmodule Ecrits.AcpAgent.ContentTest do
  @moduledoc """
  The Phase 5 multi-modal input seam: string-as-sugar must stay byte-for-byte
  identical to the legacy path, and a block list must map onto the ACP prompt
  content shape (text / image / audio / resource_link; doc_ref → ecrits:// link).
  """

  use ExUnit.Case, async: true

  alias Ecrits.AcpAgent.Content

  @preamble "[System] preamble\n"

  describe "normalize/1 — string sugar (legacy path)" do
    test "a bare string is returned UNCHANGED" do
      assert {:ok, "hello"} = Content.normalize("hello")
    end

    test "an empty string is still a valid (unchanged) string" do
      assert {:ok, ""} = Content.normalize("")
    end
  end

  describe "normalize/1 — content blocks" do
    test "file and media payloads are changeset validated" do
      attrs = %{
        type: :file,
        uri: "file:///tmp/x.pdf",
        name: "x.pdf",
        mime_type: "application/pdf"
      }

      assert {:ok, %Ecrits.AcpAgent.Content.File{}} =
               Ecrits.AcpAgent.Content.Block.cast(attrs)

      assert {:ok, [file]} = Content.normalize([attrs])

      assert file == %{
               type: :file,
               uri: "file:///tmp/x.pdf",
               name: "x.pdf",
               mime_type: "application/pdf"
             }

      assert {:error, {:invalid_block, :image}} =
               Content.normalize([%{type: :image, mime_type: "image/png"}])
    end

    test "a text block list normalizes" do
      assert {:ok, [%{type: :text, text: "hi"}]} =
               Content.normalize([%{type: :text, text: "hi"}])
    end

    test "image with inline data + audio normalize" do
      assert {:ok, [img, aud]} =
               Content.normalize([
                 %{type: :image, mime_type: "image/png", data: "AAA"},
                 %{type: :audio, mime_type: "audio/wav", data: "BBB"}
               ])

      assert img == %{type: :image, mime_type: "image/png", data: "AAA"}
      assert aud == %{type: :audio, mime_type: "audio/wav", data: "BBB"}
    end

    test "doc_ref with and without a ref" do
      assert {:ok, [%{type: :doc_ref, document_id: "d_1", ref: "sec/0"}]} =
               Content.normalize([%{type: :doc_ref, document_id: "d_1", ref: "sec/0"}])

      assert {:ok, [%{type: :doc_ref, document_id: "d_2"}]} =
               Content.normalize([%{type: :doc_ref, document_id: "d_2"}])
    end

    test "string-keyed blocks (JSON-shaped) are accepted" do
      assert {:ok, [%{type: :text, text: "hi"}]} =
               Content.normalize([%{"type" => "text", "text" => "hi"}])
    end

    test "an empty list is rejected" do
      assert {:error, :empty_input} = Content.normalize([])
    end

    test "an unknown block type is rejected" do
      assert {:error, {:unknown_block_type, "bogus"}} =
               Content.normalize([%{"type" => "bogus"}])
    end

    test "a malformed text block is rejected" do
      assert {:error, {:invalid_block, :text}} = Content.normalize([%{type: :text}])
    end
  end

  describe "display_text/1" do
    test "string is itself" do
      assert Content.display_text("hello") == "hello"
    end

    test "joins text blocks, ignores media" do
      input = [
        %{type: :text, text: "line1"},
        %{type: :image, mime_type: "image/png", data: "x"},
        %{type: :text, text: "line2"}
      ]

      assert Content.display_text(input) == "line1\nline2"
    end
  end

  describe "to_acp_content/2 — string is the legacy shape" do
    test "string input maps to preamble <> string (a plain string)" do
      assert Content.to_acp_content("edit the doc", @preamble) == @preamble <> "edit the doc"
    end
  end

  describe "to_acp_content/2 — blocks" do
    test "preamble leads as a text block, then one ACP block per input block" do
      input = [
        %{type: :text, text: "describe this"},
        %{type: :image, mime_type: "image/png", data: "AAA"}
      ]

      assert [preamble_block, text_block, image_block] = Content.to_acp_content(input, @preamble)
      assert preamble_block == %{"type" => "text", "text" => @preamble}
      assert text_block == %{"type" => "text", "text" => "describe this"}
      assert image_block["type"] == "image"
      assert image_block["mimeType"] == "image/png"
      assert image_block["data"] == "AAA"
    end

    test "doc_ref maps to an ecrits:// resource_link the agent resolves via doc.*" do
      input = [%{type: :doc_ref, document_id: "d_42", ref: "sec/3/para/0"}]
      assert [_preamble, link] = Content.to_acp_content(input, @preamble)
      assert link["type"] == "resource_link"
      assert link["uri"] == "ecrits://doc/d_42#sec/3/para/0"
    end

    test "doc_ref without a ref omits the fragment" do
      input = [%{type: :doc_ref, document_id: "d_7"}]
      assert [_preamble, link] = Content.to_acp_content(input, @preamble)
      assert link["uri"] == "ecrits://doc/d_7"
    end

    test "file block maps to a resource_link" do
      input = [
        %{type: :file, uri: "file:///tmp/x.pdf", name: "x.pdf", mime_type: "application/pdf"}
      ]

      assert [_preamble, link] = Content.to_acp_content(input, @preamble)
      assert link["type"] == "resource_link"
      assert link["uri"] == "file:///tmp/x.pdf"
      assert link["name"] == "x.pdf"
    end
  end
end
