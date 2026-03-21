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

  - No JavaScript execution (execute_script returns {:error, :not_supported})
  - No window management, frames, cookies, screenshots, dialogs
  - No real HTTP (XHR, fetch) — only LiveView events
  - Forms must use phx-change/phx-submit, not JS-driven submission
  """

  @behaviour Wallabidi.Driver

  # These are test helpers — only available in test env
  # Using Module.concat to avoid compile-time dependency
  @conn_test Phoenix.ConnTest
  @lv_test Phoenix.LiveViewTest

  alias Wallabidi.{Session, Element}

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
  def end_session(_session), do: :ok

  # --- Navigation ---

  @impl true
  def visit(session, path) do
    conn =
      @conn_test.build_conn()
      |> Plug.Conn.put_private(:phoenix_endpoint, session.server)

    {:ok, view, html} = @lv_test.live(conn, path)
    put_view(session, view, html)
    :ok
  end

  @impl true
  def current_url(session) do
    case get_view(session) do
      nil -> {:ok, ""}
      _view -> {:ok, session.url}
    end
  end

  @impl true
  def current_path(session) do
    case current_url(session) do
      {:ok, url} -> {:ok, URI.parse(url).path || "/"}
      error -> error
    end
  end

  # --- Finding elements ---

  @impl true
  def find_elements(session_or_element, query) do
    html = get_html(session_or_element)
    {strategy, selector} = query

    elements =
      case strategy do
        :css ->
          html
          |> LazyHtml.parse()
          |> LazyHtml.find(selector)
          |> Enum.with_index()
          |> Enum.map(fn {node, idx} ->
            %Element{
              id: "#{selector}-#{idx}",
              parent: session_or_element,
              driver: __MODULE__,
              url: "",
              session_url: "",
              bidi_shared_id: {:lv_element, selector, idx, node_to_html(node)}
            }
          end)

        :xpath ->
          # XPath not supported in direct mode
          []
      end

    {:ok, elements}
  end

  # --- Element interactions ---

  @impl true
  def click(%Element{} = element) do
    session = root_session(element)
    view = get_view(session)

    if view do
      selector = element_selector(element)

      case @lv_test.render_click(view, selector) do
        html when is_binary(html) ->
          update_html(session, html)
          {:ok, nil}

        {:error, _} = error ->
          error
      end
    else
      {:error, :no_live_view}
    end
  end

  @impl true
  def clear(%Element{} = element) do
    set_value(element, "")
  end

  @impl true
  def set_value(%Element{} = element, value) do
    session = root_session(element)
    view = get_view(session)

    if view do
      selector = element_selector(element)

      # Determine the input name from the element HTML
      case get_input_name(element) do
        nil ->
          {:error, :no_input_name}

        name ->
          html = @lv_test.render_change(view, selector, %{name => value})
          update_html(session, html)
          {:ok, nil}
      end
    else
      {:error, :no_live_view}
    end
  end

  @impl true
  def text(%Element{} = element) do
    {:ok, element_text(element)}
  end

  @impl true
  def attribute(%Element{} = element, attr_name) do
    html = element_html(element)

    case LazyHtml.parse(html) |> LazyHtml.find("[#{attr_name}]") do
      [{_tag, attrs, _children} | _] ->
        value = Enum.find_value(attrs, fn {k, v} -> if k == attr_name, do: v end)
        {:ok, value}

      _ ->
        # Try parsing the element itself
        case LazyHtml.parse(html) do
          [{_tag, attrs, _children} | _] ->
            value = Enum.find_value(attrs, fn {k, v} -> if k == attr_name, do: v end)
            {:ok, value}

          _ ->
            {:ok, nil}
        end
    end
  end

  @impl true
  def displayed(%Element{} = _element) do
    # In direct mode, if the element was found it's "displayed"
    {:ok, true}
  end

  @impl true
  def selected(%Element{} = element) do
    html = element_html(element)
    {:ok, String.contains?(html, "selected") or String.contains?(html, "checked")}
  end

  # --- Page content ---

  @impl true
  def page_source(session) do
    {:ok, get_html(session)}
  end

  @impl true
  def page_title(session) do
    html = get_html(session)

    title =
      case Regex.run(~r/<title[^>]*>([^<]*)<\/title>/i, html) do
        [_, title] -> String.trim(title)
        _ -> ""
      end

    {:ok, title}
  end

  # --- Not supported in direct mode ---

  @impl true
  def execute_script(_session, _script, _args), do: {:error, :not_supported}

  @impl true
  def execute_script_async(_session, _script, _args), do: {:error, :not_supported}

  @impl true
  def send_keys(_session, _keys), do: {:error, :not_supported}

  @impl true
  def take_screenshot(_session), do: {:error, :not_supported}

  @impl true
  def accept_alert(_session, _fun), do: {:error, :not_supported}

  @impl true
  def accept_confirm(_session, _fun), do: {:error, :not_supported}

  @impl true
  def accept_prompt(_session, _input, _fun), do: {:error, :not_supported}

  @impl true
  def dismiss_confirm(_session, _fun), do: {:error, :not_supported}

  @impl true
  def dismiss_prompt(_session, _fun), do: {:error, :not_supported}

  @impl true
  def cookies(_session), do: {:ok, []}

  @impl true
  def set_cookie(_session, _name, _value), do: {:error, :not_supported}

  @impl true
  def set_cookie(_session, _name, _value, _opts), do: {:error, :not_supported}

  @impl true
  def window_handle(_session), do: {:ok, "lv-main"}

  @impl true
  def window_handles(_session), do: {:ok, ["lv-main"]}

  @impl true
  def focus_window(_session, _handle), do: {:ok, nil}

  @impl true
  def close_window(_session), do: {:ok, nil}

  @impl true
  def maximize_window(_session), do: {:ok, nil}

  @impl true
  def get_window_size(_session), do: {:ok, %{"width" => 1024, "height" => 768}}

  @impl true
  def set_window_size(_session, _w, _h), do: {:ok, nil}

  @impl true
  def get_window_position(_session), do: {:ok, %{"x" => 0, "y" => 0}}

  @impl true
  def set_window_position(_session, _x, _y), do: {:ok, nil}

  @impl true
  def focus_frame(_session, _frame), do: {:ok, nil}

  @impl true
  def focus_parent_frame(_session), do: {:ok, nil}

  # Also need click on session (mouse click at position)
  def click(_session, _button), do: {:error, :not_supported}

  def double_click(_session), do: {:error, :not_supported}

  def button_down(_session, _button), do: {:error, :not_supported}

  def button_up(_session, _button), do: {:error, :not_supported}

  def move_mouse_to(_session, _element), do: {:error, :not_supported}

  # --- Internal state management ---
  # Store the LiveView and rendered HTML in the process dictionary
  # keyed by session id. This avoids needing mutable state in the Session struct.

  defp put_view(session, view, html) do
    Process.put({:lv_driver, session.id}, %{view: view, html: html})
  end

  defp get_view(session) do
    case Process.get({:lv_driver, session.id}) do
      %{view: view} -> view
      _ -> nil
    end
  end

  defp get_html(%Session{} = session) do
    case Process.get({:lv_driver, session.id}) do
      %{html: html} -> html
      _ -> ""
    end
  end

  defp get_html(%Element{} = element) do
    get_html(root_session(element))
  end

  defp update_html(session, html) do
    case Process.get({:lv_driver, session.id}) do
      %{} = state -> Process.put({:lv_driver, session.id}, %{state | html: html})
      _ -> :ok
    end
  end

  defp root_session(%Element{parent: %Session{} = session}), do: session
  defp root_session(%Element{parent: parent}), do: root_session(parent)

  defp element_selector(%Element{bidi_shared_id: {:lv_element, selector, _idx, _html}}) do
    selector
  end

  defp element_html(%Element{bidi_shared_id: {:lv_element, _selector, _idx, html}}) do
    html
  end

  defp element_text(%Element{} = element) do
    html = element_html(element)

    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end

  defp get_input_name(%Element{} = element) do
    html = element_html(element)

    case Regex.run(~r/name="([^"]*)"/, html) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp node_to_html({tag, attrs, children}) do
    attr_str = Enum.map_join(attrs, " ", fn {k, v} -> ~s(#{k}="#{v}") end)
    children_str = Enum.map_join(children, "", &node_to_html/1)
    open = if attr_str == "", do: "<#{tag}>", else: "<#{tag} #{attr_str}>"
    "#{open}#{children_str}</#{tag}>"
  end

  defp node_to_html(text) when is_binary(text), do: text
  defp node_to_html(_), do: ""
end
