defmodule LemonWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias LemonWeb.Markdown

  defp html(markdown), do: markdown |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()

  test "renders common markdown structure" do
    out = html("# Title\n\n3. three\n4. four\n\n> quoted\n\n| a | b |\n|---|:-:|\n| 1 | 2 |")

    assert out =~ "<h1>Title</h1>"
    assert out =~ ~s|<ol start="3"><li>three</li><li>four</li></ol>|
    assert out =~ "<blockquote><p>quoted</p></blockquote>"
    assert out =~ ~s|<th style="text-align: center;">b</th>|
  end

  test "code is shown literally with a sanitized language class" do
    out = html("```elixir\nIO.puts(\"<b>\") &amp;\n```\n\n```x\" onclick=\"y\nboom\n```")

    assert out =~ ~s|<pre><code class="language-elixir">IO.puts(&quot;&lt;b&gt;&quot;) &amp;amp;</code></pre>|
    refute out =~ ~s|onclick="|
  end

  test "raw HTML never becomes markup" do
    out =
      html("""
      <script>alert(1)</script>

      <div>
      <img src=x onerror=alert(1)>
      </div>

      inline <iframe src="https://evil.test"></iframe> and <b onclick="x">bold</b>
      """)

    refute out =~ "<script"
    refute out =~ "alert(1)</script>"
    refute out =~ "<img"
    refute out =~ "<iframe"
    refute out =~ "<b "
    assert out =~ "&lt;img src=x onerror=alert(1)&gt;"
    assert out =~ "&lt;b onclick=&quot;x&quot;&gt;bold&lt;/b&gt;"
  end

  test "inline attribute lists cannot add attributes" do
    out = html("para\n{: .x onclick=\"alert(1)\" style=\"color:red\"}")

    assert out == "<p>para</p>"
  end

  test "links keep only safe schemes and open in a new tab" do
    out =
      html(
        "[a](javascript:alert(1)) [b](JaVaScRiPt:alert(1)) [c](java\tscript:alert(1)) " <>
          "[d](data:text/html,x) [e](https://example.com/?q=1&r=2) [f](/relative) [g](mailto:me@example.com)"
      )

    refute out =~ ~r/href="\s*(javascript|java\s*script|data):/i
    assert out =~ "a b c d"
    assert out =~ ~s|<a href="https://example.com/?q=1&amp;r=2" target="_blank" rel="noopener noreferrer nofollow">e</a>|
    assert out =~ ~s|href="/relative"|
    assert out =~ ~s|href="mailto:me@example.com"|
  end

  test "images render as their alt text without fetching the source" do
    out = html("![a diagram](https://tracker.test/pixel.png)")

    assert out == "<p>a diagram</p>"
  end

  test "prose keeps entity references and escapes bare markup characters" do
    assert html("Tom &amp; Jerry & <friends>") == "<p>Tom &amp; Jerry &amp; &lt;friends&gt;</p>"
  end
end
