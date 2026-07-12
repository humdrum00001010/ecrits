defmodule EcritsWeb.MarkdownTest do
  use ExUnit.Case, async: true

  describe "to_safe_html/1 (chat rail, sanitized)" do
    test "renders GFM and escapes raw HTML" do
      {:safe, html} = EcritsWeb.Markdown.to_safe_html("**bold** <script>x</script>")

      assert html =~ "<strong>bold</strong>"
      refute html =~ "<script>"
    end

    test "returns empty string for blank/non-binary input" do
      assert EcritsWeb.Markdown.to_safe_html("") == ""
      assert EcritsWeb.Markdown.to_safe_html(nil) == ""
    end
  end

  describe "to_preview_html/1 (markdown document preview, Observex)" do
    test "renders GFM body" do
      {:safe, html} = EcritsWeb.Markdown.to_preview_html("# Title\n\n- a\n- b")

      assert html =~ "<h1>Title</h1>"
      assert html =~ "<li>a</li>"
    end

    test "emits math and tikz tex-islands" do
      {:safe, html} =
        EcritsWeb.Markdown.to_preview_html("""
        Inline $x^2$ and display:

        $$\\int_0^1 x\\,dx$$

        ```tikz
        \\begin{tikzpicture}\\draw (0,0)--(1,1);\\end{tikzpicture}
        ```
        """)

      assert html =~ ~s(data-kind="math-inline")
      assert html =~ ~s(data-kind="math-display")
      assert html =~ ~s(data-kind="tikz-block")
    end

    test "escapes raw HTML from the document source" do
      {:safe, html} = EcritsWeb.Markdown.to_preview_html("hello <img src=x onerror=alert(1)>")

      refute html =~ "<img"
      assert html =~ "&lt;img"
    end

    test "returns empty string for blank/non-binary input" do
      assert EcritsWeb.Markdown.to_preview_html("") == ""
      assert EcritsWeb.Markdown.to_preview_html(nil) == ""
    end
  end

  describe "repair_chat_prose_boundaries/1" do
    test "repairs adjacent Korean prose sentences in text nodes" do
      html = "<p>확인한다.첫 장을 본다.JSONL 검증도 한다.</p>"

      assert EcritsWeb.Markdown.repair_chat_prose_boundaries(html) ==
               "<p>확인한다. 첫 장을 본다. JSONL 검증도 한다.</p>"
    end

    test "leaves inline and fenced code text untouched" do
      html = """
      <p>확인한다.첫 장 <code>코드.깨면안됨</code></p><pre><code>코드.깨면안됨
      </code></pre>
      """

      repaired = EcritsWeb.Markdown.repair_chat_prose_boundaries(html)

      assert repaired =~ "확인한다. 첫 장"
      assert repaired =~ "<code>코드.깨면안됨</code>"
      assert repaired =~ "<pre><code>코드.깨면안됨\n</code></pre>"
    end
  end
end
