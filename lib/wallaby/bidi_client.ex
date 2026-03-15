defmodule Wallaby.BiDiClient do
  @moduledoc false
  # BiDi protocol client mirroring WebdriverClient function signatures.
  # Sends commands via WebSocket using the BiDi protocol.

  alias Wallaby.{Element, Session}
  alias Wallaby.BiDi.{Commands, ResponseParser, WebSocketClient}

  @type parent :: Element.t() | Session.t()

  # Session helpers

  defp bidi_pid(%Session{bidi_pid: pid}), do: pid
  defp bidi_pid(%Element{parent: parent}), do: bidi_pid(parent)

  defp browsing_context(%Session{browsing_context: ctx}), do: ctx
  defp browsing_context(%Element{parent: parent}), do: browsing_context(parent)

  defp session(%Session{} = s), do: s
  defp session(%Element{parent: parent}), do: session(parent)

  defp send_bidi(parent, method, params) do
    pid = bidi_pid(parent)
    WebSocketClient.send_command(pid, method, params)
    |> ResponseParser.check_error()
  end

  # Navigation

  def visit(session, url) do
    context = browsing_context(session)
    {method, params} = Commands.navigate(context, url)

    case send_bidi(session, method, params) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def current_url(session) do
    context = browsing_context(session)
    {method, params} = Commands.evaluate(context, "window.location.href")

    case send_bidi(session, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def current_path(session) do
    case current_url(session) do
      {:ok, url} ->
        url
        |> URI.parse()
        |> Map.fetch(:path)

      error ->
        error
    end
  end

  # Element finding

  def find_elements(parent, {:css, css}) do
    context = browsing_context(parent)
    locator = %{type: "css", value: css}

    {method, params} =
      case parent do
        %Element{bidi_shared_id: shared_id} when not is_nil(shared_id) ->
          Commands.locate_nodes(context, locator, [%{sharedId: shared_id}])

        _ ->
          Commands.locate_nodes(context, locator)
      end

    case send_bidi(parent, method, params) do
      {:ok, result} ->
        case ResponseParser.extract_nodes(result) do
          {:ok, nodes} ->
            sess = session(parent)
            {:ok, ResponseParser.cast_elements(sess, nodes)}

          error ->
            error
        end

      error ->
        error
    end
  end

  def find_elements(parent, {:xpath, xpath}) do
    context = browsing_context(parent)

    # XPath is not directly supported in BiDi locateNodes,
    # so we use script.callFunction with document.evaluate
    root_arg =
      case parent do
        %Element{bidi_shared_id: shared_id} when not is_nil(shared_id) ->
          %{type: "element", element: %{sharedId: shared_id}}

        _ ->
          %{type: "undefined"}
      end

    # When root is undefined, use document as the context node
    js_with_fallback = """
    (root, xpathExpr) => {
      const contextNode = (root && root.nodeType) ? root : document;
      const result = document.evaluate(xpathExpr, contextNode, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      const elements = [];
      for (let i = 0; i < result.snapshotLength; i++) {
        elements.push(result.snapshotItem(i));
      }
      return elements;
    }
    """

    {method, params} =
      Commands.call_function(context, js_with_fallback, [
        root_arg,
        %{type: "string", value: xpath}
      ])

    case send_bidi(parent, method, params) do
      {:ok, %{"result" => %{"type" => "array", "value" => items}}} ->
        sess = session(parent)

        elements =
          items
          |> Enum.filter(fn item -> item["type"] == "node" end)
          |> Enum.map(fn node ->
            shared_id = node["sharedId"]
            {shared_id, node}
          end)

        {:ok, ResponseParser.cast_elements(sess, elements)}

      {:ok, _} ->
        {:ok, []}

      error ->
        error
    end
  end

  # Element interactions

  def click(%Element{bidi_shared_id: shared_id} = element) when not is_nil(shared_id) do
    context = browsing_context(element)
    actions = Commands.pointer_click_actions(shared_id)
    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(element, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def click(%Element{} = element) do
    # Fallback to WebDriver if no shared_id
    Wallaby.WebdriverClient.click(element)
  end

  def click(parent, button) do
    # Mouse button clicks delegate to WebDriver (complex action sequences)
    Wallaby.WebdriverClient.click(parent, button)
  end

  def clear(%Element{bidi_shared_id: shared_id} = element) when not is_nil(shared_id) do
    context = browsing_context(element)

    js = """
    (el) => {
      el.value = '';
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    """

    {method, params} =
      Commands.call_function(context, js, [%{type: "element", element: %{sharedId: shared_id}}])

    case send_bidi(element, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def clear(%Element{} = element) do
    Wallaby.WebdriverClient.clear(element)
  end

  def set_value(%Element{bidi_shared_id: shared_id} = element, value) when not is_nil(shared_id) do
    context = browsing_context(element)

    # Focus the element first, then type
    focus_js = "(el) => el.focus()"

    {method, params} =
      Commands.call_function(context, focus_js, [
        %{type: "element", element: %{sharedId: shared_id}}
      ])

    case send_bidi(element, method, params) do
      {:ok, _} ->
        actions = Commands.key_type_actions(to_string(value))
        {method2, params2} = Commands.perform_actions(context, actions)

        case send_bidi(element, method2, params2) do
          {:ok, _} -> {:ok, nil}
          error -> error
        end

      error ->
        error
    end
  end

  def set_value(%Element{} = element, value) do
    Wallaby.WebdriverClient.set_value(element, value)
  end

  def text(%Element{bidi_shared_id: shared_id} = element) when not is_nil(shared_id) do
    context = browsing_context(element)

    {method, params} =
      Commands.call_function(context, "(el) => el.innerText", [
        %{type: "element", element: %{sharedId: shared_id}}
      ])

    case send_bidi(element, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def text(%Element{} = element) do
    Wallaby.WebdriverClient.text(element)
  end

  def attribute(%Element{bidi_shared_id: shared_id} = element, name)
      when not is_nil(shared_id) do
    context = browsing_context(element)

    {method, params} =
      Commands.call_function(
        context,
        "(el, name) => el.getAttribute(name)",
        [
          %{type: "element", element: %{sharedId: shared_id}},
          %{type: "string", value: name}
        ]
      )

    case send_bidi(element, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def attribute(%Element{} = element, name) do
    Wallaby.WebdriverClient.attribute(element, name)
  end

  def displayed(%Element{bidi_shared_id: shared_id} = element) when not is_nil(shared_id) do
    context = browsing_context(element)

    js = """
    (el) => {
      if (!el.ownerDocument) return false;
      const style = window.getComputedStyle(el);
      return style.display !== 'none' &&
             style.visibility !== 'hidden' &&
             style.opacity !== '0' &&
             el.offsetWidth > 0 &&
             el.offsetHeight > 0;
    }
    """

    {method, params} =
      Commands.call_function(context, js, [
        %{type: "element", element: %{sharedId: shared_id}}
      ])

    case send_bidi(element, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def displayed(%Element{} = element) do
    Wallaby.WebdriverClient.displayed(element)
  end

  def selected(%Element{bidi_shared_id: shared_id} = element) when not is_nil(shared_id) do
    context = browsing_context(element)

    {method, params} =
      Commands.call_function(
        context,
        "(el) => el.selected || el.checked || false",
        [%{type: "element", element: %{sharedId: shared_id}}]
      )

    case send_bidi(element, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def selected(%Element{} = element) do
    Wallaby.WebdriverClient.selected(element)
  end

  # Script execution

  def execute_script(session_or_element, script, arguments \\ []) do
    context = browsing_context(session_or_element)

    bidi_args =
      Enum.map(arguments, fn
        arg when is_binary(arg) -> %{type: "string", value: arg}
        arg when is_integer(arg) -> %{type: "number", value: arg}
        arg when is_float(arg) -> %{type: "number", value: arg}
        arg when is_boolean(arg) -> %{type: "boolean", value: arg}
        nil -> %{type: "null"}
        %Element{bidi_shared_id: sid} when not is_nil(sid) ->
          %{type: "element", element: %{sharedId: sid}}
        arg when is_map(arg) -> %{type: "object", value: arg}
        arg when is_list(arg) -> %{type: "array", value: arg}
      end)

    # Wrap the script to accept arguments array
    wrapped = "(arguments) => { #{script} }"

    {method, params} =
      Commands.call_function(context, wrapped, [%{type: "array", value: bidi_args}])

    case send_bidi(session_or_element, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def execute_script_async(session_or_element, script, arguments \\ []) do
    context = browsing_context(session_or_element)

    bidi_args =
      Enum.map(arguments, fn
        arg when is_binary(arg) -> %{type: "string", value: arg}
        arg when is_integer(arg) -> %{type: "number", value: arg}
        arg when is_float(arg) -> %{type: "number", value: arg}
        arg when is_boolean(arg) -> %{type: "boolean", value: arg}
        nil -> %{type: "null"}
        %Element{bidi_shared_id: sid} when not is_nil(sid) ->
          %{type: "element", element: %{sharedId: sid}}
        arg when is_map(arg) -> %{type: "object", value: arg}
        arg when is_list(arg) -> %{type: "array", value: arg}
      end)

    # Async scripts use a callback as the last argument; wrap as Promise
    wrapped = """
    (arguments) => {
      return new Promise((resolve, reject) => {
        const args = [...arguments, resolve];
        (function() { #{script} }).apply(null, args);
      });
    }
    """

    {method, params} =
      Commands.call_function(context, wrapped, [%{type: "array", value: bidi_args}], %{
        await_promise: true
      })

    case send_bidi(session_or_element, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  # Screenshots

  def take_screenshot(session_or_element) do
    context = browsing_context(session_or_element)
    {method, params} = Commands.capture_screenshot(context)

    case send_bidi(session_or_element, method, params) do
      {:ok, result} ->
        case ResponseParser.extract_screenshot(result) do
          {:ok, data} -> data
          error -> error
        end

      error ->
        error
    end
  end

  # Cookies

  def cookies(session) do
    context = browsing_context(session)
    {method, params} = Commands.get_cookies(%{partition: %{type: "context", context: context}})

    case send_bidi(session, method, params) do
      {:ok, result} -> ResponseParser.extract_cookies(result)
      error -> error
    end
  end

  def set_cookie(session, key, value, attributes \\ []) do
    context = browsing_context(session)

    cookie =
      %{
        name: key,
        value: %{type: "string", value: value},
        domain: Keyword.get(attributes, :domain, "localhost"),
        path: Keyword.get(attributes, :path, "/")
      }
      |> maybe_put(:secure, Keyword.get(attributes, :secure))
      |> maybe_put(:httpOnly, Keyword.get(attributes, :httpOnly))
      |> maybe_put(:expiry, Keyword.get(attributes, :expiry))

    {method, params} =
      Commands.set_cookie(cookie, %{partition: %{type: "context", context: context}})

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Page info

  def page_source(session) do
    context = browsing_context(session)
    {method, params} = Commands.evaluate(context, "document.documentElement.outerHTML")

    case send_bidi(session, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def page_title(session) do
    context = browsing_context(session)
    {method, params} = Commands.evaluate(context, "document.title")

    case send_bidi(session, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  # Window management

  def window_handles(session) do
    {method, params} = Commands.get_tree()

    case send_bidi(session, method, params) do
      {:ok, result} -> ResponseParser.extract_all_contexts(result)
      error -> error
    end
  end

  def window_handle(session) do
    {:ok, browsing_context(session)}
  end

  def focus_window(session, window_handle) do
    {method, params} = Commands.activate(window_handle)

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def close_window(session) do
    context = browsing_context(session)
    {method, params} = Commands.close_context(context)

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  # Frame management

  def focus_frame(session, nil) do
    # Switch to top-level context - handled by getting the tree
    {method, params} = Commands.get_tree()

    case send_bidi(session, method, params) do
      {:ok, result} ->
        case ResponseParser.extract_context(result) do
          {:ok, _context} -> {:ok, nil}
          error -> error
        end

      error ->
        error
    end
  end

  def focus_frame(session, %Element{bidi_shared_id: shared_id} = _frame)
      when not is_nil(shared_id) do
    # Get the frame's browsing context via script
    context = browsing_context(session)

    js = "(frame) => frame.contentWindow ? true : false"

    {method, params} =
      Commands.call_function(context, js, [
        %{type: "element", element: %{sharedId: shared_id}}
      ])

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def focus_frame(session, frame) do
    # Numeric frame index or string - fallback to WebDriver
    Wallaby.WebdriverClient.focus_frame(session, frame)
  end

  def focus_parent_frame(session) do
    # Fallback to WebDriver
    Wallaby.WebdriverClient.focus_parent_frame(session)
  end

  # Key sending

  def send_keys(%Session{} = session, keys) when is_list(keys) do
    context = browsing_context(session)
    actions = Commands.key_type_actions(keys)
    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def send_keys(%Element{bidi_shared_id: shared_id} = element, keys)
      when is_list(keys) and not is_nil(shared_id) do
    context = browsing_context(element)

    # Focus the element first
    focus_js = "(el) => el.focus()"

    {method, params} =
      Commands.call_function(context, focus_js, [
        %{type: "element", element: %{sharedId: shared_id}}
      ])

    case send_bidi(element, method, params) do
      {:ok, _} ->
        actions = Commands.key_type_actions(keys)
        {method2, params2} = Commands.perform_actions(context, actions)

        case send_bidi(element, method2, params2) do
          {:ok, _} -> {:ok, nil}
          error -> error
        end

      error ->
        error
    end
  end

  def send_keys(%Element{} = element, keys) when is_list(keys) do
    Wallaby.WebdriverClient.send_keys(element, keys)
  end

  # Element size and location

  def element_size(%Element{bidi_shared_id: shared_id} = element)
      when not is_nil(shared_id) do
    context = browsing_context(element)

    js = "(el) => { const r = el.getBoundingClientRect(); return [r.width, r.height]; }"

    {method, params} =
      Commands.call_function(context, js, [
        %{type: "element", element: %{sharedId: shared_id}}
      ])

    case send_bidi(element, method, params) do
      {:ok, result} ->
        case ResponseParser.extract_value(result) do
          {:ok, [width, height]} -> {:ok, {width, height}}
          error -> error
        end

      error ->
        error
    end
  end

  def element_size(%Element{} = element) do
    Wallaby.WebdriverClient.element_size(element)
  end

  def element_location(%Element{bidi_shared_id: shared_id} = element)
      when not is_nil(shared_id) do
    context = browsing_context(element)

    js = "(el) => { const r = el.getBoundingClientRect(); return [r.x, r.y]; }"

    {method, params} =
      Commands.call_function(context, js, [
        %{type: "element", element: %{sharedId: shared_id}}
      ])

    case send_bidi(element, method, params) do
      {:ok, result} ->
        case ResponseParser.extract_value(result) do
          {:ok, [x, y]} -> {:ok, {x, y}}
          error -> error
        end

      error ->
        error
    end
  end

  def element_location(%Element{} = element) do
    Wallaby.WebdriverClient.element_location(element)
  end

  # Hover (move_mouse_to)

  def move_mouse_to(%Element{bidi_shared_id: shared_id} = element, %Element{} = _target)
      when not is_nil(shared_id) do
    context = browsing_context(element)
    actions = Commands.pointer_move_actions(shared_id)
    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(element, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def move_mouse_to(session, element, x_offset \\ nil, y_offset \\ nil) do
    Wallaby.WebdriverClient.move_mouse_to(session, element, x_offset, y_offset)
  end

  # Log - initially falls back to WebDriver, will be migrated to event subscription
  def log(session) do
    Wallaby.WebdriverClient.log(session)
  end

  # Operations that fall back to WebDriver (not in BiDi spec yet)

  def double_click(parent), do: Wallaby.WebdriverClient.double_click(parent)
  def button_down(parent, button), do: Wallaby.WebdriverClient.button_down(parent, button)
  def button_up(parent, button), do: Wallaby.WebdriverClient.button_up(parent, button)

  def touch_down(session, element, x, y),
    do: Wallaby.WebdriverClient.touch_down(session, element, x, y)

  def touch_up(session), do: Wallaby.WebdriverClient.touch_up(session)
  def tap(element), do: Wallaby.WebdriverClient.tap(element)
  def touch_move(parent, x, y), do: Wallaby.WebdriverClient.touch_move(parent, x, y)

  def touch_scroll(element, x, y),
    do: Wallaby.WebdriverClient.touch_scroll(element, x, y)

  def set_window_size(session, w, h),
    do: Wallaby.WebdriverClient.set_window_size(session, w, h)

  def get_window_size(session), do: Wallaby.WebdriverClient.get_window_size(session)

  def set_window_position(session, x, y),
    do: Wallaby.WebdriverClient.set_window_position(session, x, y)

  def get_window_position(session), do: Wallaby.WebdriverClient.get_window_position(session)
  def maximize_window(session), do: Wallaby.WebdriverClient.maximize_window(session)
end
