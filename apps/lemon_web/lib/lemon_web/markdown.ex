defmodule LemonWeb.Markdown do
  @moduledoc """
  Renders assistant markdown as sanitized HTML for the chat transcript.

  `EarmarkParser` produces an AST; this module re-emits it through an
  allow-list instead of trusting a generic HTML renderer:

    * only the tags in `@allowed_tags` become markup, and each keeps only the
      attributes this module constructs itself (link `href`/`title`, a
      `language-*` class on code blocks, table cell alignment, list `start`);
      inline attribute lists such as `{: onclick="..."}` are discarded
    * every text node and attribute value is HTML-escaped
    * raw HTML blocks in the source are never emitted as markup: script-like
      blocks are dropped entirely and anything else is shown as escaped text
    * links are kept only for `http`, `https`, `mailto`, and relative targets
      and open in a new tab with `rel="noopener noreferrer nofollow"`
    * images render as their alt text, so model output cannot make the browser
      fetch arbitrary URLs
  """

  @allowed_tags ~w(p h1 h2 h3 h4 h5 h6 blockquote ul ol li pre code em strong del sub sup a br hr table thead tbody tr th td)
  @void_tags ~w(br hr)
  @dropped_tags ~w(script style iframe frame frameset object embed noscript template textarea title head link meta base svg math form)
  @safe_schemes ~w(http https mailto)
  @cell_alignments ["text-align: left;", "text-align: center;", "text-align: right;"]

  @doc """
  Render `markdown` to a `Phoenix.HTML.safe()` value.
  """
  @spec to_html(String.t()) :: Phoenix.HTML.safe()
  def to_html(markdown) when is_binary(markdown) do
    ast =
      case EarmarkParser.as_ast(markdown, gfm_tables: true) do
        {:ok, ast, _messages} -> ast
        {:error, ast, _messages} -> ast
      end

    {:safe, render_nodes(ast, false)}
  rescue
    _error -> {:safe, ["<p>", escape_literal(markdown), "</p>"]}
  end

  defp render_nodes(nodes, literal?) when is_list(nodes),
    do: Enum.map(nodes, &render_node(&1, literal?))

  defp render_nodes(_nodes, _literal?), do: []

  defp render_node(text, true) when is_binary(text), do: escape_literal(text)
  defp render_node(text, false) when is_binary(text), do: escape_text(text)

  defp render_node({tag, _attrs, children, %{verbatim: true}}, _literal?) do
    if dropped?(tag) do
      []
    else
      text = children |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.join("\n")
      if text == "", do: [], else: ["<p>", escape_literal(text), "</p>"]
    end
  end

  defp render_node({"img", attrs, _children, _meta}, _literal?) do
    case attr(attrs, "alt") do
      alt when is_binary(alt) and alt != "" -> escape_text(alt)
      _ -> []
    end
  end

  defp render_node({"a", attrs, children, _meta}, literal?) do
    inner = render_nodes(children, literal?)

    case safe_href(attr(attrs, "href")) do
      nil ->
        inner

      href ->
        title =
          case attr(attrs, "title") do
            title when is_binary(title) and title != "" ->
              [" title=\"", escape_literal(title), "\""]

            _ ->
              []
          end

        [
          "<a href=\"",
          escape_literal(href),
          "\"",
          title,
          " target=\"_blank\" rel=\"noopener noreferrer nofollow\">",
          inner,
          "</a>"
        ]
    end
  end

  defp render_node({tag, attrs, children, _meta}, literal?) when is_binary(tag) do
    cond do
      dropped?(tag) ->
        []

      tag in @void_tags ->
        ["<", tag, ">"]

      tag in @allowed_tags ->
        literal? = literal? or tag in ["pre", "code"]

        [
          "<",
          tag,
          allowed_attrs(tag, attrs),
          ">",
          render_nodes(children, literal?),
          "</",
          tag,
          ">"
        ]

      true ->
        render_nodes(children, literal?)
    end
  end

  defp render_node(_node, _literal?), do: []

  defp allowed_attrs("code", attrs) do
    with class when is_binary(class) <- attr(attrs, "class"),
         [language | _] <- String.split(class),
         true <- language != "inline" and Regex.match?(~r/\A[A-Za-z0-9_+#.-]{1,40}\z/, language) do
      [" class=\"language-", escape_literal(language), "\""]
    else
      _ -> []
    end
  end

  defp allowed_attrs(tag, attrs) when tag in ["th", "td"] do
    case attr(attrs, "style") do
      style when style in @cell_alignments -> [" style=\"", style, "\""]
      _ -> []
    end
  end

  defp allowed_attrs("ol", attrs) do
    case attr(attrs, "start") do
      start when is_binary(start) ->
        if Regex.match?(~r/\A\d{1,9}\z/, start), do: [" start=\"", start, "\""], else: []

      _ ->
        []
    end
  end

  defp allowed_attrs(_tag, _attrs), do: []

  defp attr(attrs, name) when is_list(attrs) do
    Enum.find_value(attrs, fn
      {key, value} when is_binary(value) -> if to_string(key) == name, do: value
      _ -> nil
    end)
  end

  defp attr(_attrs, _name), do: nil

  # Browsers ignore ASCII whitespace and control characters inside a scheme
  # (`java\tscript:`), so strip them before deciding what the scheme is.
  defp safe_href(href) when is_binary(href) do
    href = String.trim(href)
    probe = String.replace(href, ~r/[\x00-\x20\x7F]/, "")

    cond do
      probe == "" ->
        nil

      match = Regex.run(~r/\A([A-Za-z][A-Za-z0-9+.-]*):/, probe) ->
        [_, scheme] = match
        if String.downcase(scheme) in @safe_schemes, do: href

      true ->
        href
    end
  end

  defp safe_href(_href), do: nil

  defp dropped?(tag) when is_binary(tag), do: String.downcase(tag) in @dropped_tags
  defp dropped?(_tag), do: true

  # Prose text keeps entity references the author wrote (`&amp;` renders as
  # `&`); an entity in element content can never be re-parsed as markup.
  defp escape_text(text) do
    text
    |> String.replace(~r/&(?!(?:#\d{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});)/, "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # Code, attribute values, and fallback text are shown exactly as written.
  defp escape_literal(text) do
    {:safe, escaped} = Phoenix.HTML.html_escape(text)
    escaped
  end
end
