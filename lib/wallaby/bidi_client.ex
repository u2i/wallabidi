defmodule Wallaby.BiDiClient do
  @moduledoc false
  # Pure BiDi protocol client — no WebdriverClient fallbacks.
  # All operations go through WebSocket using the BiDi protocol.

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

  defp element_arg(shared_id) do
    %{type: "element", element: %{sharedId: shared_id}}
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

    root_arg =
      case parent do
        %Element{bidi_shared_id: shared_id} when not is_nil(shared_id) ->
          element_arg(shared_id)

        _ ->
          %{type: "undefined"}
      end

    js = """
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
      Commands.call_function(context, js, [root_arg, %{type: "string", value: xpath}])

    case send_bidi(parent, method, params) do
      {:ok, %{"result" => %{"type" => "array", "value" => items}}} ->
        sess = session(parent)

        elements =
          items
          |> Enum.filter(fn item -> item["type"] == "node" end)
          |> Enum.map(fn node -> {node["sharedId"], node} end)

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

  def click(%Element{} = _element) do
    {:error, :no_bidi_shared_id}
  end

  def click(parent, button) when button in [:left, :middle, :right] do
    context = browsing_context(parent)
    actions = Commands.pointer_click_at_position_actions(button)
    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(parent, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
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

    {method, params} = Commands.call_function(context, js, [element_arg(shared_id)])

    case send_bidi(element, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def clear(%Element{} = _element), do: {:error, :no_bidi_shared_id}

  def set_value(%Element{bidi_shared_id: shared_id} = element, value)
      when not is_nil(shared_id) do
    context = browsing_context(element)

    {method, params} =
      Commands.call_function(context, "(el) => el.focus()", [element_arg(shared_id)])

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

  def set_value(%Element{} = _element, _value), do: {:error, :no_bidi_shared_id}

  def text(%Element{bidi_shared_id: shared_id} = element) when not is_nil(shared_id) do
    context = browsing_context(element)

    {method, params} =
      Commands.call_function(context, "(el) => el.innerText", [element_arg(shared_id)])

    case send_bidi(element, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def text(%Element{} = _element), do: {:error, :no_bidi_shared_id}

  def attribute(%Element{bidi_shared_id: shared_id} = element, name)
      when not is_nil(shared_id) do
    context = browsing_context(element)

    {method, params} =
      Commands.call_function(
        context,
        "(el, name) => el.getAttribute(name)",
        [element_arg(shared_id), %{type: "string", value: name}]
      )

    case send_bidi(element, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def attribute(%Element{} = _element, _name), do: {:error, :no_bidi_shared_id}

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

    {method, params} = Commands.call_function(context, js, [element_arg(shared_id)])

    case send_bidi(element, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def displayed(%Element{} = _element), do: {:error, :no_bidi_shared_id}

  def selected(%Element{bidi_shared_id: shared_id} = element) when not is_nil(shared_id) do
    context = browsing_context(element)

    {method, params} =
      Commands.call_function(
        context,
        "(el) => el.selected || el.checked || false",
        [element_arg(shared_id)]
      )

    case send_bidi(element, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def selected(%Element{} = _element), do: {:error, :no_bidi_shared_id}

  # Script execution

  def execute_script(session_or_element, script, arguments \\ []) do
    context = browsing_context(session_or_element)
    bidi_args = encode_args(arguments)
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
    bidi_args = encode_args(arguments)

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

  defp encode_args(arguments) do
    Enum.map(arguments, fn
      arg when is_binary(arg) ->
        %{type: "string", value: arg}

      arg when is_integer(arg) ->
        %{type: "number", value: arg}

      arg when is_float(arg) ->
        %{type: "number", value: arg}

      arg when is_boolean(arg) ->
        %{type: "boolean", value: arg}

      nil ->
        %{type: "null"}

      %Element{bidi_shared_id: sid} when not is_nil(sid) ->
        element_arg(sid)

      arg when is_map(arg) ->
        %{type: "object", value: arg}

      arg when is_list(arg) ->
        %{type: "array", value: arg}
    end)
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

  def focus_window(session, window_handle_id) do
    {method, params} = Commands.activate(window_handle_id)

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

  # Window size and position (via JavaScript — no chromedriver needed)

  def set_window_size(session, width, height) do
    context = browsing_context(session)
    {method, params} = Commands.set_viewport(context, width, height)

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def get_window_size(session) do
    context = browsing_context(session)

    {method, params} =
      Commands.evaluate(
        context,
        "({width: window.innerWidth, height: window.innerHeight})"
      )

    case send_bidi(session, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def set_window_position(session, x, y) do
    context = browsing_context(session)

    {method, params} =
      Commands.evaluate(context, "window.moveTo(#{x}, #{y}); null")

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def get_window_position(session) do
    context = browsing_context(session)

    {method, params} =
      Commands.evaluate(context, "({x: window.screenX, y: window.screenY})")

    case send_bidi(session, method, params) do
      {:ok, result} -> ResponseParser.extract_value(result)
      error -> error
    end
  end

  def maximize_window(session) do
    context = browsing_context(session)

    {method, params} =
      Commands.evaluate(
        context,
        "window.moveTo(0,0); window.resizeTo(screen.width, screen.height); null"
      )

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  # Frame management

  def focus_frame(session, nil) do
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

  def focus_frame(session, %Element{bidi_shared_id: shared_id})
      when not is_nil(shared_id) do
    context = browsing_context(session)

    js = "(frame) => frame.contentWindow ? true : false"

    {method, params} =
      Commands.call_function(context, js, [element_arg(shared_id)])

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def focus_frame(session, frame_index) when is_integer(frame_index) do
    context = browsing_context(session)

    js = """
    (index) => {
      const frames = document.querySelectorAll('iframe, frame');
      if (index < frames.length) return true;
      throw new Error('Frame index out of bounds');
    }
    """

    {method, params} =
      Commands.call_function(context, js, [%{type: "number", value: frame_index}])

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def focus_frame(_session, _frame), do: {:ok, nil}

  def focus_parent_frame(session) do
    context = browsing_context(session)

    {method, params} = Commands.evaluate(context, "window.parent !== window")

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
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

    {method, params} =
      Commands.call_function(context, "(el) => el.focus()", [element_arg(shared_id)])

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

  def send_keys(%Element{} = _element, _keys), do: {:error, :no_bidi_shared_id}

  # Element size and location

  def element_size(%Element{bidi_shared_id: shared_id} = element)
      when not is_nil(shared_id) do
    context = browsing_context(element)

    js = "(el) => { const r = el.getBoundingClientRect(); return [r.width, r.height]; }"

    {method, params} = Commands.call_function(context, js, [element_arg(shared_id)])

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

  def element_size(%Element{} = _element), do: {:error, :no_bidi_shared_id}

  def element_location(%Element{bidi_shared_id: shared_id} = element)
      when not is_nil(shared_id) do
    context = browsing_context(element)

    js = "(el) => { const r = el.getBoundingClientRect(); return [r.x, r.y]; }"

    {method, params} = Commands.call_function(context, js, [element_arg(shared_id)])

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

  def element_location(%Element{} = _element), do: {:error, :no_bidi_shared_id}

  # Mouse actions

  def move_mouse_to(%Element{bidi_shared_id: shared_id} = element, %Element{})
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
    parent = if element, do: element, else: session

    context = browsing_context(parent)

    actions =
      cond do
        element && element.bidi_shared_id && (x_offset || y_offset) ->
          Commands.pointer_move_to_element_actions(
            element.bidi_shared_id,
            x_offset || 0,
            y_offset || 0
          )

        element && element.bidi_shared_id ->
          Commands.pointer_move_actions(element.bidi_shared_id)

        x_offset || y_offset ->
          Commands.pointer_move_by_actions(x_offset || 0, y_offset || 0)

        true ->
          Commands.pointer_move_by_actions(0, 0)
      end

    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(parent, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def double_click(parent) do
    context = browsing_context(parent)
    actions = Commands.pointer_double_click_actions()
    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(parent, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def button_down(parent, button) do
    context = browsing_context(parent)
    actions = Commands.pointer_button_down_actions(button)
    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(parent, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def button_up(parent, button) do
    context = browsing_context(parent)
    actions = Commands.pointer_button_up_actions(button)
    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(parent, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  # Touch actions

  def touch_down(session, element, x_or_offset \\ 0, y_or_offset \\ 0) do
    context = browsing_context(session)

    {x, y} =
      if element && element.bidi_shared_id do
        case element_location(element) do
          {:ok, {ex, ey}} -> {ex + x_or_offset, ey + y_or_offset}
          _ -> {x_or_offset, y_or_offset}
        end
      else
        {x_or_offset, y_or_offset}
      end

    actions = Commands.touch_down_actions(round(x), round(y))
    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def touch_up(session) do
    context = browsing_context(session)
    actions = Commands.touch_up_actions()
    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def tap(%Element{bidi_shared_id: shared_id} = element) when not is_nil(shared_id) do
    context = browsing_context(element)
    actions = Commands.touch_tap_element_actions(shared_id)
    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(element, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def tap(%Element{} = _element), do: {:error, :no_bidi_shared_id}

  def touch_move(parent, x, y) do
    context = browsing_context(parent)
    actions = Commands.touch_move_actions(x, y)
    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(parent, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def touch_scroll(%Element{bidi_shared_id: shared_id} = element, x_offset, y_offset)
      when not is_nil(shared_id) do
    context = browsing_context(element)
    actions = Commands.touch_scroll_element_actions(shared_id, x_offset, y_offset)
    {method, params} = Commands.perform_actions(context, actions)

    case send_bidi(element, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def touch_scroll(%Element{} = _element, _x, _y), do: {:error, :no_bidi_shared_id}

  # Dialog handling

  def accept_alert(session, fun) do
    handle_dialog(session, fun, true)
  end

  def dismiss_alert(session, fun) do
    handle_dialog(session, fun, true)
  end

  def accept_confirm(session, fun) do
    handle_dialog(session, fun, true)
  end

  def dismiss_confirm(session, fun) do
    handle_dialog(session, fun, false)
  end

  def accept_prompt(session, nil, fun) do
    handle_dialog(session, fun, true)
  end

  def accept_prompt(session, input, fun) when is_binary(input) do
    handle_dialog(session, fun, true, input)
  end

  def dismiss_prompt(session, fun) do
    handle_dialog(session, fun, false)
  end

  defp handle_dialog(session, fun, accept, user_text \\ nil) do
    pid = bidi_pid(session)
    context = browsing_context(session)

    # Subscribe to prompt events
    WebSocketClient.subscribe(pid, "browsingContext.userPromptOpened")

    # Execute the function that triggers the dialog
    fun.(session)

    # Wait for the prompt event
    message =
      receive do
        {:bidi_event, "browsingContext.userPromptOpened", event} ->
          get_in(event, ["params", "message"]) || ""
      after
        5_000 -> ""
      end

    # Handle the prompt
    {method, params} = Commands.handle_user_prompt(context, accept, user_text)
    send_bidi(session, method, params)

    message
  end

  # Settle — wait for the page to be idle after an action.
  #
  # Two signals:
  # 1. Network: no new HTTP requests for `idle_time` ms
  # 2. LiveView: no phx-*-loading attributes on any element
  #
  # Works correctly with persistent connections (WebSockets, SSE)
  # since those don't fire new request events.

  @liveview_settled_js """
  (() => {
    const loading = document.querySelector('[data-phx-main-loading], [class*="phx-"][class*="-loading"]');
    const connected = document.querySelector('[data-phx-main]');
    if (!connected) return true;
    return !loading;
  })()
  """

  def settle(session, timeout, idle_time) do
    pid = bidi_pid(session)

    {method, params} = Commands.subscribe(["network.beforeRequestSent"])
    WebSocketClient.send_command(pid, method, params)
    WebSocketClient.subscribe(pid, "network.beforeRequestSent")

    deadline = System.monotonic_time(:millisecond) + timeout
    do_settle(session, idle_time, deadline)
  end

  defp do_settle(session, idle_time, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      raise RuntimeError, "Timed out waiting for page to settle"
    end

    wait_ms = min(idle_time, remaining)

    receive do
      {:bidi_event, "network.beforeRequestSent", _event} ->
        do_settle(session, idle_time, deadline)
    after
      wait_ms ->
        # Network is quiet — check if LiveView is also settled
        if liveview_settled?(session) do
          :ok
        else
          do_settle(session, idle_time, deadline)
        end
    end
  end

  defp liveview_settled?(session) do
    context = browsing_context(session)
    {method, params} = Commands.evaluate(context, @liveview_settled_js)

    case send_bidi(session, method, params) do
      {:ok, result} ->
        case ResponseParser.extract_value(result) do
          {:ok, true} -> true
          _ -> false
        end

      _ ->
        # If we can't check, assume settled
        true
    end
  end

  # Console event listener

  def on_console(session, callback) do
    pid = bidi_pid(session)

    # Subscribe to log events at the BiDi protocol level (idempotent)
    {method, params} = Commands.subscribe(["log.entryAdded"])
    WebSocketClient.send_command(pid, method, params)

    # Spawn a listener process that subscribes itself and calls the callback
    caller = self()

    spawn_link(fn ->
      # Subscribe this spawned process to receive log events
      WebSocketClient.subscribe(pid, "log.entryAdded")
      console_listener_loop(caller, callback)
    end)

    :ok
  end

  defp console_listener_loop(caller, callback) do
    # Monitor the caller so we stop when the test process exits
    ref = Process.monitor(caller)
    do_console_listener_loop(ref, callback)
  end

  defp do_console_listener_loop(ref, callback) do
    receive do
      {:bidi_event, "log.entryAdded", event} ->
        params = event["params"] || %{}
        level = params["level"] || "info"
        text = params["text"] || ""
        callback.(level, text)
        do_console_listener_loop(ref, callback)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    end
  end

  # Request interception

  def intercept_request(session, url_pattern, response) do
    pid = bidi_pid(session)

    # Subscribe to network events at the BiDi protocol level
    {sub_method, sub_params} = Commands.subscribe(["network.beforeRequestSent"])
    WebSocketClient.send_command(pid, sub_method, sub_params)

    # Add the intercept
    {method, params} = Commands.add_intercept(url_pattern)

    case send_bidi(session, method, params) do
      {:ok, _result} ->
        # Spawn a handler process that subscribes itself and handles intercepted requests
        caller = self()

        spawn_link(fn ->
          WebSocketClient.subscribe(pid, "network.beforeRequestSent")
          intercept_handler_loop(caller, session, response)
        end)

        :ok

      error ->
        error
    end
  end

  defp intercept_handler_loop(caller, session, response) do
    ref = Process.monitor(caller)
    do_intercept_handler_loop(ref, session, response)
  end

  defp do_intercept_handler_loop(ref, session, response) do
    receive do
      {:bidi_event, "network.beforeRequestSent", event} ->
        request_id = get_in(event, ["params", "request"])
        is_blocked = get_in(event, ["params", "isBlocked"])

        if request_id && is_blocked do
          response_map =
            if is_function(response, 1) do
              response.(event)
            else
              response
            end

          {method, params} =
            Commands.provide_response(request_id, %{
              status: response_map[:status] || 200,
              headers: response_map[:headers] || [],
              body: response_map[:body]
            })

          send_bidi(session, method, params)
        end

        do_intercept_handler_loop(ref, session, response)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    end
  end

  # Log collection via BiDi events

  def log(session) do
    pid = bidi_pid(session)

    # Subscribe to log events (idempotent)
    {method, params} = Commands.subscribe(["log.entryAdded"])
    WebSocketClient.send_command(pid, method, params)
    WebSocketClient.subscribe(pid, "log.entryAdded")

    # Drain any buffered log events
    logs = drain_log_events()

    {:ok, logs}
  end

  defp drain_log_events do
    receive do
      {:bidi_event, "log.entryAdded", event} ->
        case translate_log_entry(event) do
          :skip -> drain_log_events()
          entry -> [entry | drain_log_events()]
        end
    after
      0 -> []
    end
  end

  # Filter out chromedriver internal messages (BiDi mapper noise)
  @internal_log_patterns ["Launching Mapper instance"]

  defp translate_log_entry(event) do
    params = event["params"] || %{}
    text = params["text"] || ""

    if Enum.any?(@internal_log_patterns, &String.contains?(text, &1)) do
      :skip
    else
      do_translate_log_entry(params, text)
    end
  end

  defp do_translate_log_entry(params, text) do
    level =
      case params["level"] do
        "error" -> "SEVERE"
        "warning" -> "WARNING"
        "info" -> "INFO"
        "debug" -> "DEBUG"
        other -> other || "INFO"
      end

    source =
      case params["type"] do
        "javascript" -> "javascript"
        "console" -> "console-api"
        other -> other || "other"
      end

    source_info = params["source"] || %{}
    url = source_info["url"] || ""
    line = params["lineNumber"] || 0
    column = params["columnNumber"] || 0

    message =
      if url != "" do
        "#{url} #{line}:#{column} #{text}"
      else
        "unknown 0:0 #{text}"
      end

    %{
      "level" => level,
      "source" => source,
      "message" => message
    }
  end
end
