defmodule Wallabidi.LiveViewDriver do
  @moduledoc """
  Direct LiveView driver — connects to LiveViews via Phoenix channels
  without a browser. Same wallabidi API, no Chrome/Docker required.

  ## Usage

      {:ok, session} = Wallabidi.start_session(driver: :live_view, endpoint: MyAppWeb.Endpoint)

      session
      |> visit("/users")
      |> click(Query.button("Save"))
      |> assert_has(Query.text("Saved"))

  ## Limitations

  - No JavaScript execution
  - No window management, frames, cookies, screenshots, dialogs
  - Forms must use phx-change/phx-submit
  """

  @behaviour Wallabidi.Driver

  alias Wallabidi.{Element, Session}

  @lv_test Phoenix.LiveViewTest
  @conn_test Phoenix.ConnTest

  # --- Session lifecycle ---

  @impl true
  def start_session(opts) do
    endpoint =
      Keyword.get_lazy(opts, :endpoint, fn ->
        Application.get_env(:wallabidi, :endpoint) ||
          raise ArgumentError,
                "LiveView driver requires an endpoint. Either pass endpoint: MyAppWeb.Endpoint " <>
                  "in opts or set config :wallabidi, endpoint: MyAppWeb.Endpoint"
      end)

    session = %Session{
      id: "lv-#{System.unique_integer([:positive])}",
      driver: __MODULE__,
      server: endpoint,
      session_url: "",
      url: ""
    }

    {:ok, session}
  end

  @impl true
  def end_session(session) do
    Process.delete({:lv_driver, session.id})
    :ok
  end

  # --- Navigation ---

  @impl true
  def visit(session, url) do
    # Browser.visit may pass a full URL (base_url + path). Extract just the path.
    uri = URI.parse(url)
    path = uri.path || url

    result = visit_endpoint(session, path)

    case result do
      {:live, view, html} ->
        put_state(session, view, html, path)

      {:static, html} ->
        put_state(session, nil, html, path)

      {:redirect, to} ->
        visit(session, to)

      :not_found ->
        put_state(session, nil, "", path)
    end

    :ok
  end

  defp visit_endpoint(session, path) do
    conn =
      @conn_test.build_conn()
      |> Plug.Conn.put_private(:phoenix_endpoint, session.server)
      |> @conn_test.dispatch(session.server, :get, path)

    cond do
      # Plug.Static served a file (conn is halted with status 200)
      conn.halted && conn.status in [200, 304] ->
        {:static, conn.resp_body || ""}

      # Normal response — try LiveView
      conn.status in [200, 302] ->
        case @lv_test.__live__(conn, nil, []) do
          {:ok, view, html} -> {:live, view, html}
          {:error, {:live_redirect, %{to: to}}} -> {:redirect, to}
          {:error, _} -> {:static, conn.resp_body || ""}
        end

      true ->
        :not_found
    end
  rescue
    e ->
      :not_found
  end

  @impl true
  def current_url(session) do
    path = get_state(session)[:path] || ""
    base = Application.get_env(:wallabidi, :base_url, "")
    {:ok, String.trim_trailing(base, "/") <> path}
  end

  @impl true
  def current_path(session), do: {:ok, get_state(session)[:path] || "/"}

  # --- Finding elements ---

  @impl true
  def find_elements(parent, compiled_query) do
    html = get_rendered_html(parent)

    # Decode the compiled query into a method + selector that Native can handle
    {method, selector} =
      case compiled_query do
        {:css, sel} -> {:css, sel}
        {:xpath, xpath} -> decode_xpath(xpath)
      end

    results = Wallabidi.Query.Native.find(html, method, selector)

    elements =
      Enum.map(results, fn {sel, idx, el_html} ->
        %Element{
          id: "lv-#{sel}-#{idx}",
          parent: parent,
          driver: __MODULE__,
          url: "",
          session_url: "",
          bidi_shared_id: {:lv_element, sel, idx, el_html}
        }
      end)

    {:ok, elements}
  end

  # When we receive an XPath string from Query.compile, reverse-engineer the
  # original query method and selector so Native can use Elixir-based finders.
  defp decode_xpath(xpath) do
    selector = extract_xpath_selector(xpath)

    cond do
      # fillable_field: contains "self::input | self::textarea" (the union selector)
      String.contains?(xpath, "self::input | self::textarea") ->
        {:fillable_field, selector}

      # checkbox: starts with .//input[./@type = 'checkbox']
      String.starts_with?(xpath, ".//input[./@type = 'checkbox']") ->
        {:checkbox, selector}

      # radio_button: starts with .//input[./@type = 'radio']
      String.starts_with?(xpath, ".//input[./@type = 'radio']") ->
        {:radio_button, selector}

      # file_field: starts with .//input[./@type = 'file']
      String.starts_with?(xpath, ".//input[./@type = 'file']") ->
        {:file_field, selector}

      String.contains?(xpath, ".//select") ->
        {:select, selector}

      String.contains?(xpath, ".//option") ->
        {:option, selector}

      String.contains?(xpath, ".//a[./@href]") ->
        {:link, selector}

      String.contains?(xpath, ".//input[") && String.contains?(xpath, "button") ->
        {:button, selector}

      String.contains?(xpath, "contains(normalize-space(text())") ->
        {:text, selector}

      String.contains?(xpath, "./@") ->
        case Regex.run(~r{\./@([\w-]+)\s*=\s*"([^"]*)"}, xpath) do
          [_, name, value] -> {:attribute, {name, value}}
          _ -> {:xpath, xpath}
        end

      true ->
        {:xpath, xpath}
    end
  end

  defp extract_xpath_selector(xpath) do
    # Extract the first quoted string that appears as a locator value
    # XPath patterns use: ./@id = "selector" or contains(..., "selector")
    case Regex.run(~r{(?:= "|, "|\("|\)=")\s*([^"]+)"}, xpath) do
      [_, selector] -> selector
      _ -> xpath
    end
  end

  # --- Element interactions ---

  @impl true
  def click(%Element{} = element) do
    session = root_session(element)
    el_html = element_html(element)

    case get_view(session) do
      nil ->
        # Static/controller page — handle click via HTML inspection
        click_static(session, element, el_html)

      view ->
        selector = element_selector(element)
        lv_element = @lv_test.element(view, selector)
        html = @lv_test.render_click(lv_element)
        update_html(session, html)
        {:ok, nil}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp click_static(session, _element, el_html) do
    doc = LazyHTML.from_fragment(el_html)

    tag =
      case LazyHTML.tag(doc) do
        [t | _] -> t |> to_string() |> String.downcase()
        _ -> ""
      end

    cond do
      # Click on a link — navigate to href
      tag == "a" ->
        case first_attr(doc, "href") do
          nil ->
            {:ok, nil}

          href ->
            href =
              if String.starts_with?(href, "/") || String.starts_with?(href, "http"),
                do: href,
                else: "/#{href}"

            visit(session, href)
            {:ok, nil}
        end

      # Click on option — toggle selected
      tag == "option" ->
        toggle_option(session, el_html)

      # Click on radio button — set checked, uncheck siblings
      tag == "input" && first_attr(doc, "type") == "radio" ->
        toggle_radio(session, el_html)

      # Click on checkbox — toggle checked
      tag == "input" && first_attr(doc, "type") == "checkbox" ->
        toggle_checkbox(session, el_html)

      # Click on submit/image button — submit the parent form
      tag == "input" && first_attr(doc, "type") in ["submit", "image"] ->
        submit_form(session, el_html)

      # Click on button — check if it's a submit button
      tag == "button" ->
        type = first_attr(doc, "type")

        if type == "reset" do
          reset_form(session, el_html)
        else
          submit_form(session, el_html)
        end

      # Click on input[type=reset]
      tag == "input" && first_attr(doc, "type") == "reset" ->
        reset_form(session, el_html)

      true ->
        {:ok, nil}
    end
  end

  defp toggle_radio(session, el_html) do
    page_html = get_rendered_html(session)
    el_doc = parse_html(el_html)
    name = first_attr(el_doc, "name")
    id = first_attr(el_doc, "id")

    # Uncheck all radios with the same name, then check this one
    new_html =
      if name do
        # Remove checked from all radios with this name
        page_html
        |> String.replace(
          ~r/(<input[^>]*name="#{Regex.escape(name)}"[^>]*)\s+checked(="[^"]*")?/,
          "\\1"
        )
        |> then(fn h ->
          # Add checked to the clicked radio
          if id do
            String.replace(h, ~r/(<input[^>]*id="#{Regex.escape(id)}"[^>]*)>/, "\\1 checked>")
          else
            h
          end
        end)
      else
        page_html
      end

    put_state(session, nil, new_html, get_state(session)[:path])
    {:ok, nil}
  end

  defp toggle_checkbox(session, el_html) do
    page_html = get_rendered_html(session)
    el_doc = parse_html(el_html)
    id = first_attr(el_doc, "id")

    new_html =
      if id do
        # Toggle checked attribute
        pattern = ~r/(<input[^>]*id="#{Regex.escape(id)}"[^>]*)>/

        if Regex.match?(~r/id="#{Regex.escape(id)}"[^>]*checked/, page_html) do
          String.replace(
            page_html,
            ~r/(<input[^>]*id="#{Regex.escape(id)}"[^>]*)\s+checked(="[^"]*")?/,
            "\\1"
          )
        else
          String.replace(page_html, pattern, "\\1 checked>")
        end
      else
        page_html
      end

    put_state(session, nil, new_html, get_state(session)[:path])
    {:ok, nil}
  end

  defp toggle_option(session, option_html) do
    page_html = get_rendered_html(session)
    opt_doc = parse_html(option_html)
    id = first_attr(opt_doc, "id")
    value = first_attr(opt_doc, "value")

    # Match the option by id or value attribute in the page HTML
    pattern =
      cond do
        id -> ~r/(<option[^>]*id='#{Regex.escape(id)}'[^>]*)>/
        value -> ~r/(<option[^>]*value="#{Regex.escape(value)}"[^>]*)>/
        true -> nil
      end

    # For single-select, deselect all other options in the same select first
    new_html =
      if pattern do
        # Find the parent select by looking for <select> containing this option
        deselected =
          if id do
            # Remove selected from all options in the same select
            # Simple approach: remove all 'selected' from nearby options
            String.replace(page_html, ~r/(<option[^>]*)\s+selected/, "\\1")
          else
            page_html
          end

        # Then add selected to the target option
        String.replace(deselected, pattern, fn match ->
          if String.contains?(match, "selected") do
            match
          else
            String.replace(match, ">", " selected>")
          end
        end)
      else
        page_html
      end

    put_state(session, nil, new_html, get_state(session)[:path])
    {:ok, nil}
  end

  defp submit_form(session, button_html) do
    page_html = get_rendered_html(session)
    page_doc = LazyHTML.from_fragment(page_html)

    # Find the form containing this button
    form = find_parent_form(page_doc, button_html)

    case form do
      nil ->
        {:ok, nil}

      form_node ->
        raw_action = first_attr(form_node, "action") || get_state(session)[:path]
        action = if String.starts_with?(raw_action, "/"), do: raw_action, else: "/#{raw_action}"
        method = (first_attr(form_node, "method") || "get") |> String.downcase()

        # Collect form data
        form_data = collect_form_data(form_node)

        # For GET forms, just visit the action URL (simulates browser form submission)
        # For POST, dispatch directly
        if method == "post" do
          conn =
            @conn_test.build_conn()
            |> Plug.Conn.put_private(:phoenix_endpoint, session.server)
            |> @conn_test.dispatch(session.server, :post, action, form_data)

          put_state(session, nil, conn.resp_body || "", action)
        else
          visit(session, action)
        end

        {:ok, nil}
    end
  rescue
    _ -> {:ok, nil}
  end

  defp reset_form(session, _button_html) do
    # Re-visit the current page to reset form state
    path = get_state(session)[:path]
    visit(session, path)
    {:ok, nil}
  end

  defp find_parent_form(page_doc, button_html) do
    LazyHTML.query(page_doc, "form")
    |> Enum.find(fn form ->
      form_html = LazyHTML.to_html(form)
      # Check if the button HTML is contained within this form
      String.contains?(form_html, String.trim(button_html))
    end)
  end

  defp collect_form_data(form_node) do
    inputs =
      LazyHTML.query(form_node, "input")
      |> Enum.flat_map(fn input ->
        name = first_attr(input, "name")
        type = first_attr(input, "type") || "text"

        cond do
          name == nil ->
            []

          type in ["submit", "image", "button", "reset", "file"] ->
            []

          type in ["checkbox", "radio"] ->
            if first_attr(input, "checked") != nil do
              [{name, first_attr(input, "value") || "on"}]
            else
              []
            end

          true ->
            [{name, first_attr(input, "value") || ""}]
        end
      end)

    textareas =
      LazyHTML.query(form_node, "textarea")
      |> Enum.flat_map(fn ta ->
        name = first_attr(ta, "name")
        if name, do: [{name, LazyHTML.text(ta) || ""}], else: []
      end)

    selects =
      LazyHTML.query(form_node, "select")
      |> Enum.flat_map(fn select ->
        name = first_attr(select, "name")

        if name == nil do
          []
        else
          selected =
            LazyHTML.query(select, "option[selected]")
            |> Enum.map(fn opt -> first_attr(opt, "value") || LazyHTML.text(opt) end)
            |> List.first()

          if selected, do: [{name, selected}], else: []
        end
      end)

    Map.new(inputs ++ textareas ++ selects)
  end

  @impl true
  def clear(%Element{} = element, _opts \\ []), do: set_value(element, "")

  @impl true
  def set_value(%Element{} = element, value) do
    session = root_session(element)
    el_html = element_html(element)

    case get_view(session) do
      nil ->
        # Static page — update the value in stored HTML
        set_value_static(session, el_html, value)

      view ->
        name = extract_attr(el_html, "name")

        if name do
          form_selector =
            find_form_selector(get_rendered_html(session), element_selector(element))

          if form_selector do
            form = @lv_test.form(view, form_selector, %{name => value})
            html = @lv_test.render_change(form)
            update_html(session, html)
          else
            lv_el = @lv_test.element(view, element_selector(element))
            html = @lv_test.render_change(lv_el, %{value: value})
            update_html(session, html)
          end
        end

        {:ok, nil}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp set_value_static(session, _el_html, value) do
    # Store form field values in the process dictionary keyed by session + element
    # The element_html re-read will pick up the stored value
    state = get_state(session)
    field_values = Map.get(state, :field_values, %{})
    # Use the element's name or id as key
    el_doc = LazyHTML.from_fragment(_el_html)
    key = first_attr(el_doc, "id") || first_attr(el_doc, "name") || _el_html

    field_values = Map.put(field_values, key, value)
    put_state(session, state[:view], state[:html], state[:path], field_values)
    {:ok, nil}
  end

  @impl true
  def text(%Element{} = element) do
    html = element_html(element)
    doc = parse_html(html)
    raw = LazyHTML.text(doc) || ""
    # Normalize whitespace — collapse indentation, trim lines
    normalized =
      raw
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 != ""))
      |> Enum.join("\n")

    {:ok, normalized}
  end

  @impl true
  def attribute(%Element{} = element, attr_name) do
    # For "value", check stored field values first (from set_value_static)
    if attr_name == "value" do
      session = root_session(element)
      field_values = get_state(session)[:field_values] || %{}
      el_html = element_html(element)
      el_doc = parse_html(el_html)
      key = first_attr(el_doc, "id") || first_attr(el_doc, "name")

      case Map.get(field_values, key) do
        nil -> {:ok, extract_attr(el_html, attr_name)}
        val -> {:ok, val}
      end
    else
      html = element_html(element)
      {:ok, extract_attr(html, attr_name)}
    end
  end

  @impl true
  def displayed(%Element{} = _element), do: {:ok, true}

  @impl true
  def selected(%Element{bidi_shared_id: {:lv_element, _, _, _}} = element) do
    # Re-read from current page state to get updated checked/selected
    el_html = element_html(element)
    el_doc = parse_html(el_html)
    id = first_attr(el_doc, "id")

    session = root_session(element)
    page_html = get_rendered_html(session)

    selected =
      cond do
        # Check by id in current page HTML (handles both single and double quoted ids)
        id ->
          Regex.match?(~r/id=['"]#{Regex.escape(id)}['"][^>]*(?:checked|selected)/, page_html) or
            Regex.match?(~r/(?:checked|selected)[^>]*id=['"]#{Regex.escape(id)}['"]/, page_html)

        # For options without id, check by value
        true ->
          el_doc = parse_html(el_html)
          value = first_attr(el_doc, "value")

          if value do
            Regex.match?(
              ~r/<option[^>]*value="#{Regex.escape(value)}"[^>]*selected/,
              page_html
            ) or
              Regex.match?(
                ~r/<option[^>]*selected[^>]*value="#{Regex.escape(value)}"/,
                page_html
              )
          else
            first_attr(el_doc, "selected") != nil or
              first_attr(el_doc, "checked") != nil
          end
      end

    {:ok, selected}
  end

  # --- Page content ---

  @impl true
  def page_source(session), do: {:ok, get_rendered_html(session)}

  @impl true
  def page_title(session) do
    view = get_view(session)
    if view, do: {:ok, @lv_test.page_title(view) || ""}, else: {:ok, ""}
  rescue
    _ -> {:ok, ""}
  end

  # --- Browser-only operations ---
  #
  # These raise Wallabidi.DriverError with a clear message directing the
  # developer to tag the test with @tag :browser.

  @impl true
  def execute_script(_, _, _), do: raise(Wallabidi.DriverError.not_supported("execute_script/3"))
  @impl true
  def execute_script_async(_, _, _),
    do: raise(Wallabidi.DriverError.not_supported("execute_script_async/3"))

  @impl true
  def send_keys(_, _), do: raise(Wallabidi.DriverError.not_supported("send_keys/2"))
  @impl true
  def take_screenshot(_), do: raise(Wallabidi.DriverError.not_supported("take_screenshot/1"))
  @impl true
  def accept_alert(_, _), do: raise(Wallabidi.DriverError.not_supported("accept_alert/2"))
  @impl true
  def accept_confirm(_, _), do: raise(Wallabidi.DriverError.not_supported("accept_confirm/2"))
  @impl true
  def accept_prompt(_, _, _), do: raise(Wallabidi.DriverError.not_supported("accept_prompt/3"))
  @impl true
  def dismiss_confirm(_, _), do: raise(Wallabidi.DriverError.not_supported("dismiss_confirm/2"))
  @impl true
  def dismiss_prompt(_, _), do: raise(Wallabidi.DriverError.not_supported("dismiss_prompt/2"))
  @impl true
  def cookies(_), do: raise(Wallabidi.DriverError.not_supported("cookies/1"))
  @impl true
  def set_cookie(_, _, _), do: raise(Wallabidi.DriverError.not_supported("set_cookie/3"))
  @impl true
  def set_cookie(_, _, _, _), do: raise(Wallabidi.DriverError.not_supported("set_cookie/4"))

  # --- Stubbed window/frame operations (no-op, don't require a browser) ---

  @impl true
  def window_handle(_), do: {:ok, "lv-main"}
  @impl true
  def window_handles(_), do: {:ok, ["lv-main"]}
  @impl true
  def focus_window(_, _), do: {:ok, nil}
  @impl true
  def close_window(_), do: {:ok, nil}
  @impl true
  def maximize_window(_), do: {:ok, nil}
  @impl true
  def get_window_size(_), do: {:ok, %{"width" => 1024, "height" => 768}}
  @impl true
  def set_window_size(_, _, _), do: {:ok, nil}
  @impl true
  def get_window_position(_), do: {:ok, %{"x" => 0, "y" => 0}}
  @impl true
  def set_window_position(_, _, _), do: {:ok, nil}
  @impl true
  def focus_frame(_, _), do: {:ok, nil}
  @impl true
  def focus_parent_frame(_), do: {:ok, nil}

  def click(_, _), do: raise(Wallabidi.DriverError.not_supported("click/2 (mouse button)"))
  def double_click(_), do: raise(Wallabidi.DriverError.not_supported("double_click/1"))
  def button_down(_, _), do: raise(Wallabidi.DriverError.not_supported("button_down/2"))
  def button_up(_, _), do: raise(Wallabidi.DriverError.not_supported("button_up/2"))
  def move_mouse_to(_, _), do: raise(Wallabidi.DriverError.not_supported("move_mouse_to/2"))

  # --- Internal state ---

  defp put_state(session, view, html, path, field_values \\ %{}) do
    Process.put({:lv_driver, session.id}, %{
      view: view,
      html: html,
      path: path,
      field_values: field_values
    })
  end

  defp get_state(session) do
    Process.get({:lv_driver, session.id}) || %{}
  end

  defp get_view(session) do
    get_state(session)[:view]
  end

  defp get_rendered_html(%Session{} = session) do
    view = get_view(session)

    if view do
      # LiveView — render returns a fragment, no body extraction needed
      @lv_test.render(view)
    else
      html = get_state(session)[:html] || ""

      html
    end
  end

  defp get_rendered_html(%Element{} = element) do
    get_rendered_html(root_session(element))
  end

  defp update_html(session, html) when is_binary(html) do
    state = get_state(session)
    Process.put({:lv_driver, session.id}, %{state | html: html})
  end

  defp update_html(_, _), do: :ok

  defp root_session(%Session{} = s), do: s
  defp root_session(%Element{parent: p}), do: root_session(p)

  defp element_selector(%Element{bidi_shared_id: {:lv_element, sel, _, _}}), do: sel

  defp element_html(%Element{bidi_shared_id: {:lv_element, _, _, html}}), do: html

  defp extract_attr(html, name) do
    doc = parse_html(html)

    # For from_document, the root is <html> not the element itself.
    # Try attribute on root first, then on the first child element.
    case LazyHTML.attribute(doc, name) do
      [value | _] ->
        value

      [] ->
        # Try querying the actual element (e.g. body, div)
        tag =
          case Regex.run(~r/^<(\w+)/, String.trim(html)) do
            [_, t] -> t
            _ -> nil
          end

        if tag do
          case LazyHTML.query(doc, tag) do
            results when results != [] ->
              case LazyHTML.attribute(hd(Enum.to_list(results)), name) do
                [value | _] -> value
                _ -> nil
              end

            _ ->
              nil
          end
        else
          nil
        end
    end
  end

  defp parse_html(html) do
    if String.contains?(html, "<html") or String.contains?(html, "<!DOCTYPE") or
         String.starts_with?(String.trim_leading(html), "<body") do
      LazyHTML.from_document(html)
    else
      LazyHTML.from_fragment(html)
    end
  end

  defp find_form_selector(page_html, child_selector) do
    doc = LazyHTML.from_fragment(page_html)

    LazyHTML.query(doc, "form")
    |> Enum.filter(fn form -> not Enum.empty?(LazyHTML.query(form, child_selector)) end)
    |> Enum.find_value(&form_selector/1)
  end

  defp form_selector(form) do
    cond do
      id = first_attr(form, "id") -> "##{id}"
      phx = first_attr(form, "phx-submit") -> ~s(form[phx-submit="#{phx}"])
      phx = first_attr(form, "phx-change") -> ~s(form[phx-change="#{phx}"])
      true -> "form"
    end
  end

  defp first_attr(doc, name) do
    case LazyHTML.attribute(doc, name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
