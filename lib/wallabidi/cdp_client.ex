defmodule Wallabidi.CDPClient do
  @moduledoc false

  alias Wallabidi.BiDi.WebSocketClient
  alias Wallabidi.CDP.{Commands, ResponseParser}
  alias Wallabidi.{Element, Session}

  # XPath polyfill for browsers without native XPath support (e.g. Lightpanda)
  # JS function to extract visible text, simulating innerText behavior
  # for browsers without a rendering engine (e.g. Lightpanda)
  @extract_text_js """
  function() {
    var blocks = ['DIV','P','H1','H2','H3','H4','H5','H6','LI','TR','BR',
                  'SECTION','ARTICLE','HEADER','FOOTER','NAV','MAIN','UL','OL','DL',
                  'BLOCKQUOTE','PRE','TABLE','THEAD','TBODY','TFOOT','FORM','FIELDSET','HR'];
    function walk(node) {
      if (node.nodeType === 3) return node.nodeValue.replace(/\\s+/g, ' ');
      if (node.nodeType !== 1) return '';
      if (node.tagName === 'BR') return '\\n';
      var parts = [];
      for (var i = 0; i < node.childNodes.length; i++) {
        parts.push(walk(node.childNodes[i]));
      }
      var text = parts.join('');
      if (blocks.indexOf(node.tagName) >= 0) text = '\\n' + text + '\\n';
      return text;
    }
    var result = walk(this);
    return result.split('\\n').map(function(l) { return l.trim(); }).filter(Boolean).join('\\n');
  }
  """

  @xpath_polyfill_path Path.join(:code.priv_dir(:wallabidi), "cdp/wgxpath.install.js")
  @external_resource @xpath_polyfill_path
  @xpath_polyfill if File.exists?(@xpath_polyfill_path),
                    do: File.read!(@xpath_polyfill_path) <> "\nwgxpath.install(window);",
                    else: ""

  # --- Connection ---

  def connect(ws_url) do
    WebSocketClient.start_link(ws_url)
  end

  def close(session) do
    WebSocketClient.close(bidi_pid(session))
  end

  # --- Session bootstrap ---

  def create_session(pid) do
    with {:ok, %{"targetId" => target_id}} <- send_cdp(pid, Commands.create_target()),
         {:ok, %{"sessionId" => session_id}} <-
           send_cdp(pid, Commands.attach_to_target(target_id)) do
      # Enable required domains using raw pid + sessionId
      send_cdp_with_session(pid, session_id, Commands.enable_page())
      send_cdp_with_session(pid, session_id, Commands.enable_runtime())
      send_cdp_with_session(pid, session_id, Commands.enable_dom())

      {:ok, %{target_id: target_id, session_id: session_id}}
    end
  end

  def close_session(session) do
    pid = bidi_pid(session)
    target_id = get_in(session.capabilities, [:target_id]) || session.id

    send_cdp(pid, Commands.close_target(target_id))
    :ok
  rescue
    _ -> :ok
  end

  # --- Navigation ---

  def visit(session, url) do
    {method, params} = Commands.navigate(url)

    case send_cdp_session(session, method, params) do
      {:ok, result} ->
        case ResponseParser.check_navigate({:ok, result}) do
          :ok ->
            inject_xpath_polyfill(session)
            :ok

          error ->
            error
        end

      error ->
        error
    end
  end

  def current_url(session) do
    evaluate_value(session, "window.location.href")
  end

  # --- Element finding ---

  def find_elements(parent, {:css, selector}) do
    find_elements_js(parent, """
    Array.from(document.querySelectorAll(#{Jason.encode!(selector)}))
    """)
  end

  def find_elements(parent, {:xpath, xpath}) do
    find_elements_js(parent, """
    (() => {
      const result = document.evaluate(#{Jason.encode!(xpath)}, document, null,
        XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      const nodes = [];
      for (let i = 0; i < result.snapshotLength; i++) nodes.push(result.snapshotItem(i));
      return nodes;
    })()
    """)
  end

  def find_elements(%Element{bidi_shared_id: parent_id} = parent, {:css, selector})
      when not is_nil(parent_id) do
    # Lightpanda's querySelectorAll on elements doesn't scope to descendants.
    # Workaround: use :scope pseudo-class to force scoping.
    find_elements_on(
      parent,
      parent_id,
      "function(s) { return Array.from(this.querySelectorAll(':scope ' + s)); }",
      [selector]
    )
  end

  def find_elements(%Element{bidi_shared_id: parent_id} = parent, {:xpath, xpath})
      when not is_nil(parent_id) do
    find_elements_on(
      parent,
      parent_id,
      """
      function(expr) {
        const result = document.evaluate(expr, this, null,
          XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
        const nodes = [];
        for (let i = 0; i < result.snapshotLength; i++) nodes.push(result.snapshotItem(i));
        return nodes;
      }
      """,
      [xpath]
    )
  end

  defp find_elements_js(parent, js) do
    session = root_session(parent)
    {method, params} = Commands.evaluate(js, return_by_value: false)

    with {:ok, result} <- send_cdp_session(session, method, params),
         {:ok, array_id} <- ResponseParser.extract_object_id({:ok, result}),
         {:ok, result} <- send_cdp_raw(session, Commands.get_properties(array_id)),
         {:ok, ids} <- ResponseParser.extract_element_ids({:ok, result}) do
      # Release the array object
      if array_id, do: send_cdp_raw(session, Commands.release_object(array_id))

      elements =
        Enum.map(ids, fn object_id ->
          %Element{
            bidi_shared_id: object_id,
            parent: parent,
            driver: session.driver,
            url: session.session_url
          }
        end)

      {:ok, elements}
    end
  end

  defp find_elements_on(parent, parent_id, function, args) do
    session = root_session(parent)
    {method, params} = Commands.call_function_on(parent_id, function, args)

    with {:ok, result} <- send_cdp_session(session, method, params),
         {:ok, array_id} <- ResponseParser.extract_object_id({:ok, result}),
         {:ok, result} <- send_cdp_raw(session, Commands.get_properties(array_id)),
         {:ok, ids} <- ResponseParser.extract_element_ids({:ok, result}) do
      if array_id, do: send_cdp_raw(session, Commands.release_object(array_id))

      elements =
        Enum.map(ids, fn object_id ->
          %Element{
            bidi_shared_id: object_id,
            parent: parent,
            driver: session.driver,
            url: session.session_url
          }
        end)

      {:ok, elements}
    end
  end

  # --- Element interaction ---

  def click(%Element{bidi_shared_id: object_id} = element) when not is_nil(object_id) do
    session = root_session(element)

    {method, params} =
      Commands.call_function_on_value(object_id, """
      function() {
        if (this.tagName === 'OPTION') {
          var select = this.closest('select');
          if (select && !select.multiple) {
            select.value = this.value;
            Array.from(select.options).forEach(function(o) { o.selected = (o === this); }.bind(this));
          } else {
            this.selected = !this.selected;
          }
          if (select) select.dispatchEvent(new Event('change', { bubbles: true }));
          return;
        }
        // Handle form reset buttons — polyfill form.reset() for Lightpanda
        var form = this.closest('form');
        if (form && (this.type === 'reset' || (this.tagName === 'BUTTON' && this.type === 'reset'))) {
          Array.from(form.elements).forEach(function(el) {
            if (el.type === 'checkbox' || el.type === 'radio') {
              el.checked = el.defaultChecked;
            } else if (el.tagName === 'SELECT') {
              Array.from(el.options).forEach(function(o) { o.selected = o.defaultSelected; });
            } else if ('defaultValue' in el) {
              el.value = el.defaultValue;
            }
          });
          form.dispatchEvent(new Event('reset', { bubbles: true }));
          return;
        }
        // Handle form submit — only explicit submit/image inputs
        if (form && this.tagName === 'INPUT' &&
            (this.type === 'submit' || this.type === 'image')) {
          this.focus();
          this.click();
          return;
        }
        this.focus();
        this.click();
      }
      """)

    case send_cdp_session(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def text(%Element{bidi_shared_id: object_id} = element) when not is_nil(object_id) do
    session = root_session(element)

    # Use innerText if available (Chrome), fall back to a DOM-walking
    # text extractor that inserts newlines between block elements
    # (Lightpanda has no innerText since it has no rendering engine)
    {method, params} =
      Commands.call_function_on_value(object_id, @extract_text_js)

    case send_cdp_session(session, method, params) do
      {:ok, result} -> ResponseParser.extract_value({:ok, result})
      error -> error
    end
  end

  def attribute(%Element{bidi_shared_id: object_id} = element, name)
      when not is_nil(object_id) do
    session = root_session(element)

    # For "value", read the DOM property (current value) not the HTML attribute
    # (initial value). Same for "checked" and "selected".
    {method, params} =
      Commands.call_function_on_value(
        object_id,
        """
        function(name) {
          if (name === 'value' && 'value' in this) return this.value;
          if (name === 'checked') return this.checked ? 'true' : null;
          if (name === 'selected') return this.selected ? 'true' : null;
          return this.getAttribute(name);
        }
          
        """,
        [name]
      )

    case send_cdp_session(session, method, params) do
      {:ok, result} -> ResponseParser.extract_value({:ok, result})
      error -> error
    end
  end

  def displayed(%Element{bidi_shared_id: object_id} = element) when not is_nil(object_id) do
    session = root_session(element)

    {method, params} =
      Commands.call_function_on_value(object_id, """
      function() {
        var never = ['TITLE','HEAD','META','LINK','SCRIPT','STYLE','NOSCRIPT'];
        if (never.indexOf(this.tagName) >= 0) return false;
        if (!document.body || !document.body.contains(this)) return false;
        var style = window.getComputedStyle(this);
        if (style.display === 'none' || style.visibility === 'hidden') return false;
        return true;
      }
      """)

    case send_cdp_session(session, method, params) do
      {:ok, result} -> ResponseParser.extract_value({:ok, result})
      error -> error
    end
  end

  def selected(%Element{bidi_shared_id: object_id} = element) when not is_nil(object_id) do
    session = root_session(element)

    {method, params} =
      Commands.call_function_on_value(
        object_id,
        "function() { return this.selected || this.checked || false; }"
      )

    case send_cdp_session(session, method, params) do
      {:ok, result} -> ResponseParser.extract_value({:ok, result})
      error -> error
    end
  end

  def set_value(%Element{bidi_shared_id: object_id} = element, value)
      when not is_nil(object_id) do
    session = root_session(element)

    {method, params} =
      Commands.call_function_on_value(
        object_id,
        """
        function(value) {
          this.focus();
          this.value = '';
          this.value = value;
          this.dispatchEvent(new Event('input', { bubbles: true }));
          this.dispatchEvent(new Event('change', { bubbles: true }));
        }
        """,
        [value]
      )

    case send_cdp_session(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  def clear(%Element{bidi_shared_id: object_id} = element) when not is_nil(object_id) do
    session = root_session(element)

    {method, params} =
      Commands.call_function_on_value(object_id, """
      function() {
        this.focus();
        this.value = '';
        this.dispatchEvent(new Event('input', { bubbles: true }));
        this.dispatchEvent(new Event('change', { bubbles: true }));
      }
      """)

    case send_cdp_session(session, method, params) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  # --- Page content ---

  def page_source(session) do
    evaluate_value(session, "document.documentElement.outerHTML")
  end

  def page_title(session) do
    evaluate_value(session, "document.title")
  end

  # --- JavaScript execution ---

  def execute_script(session, script, args) do
    wrapped = wrap_script(script, args)
    evaluate_value(session, wrapped)
  end

  def execute_script_async(session, script, args) do
    wrapped = wrap_async_script(script, args)
    {method, params} = Commands.evaluate(wrapped, await_promise: true)

    case send_cdp_session(session, method, params) do
      {:ok, result} -> ResponseParser.extract_value({:ok, result})
      error -> error
    end
  end

  # --- Send keys ---

  def send_keys(%Session{} = session, keys) when is_list(keys) do
    Enum.each(keys, fn
      key when is_atom(key) ->
        {code, key_val} = key_mapping(key)
        send_key_event(session, code, key_val)

      text when is_binary(text) ->
        for char <- String.graphemes(text) do
          send_cdp_session(session, "Input.dispatchKeyEvent", %{type: "keyDown", text: char})
          send_cdp_session(session, "Input.dispatchKeyEvent", %{type: "keyUp", text: char})
        end
    end)

    {:ok, nil}
  end

  def send_keys(%Element{bidi_shared_id: object_id} = element, keys)
      when not is_nil(object_id) and is_list(keys) do
    session = root_session(element)

    # Lightpanda's Input.dispatchKeyEvent doesn't insert text into inputs.
    # Use a JS-based approach: focus, then set value char by char with events.
    text = keys |> Enum.filter(&is_binary/1) |> Enum.join()

    {method, params} =
      Commands.call_function_on_value(
        object_id,
        """
        function(text) {
          this.focus();
          this.value = (this.value || '') + text;
          this.dispatchEvent(new Event('input', { bubbles: true }));
          this.dispatchEvent(new Event('change', { bubbles: true }));
        }
        """,
        [text]
      )

    send_cdp_session(session, method, params)
    {:ok, nil}
  end

  defp send_key_event(session, code, key_val) do
    send_cdp_session(session, "Input.dispatchKeyEvent", %{
      type: "rawKeyDown",
      key: key_val,
      code: code,
      windowsVirtualKeyCode: key_code(code)
    })

    send_cdp_session(session, "Input.dispatchKeyEvent", %{
      type: "keyUp",
      key: key_val,
      code: code,
      windowsVirtualKeyCode: key_code(code)
    })
  end

  # --- Cookies ---

  def cookies(session) do
    {method, params} = Commands.get_cookies()

    case send_cdp_session(session, method, params) do
      {:ok, %{"cookies" => cookies}} -> {:ok, cookies}
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  def set_cookie(session, name, value, attributes \\ []) do
    domain = Keyword.get(attributes, :domain)
    path = Keyword.get(attributes, :path, "/")

    domain =
      domain ||
        case current_url(session) do
          {:ok, url} -> URI.parse(url).host
          _ -> nil
        end

    {method, params} = Commands.set_cookie(name, value, domain: domain, path: path)

    case send_cdp_session(session, method, params) do
      {:ok, %{"success" => true}} -> {:ok, []}
      {:ok, _} -> {:error, :invalid_cookie_domain}
      error -> error
    end
  end

  # --- Window ---

  def get_window_size(session) do
    # Check if we've set a custom size (stored via JS on the session's page)
    case evaluate_value(
           session,
           "JSON.stringify(window.__wallabidi_window_size || {width: window.innerWidth, height: window.innerHeight})"
         ) do
      {:ok, json} when is_binary(json) -> {:ok, Jason.decode!(json)}
      other -> other
    end
  end

  def set_window_size(session, width, height) do
    {method, params} = Commands.set_device_metrics(width, height)
    send_cdp_session(session, method, params)

    # Also store in JS as fallback (Lightpanda doesn't implement emulation)
    evaluate_value(
      session,
      "window.__wallabidi_window_size = {width: #{width}, height: #{height}}"
    )

    {:ok, nil}
  end

  # --- Screenshots ---

  def take_screenshot(session) do
    {method, params} = Commands.capture_screenshot()

    case send_cdp_session(session, method, params) do
      {:ok, %{"data" => data}} -> Base.decode64(data)
      error -> error
    end
  end

  # --- Helpers ---

  defp evaluate_value(session, expression) do
    {method, params} = Commands.evaluate(expression)

    case send_cdp_session(session, method, params) do
      {:ok, result} -> ResponseParser.extract_value({:ok, result})
      error -> error
    end
  end

  defp send_cdp(pid, {method, params}) when is_pid(pid) do
    WebSocketClient.send_command(pid, method, params)
    |> ResponseParser.check_error()
  end

  # Bootstrap: send CDP command with raw pid + sessionId (before Session struct exists)
  defp send_cdp_with_session(pid, session_id, {method, params}) when is_pid(pid) do
    params = Map.put(params, :sessionId, session_id)

    WebSocketClient.send_command(pid, method, params)
    |> ResponseParser.check_error()
  end

  defp send_cdp_session(%Session{} = session, method, params) do
    pid = bidi_pid(session)
    session_id = session.browsing_context
    params = Map.put(params, :sessionId, session_id)

    WebSocketClient.send_command(pid, method, params)
    |> ResponseParser.check_error()
  end

  defp send_cdp_raw(%Session{} = session, {method, params}) do
    pid = bidi_pid(session)
    session_id = session.browsing_context
    params = Map.put(params, :sessionId, session_id)

    WebSocketClient.send_command(pid, method, params)
  end

  defp bidi_pid(%Session{bidi_pid: pid}), do: pid
  defp bidi_pid(%Element{parent: parent}), do: bidi_pid(parent)

  defp root_session(%Session{} = s), do: s
  defp root_session(%Element{parent: p}), do: root_session(p)

  defp wrap_script(script, args) do
    encoded_args = Jason.encode!(args)
    "(function() { var arguments = #{encoded_args}; #{script} })()"
  end

  defp wrap_async_script(script, args) do
    encoded_args = Jason.encode!(args)

    """
    new Promise((resolve) => {
      var arguments = [...#{encoded_args}, resolve];
      #{script}
    })
    """
  end

  defp key_mapping(:enter), do: {"Enter", "Enter"}
  defp key_mapping(:tab), do: {"Tab", "Tab"}
  defp key_mapping(:escape), do: {"Escape", "Escape"}
  defp key_mapping(:backspace), do: {"Backspace", "Backspace"}
  defp key_mapping(:delete), do: {"Delete", "Delete"}
  defp key_mapping(:arrow_up), do: {"ArrowUp", "ArrowUp"}
  defp key_mapping(:arrow_down), do: {"ArrowDown", "ArrowDown"}
  defp key_mapping(:arrow_left), do: {"ArrowLeft", "ArrowLeft"}
  defp key_mapping(:arrow_right), do: {"ArrowRight", "ArrowRight"}
  defp key_mapping(:home), do: {"Home", "Home"}
  defp key_mapping(:end_key), do: {"End", "End"}
  defp key_mapping(:space), do: {"Space", " "}
  defp key_mapping(other), do: {to_string(other), to_string(other)}

  defp key_code("Enter"), do: 13
  defp key_code("Tab"), do: 9
  defp key_code("Escape"), do: 27
  defp key_code("Backspace"), do: 8
  defp key_code("Delete"), do: 46
  defp key_code("ArrowUp"), do: 38
  defp key_code("ArrowDown"), do: 40
  defp key_code("ArrowLeft"), do: 37
  defp key_code("ArrowRight"), do: 39
  defp key_code("Space"), do: 32
  defp key_code(_), do: 0

  # Inject XPath polyfill for browsers without native XPath (e.g. Lightpanda)
  defp inject_xpath_polyfill(session) do
    if @xpath_polyfill != "" do
      {method, params} = Commands.evaluate(@xpath_polyfill, return_by_value: true)
      send_cdp_session(session, method, params)
    end

    :ok
  end
end
