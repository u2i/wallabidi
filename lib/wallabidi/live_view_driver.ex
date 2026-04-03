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
    endpoint = Keyword.fetch!(opts, :endpoint)

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
  def visit(session, path) do
    conn =
      @conn_test.build_conn()
      |> Plug.Conn.put_private(:phoenix_endpoint, session.server)

    conn = @conn_test.dispatch(conn, session.server, :get, path)
    {:ok, view, html} = @lv_test.__live__(conn, nil, [])

    put_state(session, view, html, path)
    :ok
  end

  @impl true
  def current_url(session), do: {:ok, get_state(session)[:path] || ""}

  @impl true
  def current_path(session), do: {:ok, get_state(session)[:path] || "/"}

  # --- Finding elements ---

  @impl true
  def find_elements(parent, {strategy, selector}) do
    html = get_rendered_html(parent)

    elements =
      case strategy do
        :css ->
          doc = LazyHTML.from_fragment(html)
          results = LazyHTML.query(doc, selector)

          results
          |> Enum.with_index()
          |> Enum.map(fn {node, idx} ->
            %Element{
              id: "lv-#{selector}-#{idx}",
              parent: parent,
              driver: __MODULE__,
              url: "",
              session_url: "",
              bidi_shared_id: {:lv_element, selector, idx, LazyHTML.to_html(node)}
            }
          end)

        _ ->
          []
      end

    {:ok, elements}
  end

  # --- Element interactions ---

  @impl true
  def click(%Element{} = element) do
    session = root_session(element)
    view = get_view(session)
    selector = element_selector(element)

    lv_element = @lv_test.element(view, selector)
    html = @lv_test.render_click(lv_element)
    update_html(session, html)
    {:ok, nil}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def clear(%Element{} = element), do: set_value(element, "")

  @impl true
  def set_value(%Element{} = element, value) do
    session = root_session(element)
    view = get_view(session)
    el_html = element_html(element)

    # Find the input name
    case extract_attr(el_html, "name") do
      nil ->
        {:error, :no_input_name}

      name ->
        # Find the parent form selector
        form_selector = find_form_selector(get_rendered_html(session), element_selector(element))

        if form_selector do
          form = @lv_test.form(view, form_selector, %{name => value})
          html = @lv_test.render_change(form)
          update_html(session, html)
        else
          # No form — try direct element change
          lv_el = @lv_test.element(view, element_selector(element))
          html = @lv_test.render_change(lv_el, %{value: value})
          update_html(session, html)
        end

        {:ok, nil}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def text(%Element{} = element) do
    html = element_html(element)
    doc = LazyHTML.from_fragment(html)
    {:ok, LazyHTML.text(doc)}
  end

  @impl true
  def attribute(%Element{} = element, attr_name) do
    html = element_html(element)
    {:ok, extract_attr(html, attr_name)}
  end

  @impl true
  def displayed(%Element{} = _element), do: {:ok, true}

  @impl true
  def selected(%Element{} = element) do
    html = element_html(element)
    doc = LazyHTML.from_fragment(html)

    selected =
      first_attr(doc, "selected") != nil or
        first_attr(doc, "checked") != nil

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

  # --- Not supported ---

  @impl true
  def execute_script(_, _, _), do: {:error, :not_supported}
  @impl true
  def execute_script_async(_, _, _), do: {:error, :not_supported}
  @impl true
  def send_keys(_, _), do: {:error, :not_supported}
  @impl true
  def take_screenshot(_), do: {:error, :not_supported}
  @impl true
  def accept_alert(_, _), do: {:error, :not_supported}
  @impl true
  def accept_confirm(_, _), do: {:error, :not_supported}
  @impl true
  def accept_prompt(_, _, _), do: {:error, :not_supported}
  @impl true
  def dismiss_confirm(_, _), do: {:error, :not_supported}
  @impl true
  def dismiss_prompt(_, _), do: {:error, :not_supported}
  @impl true
  def cookies(_), do: {:ok, []}
  @impl true
  def set_cookie(_, _, _), do: {:error, :not_supported}
  @impl true
  def set_cookie(_, _, _, _), do: {:error, :not_supported}
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

  def click(_, _), do: {:error, :not_supported}
  def double_click(_), do: {:error, :not_supported}
  def button_down(_, _), do: {:error, :not_supported}
  def button_up(_, _), do: {:error, :not_supported}
  def move_mouse_to(_, _), do: {:error, :not_supported}

  # --- Internal state ---

  defp put_state(session, view, html, path) do
    Process.put({:lv_driver, session.id}, %{view: view, html: html, path: path})
  end

  defp get_state(session) do
    Process.get({:lv_driver, session.id}) || %{}
  end

  defp get_view(session) do
    get_state(session)[:view]
  end

  defp get_rendered_html(%Session{} = session) do
    view = get_view(session)
    if view, do: @lv_test.render(view), else: get_state(session)[:html] || ""
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
    doc = LazyHTML.from_fragment(html)

    case LazyHTML.attribute(doc, name) do
      [value | _] -> value
      [] -> nil
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
