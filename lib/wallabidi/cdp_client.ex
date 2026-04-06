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
    # Detach from test process so the WebSocket survives into on_exit cleanup.
    case WebSocketClient.start_link(ws_url) do
      {:ok, pid} = result ->
        Wallabidi.Driver.SessionLifecycle.detach(pid)
        result

      error ->
        error
    end
  end

  # --- Session bootstrap ---

  def create_session(pid, opts \\ []) do
    flat = Keyword.get(opts, :flat_session_id, false)
    browser_context_id = Keyword.get(opts, :browser_context_id)

    create_target_opts =
      if browser_context_id,
        do: [browser_context_id: browser_context_id],
        else: []

    with {:ok, %{"targetId" => target_id}} <-
           send_cdp(pid, Commands.create_target("", create_target_opts)),
         {:ok, %{"sessionId" => session_id}} <-
           send_cdp(pid, Commands.attach_to_target(target_id)) do
      # Fire-and-forget: enables don't need ack. Chrome processes them in
      # order on the session, so by the time the first real command (e.g.
      # Page.navigate) gets a response, all enables have been processed.
      cast_cdp_with_session(pid, session_id, Commands.enable_page(), flat_session_id: flat)
      cast_cdp_with_session(pid, session_id, Commands.enable_runtime(), flat_session_id: flat)
      cast_cdp_with_session(pid, session_id, Commands.enable_dom(), flat_session_id: flat)
      cast_cdp_with_session(pid, session_id, Commands.set_lifecycle_events_enabled(true), flat_session_id: flat)

      {:ok, %{target_id: target_id, session_id: session_id}}
    end
  end

  @doc "Create an isolated browser context (like incognito)."
  def create_browser_context(pid) do
    send_cdp(pid, Commands.create_browser_context())
  end

  @doc "Dispose of a browser context and all its targets."
  def dispose_browser_context(pid, browser_context_id) do
    send_cdp(pid, Commands.dispose_browser_context(browser_context_id))
  end

  def close_session(session) do
    pid = bidi_pid(session)
    target_id = get_in(session.capabilities, [:target_id]) || session.id

    # If we have a browser context, disposing it closes the target too
    if browser_context_id = get_in(session.capabilities, [:browser_context_id]) do
      send_cdp(pid, Commands.dispose_browser_context(browser_context_id))
    else
      send_cdp(pid, Commands.close_target(target_id))
    end

    :ok
  end

  # --- Navigation ---

  def visit(session, url) do
    {method, params} = Commands.navigate(url)

    case send_cdp_session(session, method, params) do
      {:ok, %{"loaderId" => loader_id} = result} ->
        with :ok <- ResponseParser.check_navigate({:ok, result}),
             :ok <- Wallabidi.SessionProcess.await_page_load(session, loader_id, "load") do
          # Only inject the xpath polyfill on browsers that lack native
          # document.evaluate support. Chrome has it natively; Lightpanda
          # (flagged via :needs_xpath_polyfill) doesn't.
          if session.capabilities[:needs_xpath_polyfill] do
            inject_xpath_polyfill(session)
          end

          :ok
        end

      {:ok, %{} = result} ->
        # Page.navigate without a loaderId — same-document navigations and
        # some cached redirects. There's no new load cycle to wait for.
        case ResponseParser.check_navigate({:ok, result}) do
          :ok ->
            if session.capabilities[:needs_xpath_polyfill] do
              inject_xpath_polyfill(session)
            end

            :ok

          error ->
            error
        end

      error ->
        error
    end
  end

  defp inject_xpath_polyfill(session) do
    {method, params} = Commands.evaluate(@xpath_polyfill, return_by_value: true)
    send_cdp_session(session, method, params)
    :ok
  end

  def current_url(session) do
    evaluate_value(session, "window.location.href")
  end

  # --- Element finding ---

  # Element-scoped queries — find within a parent element
  def find_elements(%Element{bidi_shared_id: parent_id} = parent, {:css, selector})
      when not is_nil(parent_id) do
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

  # Document-level queries — find from root (Session or Element without object ID)
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

  defp find_elements_js(parent, js) do
    session = root_session(parent)
    # Wrap the JS to return elements as an array, then use getProperties
    # to extract individual objectIds. TODO: collapse into single RPC.
    {method, params} = Commands.evaluate(js, return_by_value: false)

    with {:ok, result} <- send_cdp_session(session, method, params),
         {:ok, array_id} <- ResponseParser.extract_object_id({:ok, result}),
         {:ok, result} <- send_cdp_raw(session, Commands.get_properties(array_id)),
         {:ok, ids} <- ResponseParser.extract_element_ids({:ok, result}) do
      if array_id, do: cast_release(session, array_id)

      elements =
        Enum.map(ids, fn object_id ->
          %Element{
            id: object_id,
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
      if array_id, do: cast_release(session, array_id)

      elements =
        Enum.map(ids, fn object_id ->
          %Element{
            id: object_id,
            bidi_shared_id: object_id,
            parent: parent,
            driver: session.driver,
            url: session.session_url
          }
        end)

      {:ok, elements}
    end
  end

  @doc """
  Execute a Pipeline — compiles to JS, runs via evaluate or callFunctionOn,
  extracts element objectIds via getProperties. 2 RPCs total.

  If the pipeline includes a `classify` step, the classification string
  is extracted from the array's `__classify` property and returned as
  `{:ok, elements, classification}`. Otherwise returns `{:ok, elements}`.
  """
  def find_elements_pipeline(parent, %Wallabidi.CDP.Pipeline{} = pipeline) do
    {js, _parent_id, mode} = Wallabidi.CDP.Pipeline.to_js(pipeline)
    session = root_session(parent)

    case mode do
      :count ->
        # Click pipeline: returns {count: N} by value (1 RPC, no getProperties).
        # The click already happened inside the JS — we just need the count.
        result =
          if pipeline.parent_id do
            {method, params} = Commands.call_function_on_value(pipeline.parent_id, js, [])
            send_cdp_session(session, method, params)
          else
            {method, params} = Commands.evaluate(js, return_by_value: true)
            send_cdp_session(session, method, params)
          end

        with {:ok, raw} <- result,
             {:ok, value} <- ResponseParser.extract_value({:ok, raw}) do
          count = if is_map(value), do: value["count"] || 0, else: 0
          # Return synthetic elements list of the right length for validate_count
          elements = List.duplicate(%Element{parent: parent, driver: session.driver}, count)
          {:ok, elements}
        end

      :elements ->
        # Find pipeline: returns array of live node refs (2 RPCs).
        has_classify = Enum.any?(pipeline.ops, &match?({:classify, _}, &1))

        result =
          if pipeline.parent_id do
            {method, params} = Commands.call_function_on(pipeline.parent_id, js, [])

            with {:ok, result} <- send_cdp_session(session, method, params),
                 {:ok, array_id} <- ResponseParser.extract_object_id({:ok, result}),
                 {:ok, result} <- send_cdp_raw(session, Commands.get_properties(array_id)) do
              if array_id, do: cast_release(session, array_id)
              {:ok, result}
            end
          else
            {method, params} = Commands.evaluate(js, return_by_value: false)

            with {:ok, result} <- send_cdp_session(session, method, params),
                 {:ok, array_id} <- ResponseParser.extract_object_id({:ok, result}),
                 {:ok, result} <- send_cdp_raw(session, Commands.get_properties(array_id)) do
              if array_id, do: cast_release(session, array_id)
              {:ok, result}
            end
          end

        with {:ok, props_result} <- result,
             {:ok, ids} <- ResponseParser.extract_element_ids({:ok, props_result}) do
          elements =
            Enum.map(ids, fn object_id ->
              %Element{
                id: object_id,
                bidi_shared_id: object_id,
                parent: parent,
                driver: session.driver,
                url: session.session_url
              }
            end)

          if has_classify do
            classification = extract_classify(props_result)
            {:ok, elements, classification}
          else
            {:ok, elements}
          end
        end
    end
  end

  defp extract_classify(%{"result" => properties}) when is_list(properties) do
    case Enum.find(properties, &(&1["name"] == "__classify")) do
      %{"value" => %{"value" => val}} when is_binary(val) -> val
      _ -> "none"
    end
  end

  defp extract_classify(_), do: "none"

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
    # (initial value). Same for "checked" and "selected". Throw for stale refs.
    {method, params} =
      Commands.call_function_on_value(
        object_id,
        """
        function(name) {
          var doc = this.ownerDocument;
          if (!doc || !doc.body || !doc.body.contains(this)) throw new Error('stale element reference');
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

    # Visibility check. We deliberately avoid `Element.checkVisibility`
    # (W3C CSS4) because it returns false negatives under parallel load
    # in headless Chrome when layout hasn't been computed yet — we saw
    # hundreds of spurious `displayed: false` verdicts for plain <div>s
    # that were perfectly visible. Stick to the older, layout-forcing APIs
    # (`getComputedStyle` + `getBoundingClientRect`) which are stable.
    #
    # Wallaby's contract is "visible to the user":
    # - `isConnected` — still in the document tree
    # - own `display`/`visibility` — not explicitly hidden
    # - non-empty rect OR `offsetParent` — actually laid out (catches
    #   ancestor `display:none`, which is what makes the rect collapse)
    # - not scrolled off-top/off-left of the viewport
    {method, params} =
      Commands.call_function_on_value(object_id, """
      function() {
        if (!this.isConnected) return false;
        // OPTION elements inside a (closed) SELECT have no layout, but
        // WebDriver considers them visible so they can be clicked. Check
        // only that an ancestor SELECT isn't hidden.
        if (this.tagName === 'OPTION') {
          var select = this.closest('select');
          if (!select) return true;
          var ss = window.getComputedStyle(select);
          return ss.display !== 'none' && ss.visibility !== 'hidden';
        }
        var style = window.getComputedStyle(this);
        if (style.display === 'none') return false;
        if (style.visibility === 'hidden') return false;
        var rect = this.getBoundingClientRect();
        // Truly unrendered (no layout at all — ancestor display:none
        // collapses everything to 0x0 with no offsetParent).
        if (rect.width === 0 && rect.height === 0 && this.offsetParent === null && style.position !== 'fixed') {
          return false;
        }
        // Scrolled off the top or left of the viewport.
        if (rect.bottom < 0) return false;
        if (rect.right < 0) return false;
        return true;
      }
      """)

    case send_cdp_session(session, method, params) do
      {:ok, result} ->
        case ResponseParser.extract_value({:ok, result}) do
          {:ok, true} -> {:ok, true}
          {:ok, false} -> {:ok, false}
          other -> other
        end

      error ->
        error
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

    # File inputs can't be set via JS — use DOM.setFileInputFiles
    case is_file_input?(session, object_id) do
      true ->
        files =
          (if is_list(value), do: value, else: [value])
          |> Enum.filter(&File.exists?/1)

        send_cdp_session(session, "DOM.setFileInputFiles", %{
          files: files,
          objectId: object_id
        })

        {:ok, nil}

      false ->
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
  end

  defp is_file_input?(session, object_id) do
    {method, params} =
      Commands.call_function_on_value(object_id, "function() { return this.type === 'file'; }")

    case send_cdp_session(session, method, params) do
      {:ok, %{"result" => %{"value" => true}}} -> true
      _ -> false
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
    session = root_session(session)

    # If args contain element references, use callFunctionOn so we can pass
    # them as objectId arguments. Otherwise, use evaluate.
    case encode_script_args(args) do
      {:no_elements, _} ->
        wrapped = wrap_script(script, args)
        evaluate_value(session, wrapped)

      {:ok, cdp_args} ->
        wrapped = """
        function() {
          #{script}
        }
        """

        # callFunctionOn needs an objectId — use globalThis
        {:ok, %{"result" => %{"objectId" => global_id}}} =
          send_cdp_session(session, "Runtime.evaluate", %{
            expression: "globalThis",
            returnByValue: false
          })

        result =
          send_cdp_session(session, "Runtime.callFunctionOn", %{
            objectId: global_id,
            functionDeclaration: wrapped,
            arguments: cdp_args,
            returnByValue: true
          })

        cast_release(session, global_id)

        case result do
          {:ok, res} -> ResponseParser.extract_value({:ok, res})
          error -> error
        end
    end
  end

  def execute_script_async(session, script, args) do
    wrapped = wrap_async_script(script, args)
    {method, params} = Commands.evaluate(wrapped, await_promise: true)

    case send_cdp_session(session, method, params) do
      {:ok, result} -> ResponseParser.extract_value({:ok, result})
      error -> error
    end
  end

  @web_element_identifier "element-6066-11e4-a52e-4f735466cecf"

  defp encode_script_args(args) do
    has_element? =
      Enum.any?(args, fn
        %{@web_element_identifier => _} -> true
        _ -> false
      end)

    if has_element? do
      cdp_args =
        Enum.map(args, fn
          %{@web_element_identifier => id} -> %{objectId: id}
          v when is_binary(v) -> %{value: v}
          v when is_number(v) -> %{value: v}
          v when is_boolean(v) -> %{value: v}
          nil -> %{value: nil}
          v -> %{value: v}
        end)

      {:ok, cdp_args}
    else
      {:no_elements, args}
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

    # Chrome CDP: focus element then dispatch real key events (supports :tab, :enter, etc.)
    # Lightpanda: Input.dispatchKeyEvent is broken, fall back to JS value setting.
    if session.capabilities[:flat_session_id] do
      {method, params} =
        Commands.call_function_on_value(object_id, "function() { this.focus(); }")

      send_cdp_session(session, method, params)
      send_keys(session, keys)
    else
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
      {:ok, %{"cookies" => cookies}} -> {:ok, Enum.map(cookies, &normalize_cookie/1)}
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  defp normalize_cookie(cookie) do
    # CDP uses `expires`, WebDriver uses `expiry`
    case Map.pop(cookie, "expires") do
      {nil, c} -> c
      {-1, c} -> c
      {expires, c} -> Map.put(c, "expiry", trunc(expires))
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

    secure = Keyword.get(attributes, :secure, false)
    http_only = Keyword.get(attributes, :httpOnly, false)
    expiry = Keyword.get(attributes, :expiry)

    {method, params} =
      Commands.set_cookie(name, value,
        domain: domain,
        path: path,
        secure: secure,
        http_only: http_only,
        expiry: expiry
      )

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

  # --- Public command sender (for driver-level features like dialogs) ---

  def send_cdp_command(session, method, params) do
    send_cdp_session(session, method, params)
  end

  # --- User-Agent ---

  def set_user_agent(session, user_agent) do
    {method, params} = Commands.set_user_agent_override(user_agent)

    case send_cdp_session(session, method, params) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # --- Screenshots ---

  def take_screenshot(session_or_element) do
    session = root_session(session_or_element)
    {method, params} = Commands.capture_screenshot()

    case send_cdp_session(session, method, params) do
      {:ok, %{"data" => data}} -> Base.decode64!(data)
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

  # Fire-and-forget: write to WebSocket, don't wait for response.
  defp cast_cdp_with_session(pid, session_id, {method, params}, opts)
       when is_pid(pid) do
    if Keyword.get(opts, :flat_session_id) do
      WebSocketClient.cast_command_flat(pid, method, params, session_id)
    else
      params = Map.put(params, :sessionId, session_id)
      WebSocketClient.cast_command_flat(pid, method, params, session_id)
    end
  end

  @doc false
  def cast_cdp_command(%Session{} = session, method, params) do
    pid = bidi_pid(session)
    session_id = effective_session_id(session)

    if session.capabilities[:flat_session_id] do
      WebSocketClient.cast_command_flat(pid, method, params, session_id)
    else
      params = Map.put(params, :sessionId, session_id)
      WebSocketClient.cast_command_flat(pid, method, params, session_id)
    end
  end

  # Fire-and-forget releaseObject — frees remote references without blocking.
  defp cast_release(%Session{} = session, object_id) do
    pid = bidi_pid(session)
    session_id = effective_session_id(session)

    if session.capabilities[:flat_session_id] do
      WebSocketClient.cast_command_flat(pid, "Runtime.releaseObject", %{objectId: object_id}, session_id)
    else
      WebSocketClient.cast_command_flat(pid, "Runtime.releaseObject", %{objectId: object_id, sessionId: session_id}, session_id)
    end
  end

  defp send_cdp_session(%Session{} = session, method, params) do
    pid = bidi_pid(session)
    session_id = effective_session_id(session)

    if session.capabilities[:flat_session_id] do
      WebSocketClient.send_command_flat(pid, method, params, session_id)
    else
      params = Map.put(params, :sessionId, session_id)
      WebSocketClient.send_command(pid, method, params)
    end
    |> ResponseParser.check_error()
  end

  # Allow drivers to override the active CDP session_id via process dict
  # (used e.g. for window/tab switching in ChromeCDP)
  defp effective_session_id(%Session{} = session) do
    case Process.get({:cdp_current_target, session.id}) do
      {_target_id, sess_id} -> sess_id
      _ -> session.browsing_context
    end
  end

  defp send_cdp_raw(%Session{} = session, {method, params}) do
    pid = bidi_pid(session)
    session_id = effective_session_id(session)

    if session.capabilities[:flat_session_id] do
      WebSocketClient.send_command_flat(pid, method, params, session_id)
    else
      params = Map.put(params, :sessionId, session_id)
      WebSocketClient.send_command(pid, method, params)
    end
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
end
