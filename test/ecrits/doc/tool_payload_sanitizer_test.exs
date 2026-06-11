defmodule Ecrits.Doc.ToolPayloadSanitizerTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.ToolPayloadSanitizer

  test "doc.save success payloads are compacted to ok only" do
    payload = %{
      "_meta" => nil,
      "content" => [
        %{
          "type" => "text",
          "text" =>
            Jason.encode!(%{
              "ok" => true,
              "path" => "/tmp/service.hwp",
              "bytes" => 1234,
              "validation" => %{"remaining_fillable" => 3}
            })
        }
      ],
      "structuredContent" => %{
        "ok" => true,
        "path" => "/tmp/service.hwp",
        "bytes" => 1234,
        "validation" => %{"remaining_fillable" => 3}
      }
    }

    assert ToolPayloadSanitizer.sanitize_tool_payload("doc.save", payload) == %{"ok" => true}
  end

  test "doc.save encoded transcript bodies are compacted to ok only" do
    body =
      Jason.encode!(%{
        "_meta" => nil,
        "content" => [
          %{"type" => "text", "text" => Jason.encode!(%{"ok" => true, "bytes" => 999})}
        ]
      })

    assert Jason.decode!(ToolPayloadSanitizer.sanitize_tool_body("doc.save", body)) == %{
             "ok" => true
           }
  end

  test "other doc tools still keep useful payload data" do
    payload = %{"ok" => true, "documents" => [%{"path" => "/tmp/service.hwp"}]}

    assert ToolPayloadSanitizer.sanitize_tool_payload("doc.context", payload) == payload
  end

  test "doc.create deck arguments are compacted for transcript proof" do
    payload = %{
      "path" => "/tmp/deck.pptx",
      "kind" => "pptx",
      "deck" => %{
        "title" => "Board update",
        "subtitle" => "Q2",
        "slides" => [
          %{
            "title" => "Problem",
            "cards" => [
              %{"title" => "Long", "body" => String.duplicate("full body ", 50)}
            ]
          },
          %{"title" => "Solution", "roadmap" => ["A", "B", "C"]}
        ]
      }
    }

    assert ToolPayloadSanitizer.sanitize_tool_payload("doc.create", payload) == %{
             "path" => "/tmp/deck.pptx",
             "kind" => "pptx",
             "deck" => %{
               "title" => "Board update",
               "subtitle" => "Q2",
               "slides" => 2,
               "slide_titles" => ["Problem", "Solution"]
             }
           }
  end
end
