defmodule Wallabidi.Query.Native do
  @moduledoc false

  # Native Elixir query evaluation using LazyHTML.
  # Replaces XPath for drivers without a JS engine (LiveViewDriver).

  @doc """
  Finds elements in an HTML string matching the given query method and selector.
  Returns a list of `{css_selector_hint, html_fragment}` tuples.
  """
  def find(html, :css, selector) do
    doc = parse_html(html)

    LazyHTML.query(doc, selector)
    |> Enum.with_index()
    |> Enum.map(fn {node, idx} ->
      {selector, idx, LazyHTML.to_html(node)}
    end)
  end

  def find(html, :text, selector) do
    doc = parse_html(html)
    find_by_text(doc, selector)
  end

  def find(html, :link, selector) do
    doc = parse_html(html)

    LazyHTML.query(doc, "a[href]")
    |> filter_by_locator(selector, doc)
  end

  def find(html, :button, selector) do
    doc = parse_html(html)
    button_types = ["submit", "reset", "button", "image"]

    inputs =
      LazyHTML.query(doc, "input")
      |> Enum.filter(fn node ->
        type = attr(node, "type")
        type in button_types
      end)

    buttons =
      LazyHTML.query(doc, "button")
      |> Enum.filter(fn node ->
        type = attr(node, "type")
        type == nil || type in button_types
      end)

    (inputs ++ buttons)
    |> filter_by_locator(selector, doc)
  end

  def find(html, :fillable_field, selector) do
    doc = parse_html(html)
    excluded = ["submit", "image", "radio", "checkbox", "hidden", "file"]

    inputs =
      LazyHTML.query(doc, "input")
      |> Enum.reject(fn node -> attr(node, "type") in excluded end)

    textareas = LazyHTML.query(doc, "textarea") |> Enum.to_list()

    (inputs ++ textareas)
    |> filter_by_field_locator(selector, doc)
  end

  def find(html, :checkbox, selector) do
    doc = parse_html(html)

    LazyHTML.query(doc, "input[type=checkbox]")
    |> filter_by_field_locator(selector, doc)
  end

  def find(html, :radio_button, selector) do
    doc = parse_html(html)

    LazyHTML.query(doc, "input[type=radio]")
    |> filter_by_field_locator(selector, doc)
  end

  def find(html, :select, selector) do
    doc = parse_html(html)

    LazyHTML.query(doc, "select")
    |> filter_by_field_locator(selector, doc)
  end

  def find(html, :option, selector) do
    doc = parse_html(html)

    LazyHTML.query(doc, "option")
    |> Enum.filter(fn node ->
      text(node) |> String.trim() == selector
    end)
    |> to_results()
  end

  def find(html, :file_field, selector) do
    doc = parse_html(html)

    LazyHTML.query(doc, "input[type=file]")
    |> filter_by_field_locator(selector, doc)
  end

  def find(html, :attribute, {name, value}) do
    doc = parse_html(html)

    LazyHTML.query(doc, "[#{name}=#{inspect(value)}]")
    |> to_results()
  end

  def find(html, :xpath, _selector) do
    # XPath not supported in native mode — return empty
    _ = html
    []
  end

  # --- Helpers ---

  # Match elements by id, name, value, text content, title, alt
  defp filter_by_locator(nodes, selector, _doc) do
    nodes
    |> Enum.filter(fn node ->
      attr(node, "id") == selector ||
        attr(node, "name") == selector ||
        attr(node, "value") == selector ||
        text(node) |> String.trim() |> contains?(selector) ||
        attr(node, "title") |> contains?(selector) ||
        attr(node, "alt") |> contains?(selector)
    end)
    |> to_results()
  end

  # Match form fields by id, name, placeholder, or associated label
  defp filter_by_field_locator(nodes, selector, doc) do
    label_for = find_label_for(doc, selector)

    nodes
    |> Enum.filter(fn node ->
      attr(node, "id") == selector ||
        attr(node, "name") == selector ||
        attr(node, "placeholder") == selector ||
        (label_for != nil && attr(node, "id") == label_for) ||
        in_label?(node, selector, doc)
    end)
    |> to_results()
  end

  # Find the `for` attribute of a label matching the selector text
  defp find_label_for(doc, selector) do
    LazyHTML.query(doc, "label")
    |> Enum.find_value(fn label ->
      if text(label) |> String.trim() |> contains?(selector) do
        attr(label, "for")
      end
    end)
  end

  # Check if the node is inside a label whose text matches
  defp in_label?(node, selector, doc) do
    node_html = LazyHTML.to_html(node)

    LazyHTML.query(doc, "label")
    |> Enum.any?(fn label ->
      label_html = LazyHTML.to_html(label)

      String.contains?(label_html, node_html) &&
        text(label) |> String.trim() |> contains?(selector)
    end)
  end

  @head_tags ~w(title head meta link script style noscript)

  defp find_by_text(doc, selector) do
    # Query body descendants only (exclude <title>, <script>, etc.)
    nodes =
      case LazyHTML.query(doc, "body *") do
        results when results != [] -> results
        _ -> LazyHTML.query(doc, "*")
      end

    nodes
    |> Enum.reject(fn node ->
      case LazyHTML.tag(node) do
        [tag | _] -> to_string(tag) in @head_tags
        _ -> false
      end
    end)
    |> Enum.filter(fn node ->
      # Match only elements whose DIRECT text nodes contain the selector
      # (not descendant text). This matches XPath's text() function behavior.
      has_direct_text?(node, selector)
    end)
    |> to_results()
  end

  # Check if an element has DIRECT text nodes containing the selector.
  # Leaf elements (no child elements) always match on full text.
  # Parent elements only match if they have direct text with the selector.
  defp has_direct_text?(node, selector) do
    full_text = text(node) |> String.trim()

    if contains?(full_text, selector) do
      html = LazyHTML.to_html(node)
      # Strip the outer tag and check if remaining has child elements
      inner =
        case Regex.run(~r/^<[^>]+>(.*)<\/[^>]+>$/s, html) do
          [_, i] -> i
          _ -> html
        end

      # If no child elements, it's a leaf — match on full text
      if Regex.match?(~r/<\w+[\s>]/, inner) do
        # Strip child element tags and content to get direct text
        direct = Regex.replace(~r/<\w+[^>]*>.*?<\/\w+>/s, inner, " ")
        contains?(String.trim(direct), selector)
      else
        true
      end
    else
      false
    end
  end

  defp to_results(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {node, idx} ->
      {"*", idx, LazyHTML.to_html(node)}
    end)
  end

  defp attr(node, name) do
    case LazyHTML.attribute(node, name) do
      [val | _] -> val
      [] -> nil
    end
  end

  defp text(node) do
    LazyHTML.text(node) || ""
  end

  defp contains?(nil, _), do: false
  defp contains?("", _), do: false
  defp contains?(haystack, needle), do: String.contains?(haystack, needle)

  # Use from_document for full HTML pages, from_fragment for partials
  defp parse_html(html) do
    if String.contains?(html, "<html") or String.contains?(html, "<!DOCTYPE") do
      LazyHTML.from_document(html)
    else
      LazyHTML.from_fragment(html)
    end
  end
end
