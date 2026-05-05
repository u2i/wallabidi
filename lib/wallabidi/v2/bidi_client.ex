defmodule Wallabidi.V2.BiDiClient do
  @moduledoc false

  # BiDi-flavored counterpart to V2.CDPClient.
  #
  # Same operation surface (visit, find_elements, click, evaluate,
  # text, attribute, ...) but every wire call goes out as a
  # WebDriver-BiDi command instead of CDP. The Transport.Protocol
  # layer is unchanged — both clients dispatch through the session's
  # actor pid.
  #
  # ## Op-by-op state of this file
  #
  # Step 1 (this branch) is mechanical translation of CDPClient's
  # public surface, BiDi-flavored. Things implemented op-by-op as
  # tests and integration coverage drive them. The orchestration
  # primitives (await_page_load, register_find/await_find_result,
  # bootstrap channel) are reused from V2.Transport.Protocol — they
  # were verified end-to-end in V2.Transport.BiDi phases A/B/C.

  alias Wallabidi.BiDi.Commands
  alias Wallabidi.Bootstrap
  alias Wallabidi.CDP.Ops
  alias Wallabidi.Element
  alias Wallabidi.Session
  alias Wallabidi.V2.Transport.Protocol

  # ----- Navigation -----

  @doc """
  Navigate the session's browsing context to `url`. Returns the
  BiDi `navigation` id (used as the loader correlation key by
  Transport.Protocol.await_page_load/4) and the resolved URL.

  Uses `wait: "none"` so the call returns as soon as the navigation
  is committed. Awaiting load milestones is the caller's job —
  see `visit/3`.
  """
  @spec navigate(Session.t(), String.t()) ::
          {:ok, %{loader_id: String.t() | nil, url: String.t()}} | {:error, term}
  def navigate(%Session{browsing_context: ctx} = session, url) when is_binary(url) do
    case Protocol.cdp_send(
           session,
           "browsingContext.navigate",
           %{"context" => ctx, "url" => url, "wait" => "none"},
           []
         ) do
      {:ok, %{"navigation" => nav, "url" => resolved}} ->
        {:ok, %{loader_id: nav, url: resolved}}

      {:ok, _} = unexpected ->
        {:error, {:unexpected_navigate_response, unexpected}}

      error ->
        error
    end
  end

  @doc """
  Navigate and wait for the page to finish loading.
  """
  @spec visit(Session.t(), String.t(), keyword) :: :ok | {:error, term}
  def visit(%Session{} = session, url, opts \\ []) when is_binary(url) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    with {:ok, %{loader_id: nav}} <- navigate(session, url) do
      cond do
        is_binary(nav) ->
          case Protocol.await_page_load(session, nav, "load", timeout) do
            :ok -> :ok
            :timeout -> {:error, :timeout}
          end

        true ->
          # Same-document or cached navigation — no nav id, no load
          # event to wait on.
          :ok
      end
    end
  end

  # ----- Script evaluation -----

  @doc """
  Evaluate a JS expression in the current browsing context's realm.
  Returns the deserialized value.

  When `args` is empty, treats `expression` as a raw expression
  (BiDi `script.evaluate`). When args are provided OR the
  expression contains a `return`, wraps it in a function and uses
  `script.callFunction` so `return` and `arguments[]` references
  work like the user-facing `execute_script` API expects.
  """
  @spec evaluate(Session.t(), String.t()) :: {:ok, term} | {:error, term}
  def evaluate(%Session{} = session, expression) when is_binary(expression) do
    do_eval_expression(session, expression)
  end

  @spec evaluate(Session.t(), String.t(), list) :: {:ok, term} | {:error, term}
  def evaluate(%Session{} = session, expression, args)
      when is_binary(expression) and is_list(args) do
    if needs_wrap?(expression, args) do
      do_eval_function(session, expression, args)
    else
      do_eval_expression(session, expression)
    end
  end

  defp needs_wrap?(_expr, args) when args != [], do: true

  defp needs_wrap?(expression, []) do
    String.contains?(expression, "return ") or
      String.contains?(expression, "return;") or
      String.contains?(expression, "arguments[")
  end

  defp do_eval_expression(%Session{browsing_context: ctx} = session, expression) do
    params = %{
      "expression" => expression,
      "awaitPromise" => false,
      "target" => %{"context" => ctx}
    }

    case Protocol.cdp_send(session, "script.evaluate", params, []) do
      {:ok, result} -> decode_eval_result(result)
      error -> error
    end
  end

  @doc """
  Evaluate a JS expression and await its returned Promise. Mirrors
  `evaluate/2` for the case where the expression yields a thenable.
  """
  @spec evaluate_async(Session.t(), String.t()) :: {:ok, term} | {:error, term}
  def evaluate_async(%Session{browsing_context: ctx} = session, expression)
      when is_binary(expression) do
    params = %{
      "expression" => expression,
      "awaitPromise" => true,
      "target" => %{"context" => ctx}
    }

    case Protocol.cdp_send(session, "script.evaluate", params, []) do
      {:ok, result} -> decode_eval_result(result)
      error -> error
    end
  end

  defp do_eval_function(%Session{browsing_context: ctx} = session, expression, args) do
    fn_decl = "function() { #{expression} }"

    params = %{
      "functionDeclaration" => fn_decl,
      "arguments" => Enum.map(args, &encode_arg/1),
      "awaitPromise" => false,
      "target" => %{"context" => ctx}
    }

    case Protocol.cdp_send(session, "script.callFunction", params, []) do
      {:ok, result} -> decode_eval_result(result)
      error -> error
    end
  end

  @web_element_identifier "element-6066-11e4-a52e-4f735466cecf"

  defp encode_arg(arg) when is_binary(arg), do: %{"type" => "string", "value" => arg}
  defp encode_arg(arg) when is_integer(arg), do: %{"type" => "number", "value" => arg}
  defp encode_arg(arg) when is_float(arg), do: %{"type" => "number", "value" => arg}
  defp encode_arg(true), do: %{"type" => "boolean", "value" => true}
  defp encode_arg(false), do: %{"type" => "boolean", "value" => false}
  defp encode_arg(nil), do: %{"type" => "null"}

  defp encode_arg(arg) when is_list(arg) do
    %{"type" => "array", "value" => Enum.map(arg, &encode_arg/1)}
  end

  # WebDriver-style element reference — translate to a BiDi node handle
  # so `arguments[N]` is a live DOM element on the page side, not an
  # opaque JSON object. Mirrors V2.CDPClient.encode_script_args's
  # element detection.
  defp encode_arg(%{@web_element_identifier => shared_id}) when is_binary(shared_id),
    do: %{"sharedId" => shared_id}

  defp encode_arg(%{"sharedId" => shared_id}) when is_binary(shared_id),
    do: %{"sharedId" => shared_id}

  defp encode_arg(arg) when is_map(arg) do
    pairs =
      Enum.map(arg, fn {k, v} ->
        [encode_arg(to_string(k)), encode_arg(v)]
      end)

    %{"type" => "object", "value" => pairs}
  end

  # BiDi script.evaluate / callFunction returns one of:
  #   %{"type" => "success", "result" => RemoteValue}
  #   %{"type" => "exception", "exceptionDetails" => ...}
  #
  # RemoteValue for primitives is `%{"type" => "string"|"number"|...,
  #   "value" => value}`. For undefined/null it's just `%{"type" =>
  #   "undefined"|"null"}` with no value field. Decode to a plain
  #   Elixir term where possible.
  defp decode_eval_result(%{"type" => "success", "result" => remote}),
    do: {:ok, decode_remote_value(remote)}

  defp decode_eval_result(%{"type" => "exception", "exceptionDetails" => details}),
    do: {:error, {:js_exception, details}}

  defp decode_eval_result(other), do: {:error, {:unexpected_eval_response, other}}

  defp decode_remote_value(%{"type" => "undefined"}), do: nil
  defp decode_remote_value(%{"type" => "null"}), do: nil
  defp decode_remote_value(%{"type" => t, "value" => v}) when t in ["string", "boolean"], do: v
  defp decode_remote_value(%{"type" => "number", "value" => v}) when is_number(v), do: v

  defp decode_remote_value(%{"type" => "number", "value" => "Infinity"}), do: :infinity
  defp decode_remote_value(%{"type" => "number", "value" => "-Infinity"}), do: :neg_infinity
  defp decode_remote_value(%{"type" => "number", "value" => "NaN"}), do: :nan

  defp decode_remote_value(%{"type" => "array", "value" => items}) when is_list(items),
    do: Enum.map(items, &decode_remote_value/1)

  defp decode_remote_value(%{"type" => "object", "value" => pairs}) when is_list(pairs) do
    Enum.into(pairs, %{}, fn [k, v] ->
      {decode_remote_value(k), decode_remote_value(v)}
    end)
  end

  defp decode_remote_value(other), do: other

  # ----- Page introspection -----

  @spec current_url(Session.t()) :: {:ok, String.t()} | {:error, term}
  def current_url(%Session{} = session) do
    evaluate(session, "location.href")
  end

  @spec page_title(Session.t()) :: {:ok, String.t()} | {:error, term}
  def page_title(%Session{} = session) do
    evaluate(session, "document.title")
  end

  @spec page_source(Session.t()) :: {:ok, String.t()} | {:error, term}
  def page_source(%Session{} = session) do
    evaluate(session, "document.documentElement.outerHTML")
  end

  @spec current_path(Session.t()) :: {:ok, String.t()} | {:error, term}
  def current_path(%Session{} = session) do
    evaluate(session, "location.pathname")
  end

  # ----- Element-scoped ops -----

  @doc """
  Run a JS function with `this` bound to the given element.
  BiDi's `script.callFunction` accepts a `this` argument — pass it
  the element's sharedId so the function body sees the live DOM
  node. Returns the deserialized value, or `{:error, :stale_reference}`
  for a detached node sentinel.
  """
  @spec call_on_element(Session.t(), Element.t(), String.t(), [term]) ::
          {:ok, term} | {:error, term}
  def call_on_element(
        %Session{browsing_context: ctx} = session,
        %Element{bidi_shared_id: shared_id},
        fn_decl,
        args \\ []
      )
      when is_binary(shared_id) and is_binary(fn_decl) do
    params = %{
      "functionDeclaration" => fn_decl,
      "this" => %{"sharedId" => shared_id},
      "arguments" => Enum.map(args, &encode_arg/1),
      "awaitPromise" => false,
      "target" => %{"context" => ctx}
    }

    case Protocol.cdp_send(session, "script.callFunction", params, []) do
      {:ok, %{"type" => "exception", "exceptionDetails" => details}} ->
        if stale_marker?(details), do: {:error, :stale_reference}, else: {:error, {:js_exception, details}}

      {:ok, result} ->
        case decode_eval_result(result) do
          # call_on_element callers can opt into the stale sentinel by
          # returning `{__wallabidi_stale: true}` — translate it here so
          # they don't all repeat the same pattern.
          {:ok, %{"__wallabidi_stale" => true}} -> {:error, :stale_reference}
          other -> other
        end

      error ->
        error
    end
  end

  defp stale_marker?(%{"text" => msg}) when is_binary(msg) do
    String.contains?(msg, "no such node") or
      String.contains?(msg, "stale element") or
      String.contains?(msg, "detached")
  end

  defp stale_marker?(_), do: false

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

  @spec text(Session.t(), Element.t()) :: {:ok, String.t()} | {:error, term}
  def text(%Session{} = session, %Element{} = element) do
    call_on_element(session, element, @extract_text_js)
  end

  @spec attribute(Session.t(), Element.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term}
  def attribute(%Session{} = session, %Element{} = element, name) when is_binary(name) do
    call_on_element(
      session,
      element,
      """
      function(name) {
        if (this && !this.isConnected) return {__wallabidi_stale: true};
        if (name === 'value' && 'value' in this) return this.value;
        if (name === 'checked') return this.checked ? 'true' : null;
        if (name === 'selected') return this.selected ? 'true' : null;
        if (name === 'outerHTML') return this.outerHTML;
        if (name === 'innerHTML') return this.innerHTML;
        return this.getAttribute(name);
      }
      """,
      [name]
    )
  end

  @spec displayed(Session.t(), Element.t()) :: {:ok, boolean} | {:error, term}
  def displayed(%Session{} = session, %Element{} = element) do
    call_on_element(
      session,
      element,
      """
      function() {
        if (!this.isConnected) return false;
        if (this.tagName === 'OPTION') {
          var sel = this.closest('select');
          if (!sel) return true;
          var ss = window.getComputedStyle(sel);
          return ss.display !== 'none' && ss.visibility !== 'hidden';
        }
        var st = window.getComputedStyle(this);
        if (st.display === 'none' || st.visibility === 'hidden') return false;
        var r = this.getBoundingClientRect();
        if (r.width === 0 && r.height === 0 && this.offsetParent === null && st.position !== 'fixed') return false;
        return true;
      }
      """
    )
  end

  # ----- Interactions -----

  @doc """
  Run the bootstrap's classifier on the element. Returns one of
  `"none" | "patch" | "navigate" | "full_page"` for `:click`, or
  the equivalent for `:change`. Caller uses this to decide whether
  to await a page_ready signal after the interaction.
  """
  @spec classify(Session.t(), Element.t(), :click | :change) ::
          {:ok, String.t()} | {:error, term}
  def classify(%Session{} = session, %Element{} = element, interaction)
      when interaction in [:click, :change] do
    call_on_element(
      session,
      element,
      "function(t) { return window.__w.classify(this, t); }",
      [Atom.to_string(interaction)]
    )
  end

  @doc """
  LV-aware click. Captures `pre_page_id` BEFORE the click, classifies
  the element to decide what to await, then issues the click and
  blocks for the appropriate signal. Mirrors V2.CDPClient.click_aware
  shape — same primitive contract, BiDi underneath.

  Returns `{:ok, classification}` on success, `{:error, :timeout}`
  if the expected signal didn't arrive, or `{:error, term}` for
  transport errors.
  """
  @spec click_aware(Session.t(), Element.t(), keyword) ::
          {:ok, String.t()} | {:error, term}
  def click_aware(%Session{} = session, %Element{} = element, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    pre_page_id = Protocol.get_page_id(session)

    with :ok <- await_lv_ready(session, timeout),
         {:ok, classification} <- classify(session, element, :click),
         {:ok, _} <- click(session, element) do
      case classification do
        "none" ->
          {:ok, classification}

        _ ->
          case Protocol.await_page_ready_after(session, pre_page_id, timeout) do
            :ok -> {:ok, classification}
            :timeout -> {:error, :timeout}
          end
      end
    end
  end

  @doc """
  Like `click_aware/3` but returns a status tag (`:ready` or
  `:timeout`) so callers can handle patch-classified timeouts
  silently — same shape as V2.CDPClient.click_aware_with_classification.
  """
  @spec click_aware_with_classification(Session.t(), Element.t(), keyword) ::
          {:ok, String.t(), :ready | :timeout} | {:error, term}
  def click_aware_with_classification(%Session{} = session, %Element{} = element, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    pre_page_id = Protocol.get_page_id(session)

    with :ok <- await_lv_ready(session, timeout),
         {:ok, classification} <- classify(session, element, :click),
         {:ok, _} <- click(session, element) do
      case classification do
        "none" ->
          {:ok, classification, :ready}

        _ ->
          case Protocol.await_page_ready_after(session, pre_page_id, timeout) do
            :ok -> {:ok, classification, :ready}
            :timeout -> {:ok, classification, :timeout}
          end
      end
    end
  end

  # Block until liveSocket.main has finished joining (or there's no
  # LiveView). Mirrors CDPClient.await_lv_ready — without it, clicks
  # fired during the join window get dropped.
  defp await_lv_ready(%Session{} = session, timeout_ms) do
    js = """
    new Promise(function(resolve) {
      var deadline = Date.now() + #{timeout_ms};
      function check() {
        var ls = window.liveSocket;
        if (!ls || !ls.main) return resolve(true);
        if (ls.main.joinPending !== true) return resolve(true);
        if (Date.now() > deadline) return resolve(false);
        setTimeout(check, 20);
      }
      check();
    })
    """

    case evaluate_async(session, js) do
      {:ok, _} -> :ok
      _ -> :ok
    end
  end

  @spec click(Session.t(), Element.t()) :: {:ok, nil} | {:error, term}
  def click(%Session{} = session, %Element{} = element) do
    case call_on_element(
           session,
           element,
           """
           function() {
             if (window.__w && window.__w.clickEl) {
               if (this.tagName !== 'OPTION') {
                 this.scrollIntoView({block: 'center', inline: 'nearest'});
                 if (typeof this.focus === 'function') this.focus();
               }
               window.__w.clickEl(this);
               return null;
             }
             this.scrollIntoView({block: 'center', inline: 'nearest'});
             if (typeof this.focus === 'function') this.focus();
             this.click();
             return null;
           }
           """
         ) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  @doc """
  DOM-based set_value. Mirrors V2.CDPClient.set_value's DOM path —
  handles checkboxes, radios, options, and text inputs.

  File inputs are NOT supported on this BiDi client yet (the CDP
  client uses DOM.setFileInputFiles, which has no direct BiDi
  equivalent — chromium-bidi 0.4+ exposes
  `input.setFiles` but support is uneven). Step 2 will fork a
  separate code path for them.
  """
  @spec set_value(Session.t(), Element.t(), term) :: {:ok, nil} | {:error, term}
  def set_value(%Session{} = session, %Element{} = element, value) do
    case call_on_element(
           session,
           element,
           """
           function(v) {
             var t = this.tagName;
             var ty = (this.type || '').toLowerCase();

             if (t === 'INPUT' && (ty === 'checkbox' || ty === 'radio')) {
               this.checked = !!v;
               this.dispatchEvent(new Event('input', {bubbles: true}));
               this.dispatchEvent(new Event('change', {bubbles: true}));
               return null;
             }

             if (t === 'OPTION') {
               var sel = this.closest('select');
               if (sel) {
                 if (sel.multiple) {
                   this.selected = !!v;
                 } else {
                   sel.value = this.value;
                   for (var i = 0; i < sel.options.length; i++) {
                     sel.options[i].selected = (sel.options[i] === this);
                   }
                 }
                 sel.dispatchEvent(new Event('input', {bubbles: true}));
                 sel.dispatchEvent(new Event('change', {bubbles: true}));
               } else {
                 this.selected = !!v;
               }
               return null;
             }

             this.value = v;
             this.dispatchEvent(new Event('input', {bubbles: true}));
             this.dispatchEvent(new Event('change', {bubbles: true}));
             return null;
           }
           """,
           [value]
         ) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  @doc """
  Clears the element's value. With `silent: true` (default), no
  events are dispatched — used internally before fill_in to avoid
  firing phx-change for the intermediate empty state.
  """
  @spec clear(Session.t(), Element.t(), keyword) :: {:ok, nil} | {:error, term}
  def clear(%Session{} = session, %Element{} = element, opts \\ []) do
    silent? = Keyword.get(opts, :silent, true)

    fn_decl =
      if silent? do
        "function() { this.value = ''; return null; }"
      else
        """
        function() {
          this.value = '';
          this.dispatchEvent(new Event('input', {bubbles: true}));
          this.dispatchEvent(new Event('change', {bubbles: true}));
          return null;
        }
        """
      end

    case call_on_element(session, element, fn_decl) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  @doc """
  Send text to an element. List form joins; atom form (special keys
  like :tab, :enter) is not supported on the BiDi path yet — would
  require `input.performActions` with a key-source action sequence.
  """
  @spec send_keys(Session.t(), Element.t(), [String.t()] | String.t()) ::
          {:ok, nil} | {:error, term}
  def send_keys(%Session{} = session, %Element{} = element, keys) when is_binary(keys) do
    send_keys(session, element, [keys])
  end

  def send_keys(%Session{} = session, %Element{} = element, keys) when is_list(keys) do
    if Enum.all?(keys, &is_binary/1) do
      text = Enum.join(keys, "")

      case call_on_element(
             session,
             element,
             """
             function(s) {
               this.value = (this.value || '') + s;
               this.dispatchEvent(new Event('input', {bubbles: true}));
               this.dispatchEvent(new Event('change', {bubbles: true}));
               return null;
             }
             """,
             [text]
           ) do
        {:ok, _} -> {:ok, nil}
        error -> error
      end
    else
      # Mixed string + special-key atoms — focus the element, then
      # dispatch a key-source action sequence via input.performActions.
      with {:ok, _} <-
             call_on_element(session, element, "function() { this.focus(); return null; }") do
        send_keys_to_session(session, keys)
      end
    end
  end

  @doc """
  Send a key sequence (text + special atoms like :tab, :enter) to
  whatever element currently has focus. BiDi's input.performActions
  with a key-source sequence handles this in one call.
  """
  @spec send_keys_to_session(Session.t(), list) :: {:ok, nil} | {:error, term}
  def send_keys_to_session(%Session{browsing_context: ctx} = session, keys) when is_list(keys) do
    actions = Commands.key_type_actions(keys)
    {method, params} = Commands.perform_actions(ctx, actions)

    case Protocol.cdp_send(session, method, params, []) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  # ----- Mouse & touch via input.performActions -----

  @doc "Hover the mouse over an element (pointer move to its center)."
  @spec hover(Element.t()) :: {:ok, nil} | {:error, term}
  def hover(%Element{bidi_shared_id: sid} = element) when is_binary(sid) do
    perform(element, Commands.pointer_move_actions(sid))
  end

  def hover(%Element{}), do: {:error, :no_bidi_shared_id}

  @doc "Synthesize a tap at the element's center via touch input source."
  @spec tap(Element.t()) :: {:ok, nil} | {:error, term}
  def tap(%Element{bidi_shared_id: sid} = element) when is_binary(sid) do
    perform(element, Commands.touch_tap_element_actions(sid))
  end

  def tap(%Element{}), do: {:error, :no_bidi_shared_id}

  @doc """
  Press a touch point. With an element, lands at the element's
  top-left corner plus offsets; without one, lands at the supplied
  absolute coordinates.
  """
  @spec touch_down(Session.t(), Element.t() | nil, number, number) ::
          {:ok, nil} | {:error, term}
  def touch_down(%Session{} = session, nil, x, y) do
    perform(session, Commands.touch_down_actions(round(x), round(y)))
  end

  def touch_down(%Session{}, %Element{bidi_shared_id: sid} = element, x_offset, y_offset)
      when is_binary(sid) do
    case element_location(element) do
      {:ok, {ex, ey}} ->
        perform(element, Commands.touch_down_actions(round(ex + x_offset), round(ey + y_offset)))

      err ->
        err
    end
  end

  def touch_down(%Session{}, %Element{}, _, _), do: {:error, :no_bidi_shared_id}

  @doc "Release any active touch points."
  @spec touch_up(Session.t() | Element.t()) :: {:ok, nil} | {:error, term}
  def touch_up(parent), do: perform(parent, Commands.touch_up_actions())

  @doc "Move the active touch point to absolute coordinates."
  @spec touch_move(Session.t() | Element.t(), number, number) :: {:ok, nil} | {:error, term}
  def touch_move(parent, x, y), do: perform(parent, Commands.touch_move_actions(x, y))

  @doc "Press a mouse button at the cursor's current position."
  @spec button_down(Session.t() | Element.t(), :left | :middle | :right) ::
          {:ok, nil} | {:error, term}
  def button_down(parent, button) do
    perform(parent, Commands.pointer_button_down_actions(button))
  end

  @doc "Release a mouse button at the cursor's current position."
  @spec button_up(Session.t() | Element.t(), :left | :middle | :right) ::
          {:ok, nil} | {:error, term}
  def button_up(parent, button) do
    perform(parent, Commands.pointer_button_up_actions(button))
  end

  @doc "Press+release a mouse button at the cursor's current position."
  @spec click_at_cursor(Session.t() | Element.t(), :left | :middle | :right) ::
          {:ok, nil} | {:error, term}
  def click_at_cursor(parent, button) do
    perform(parent, Commands.pointer_click_at_position_actions(button))
  end

  @doc "Move the mouse cursor by an offset from its current position."
  @spec move_mouse_by(Session.t() | Element.t(), number, number) ::
          {:ok, nil} | {:error, term}
  def move_mouse_by(parent, x_offset, y_offset) do
    perform(parent, Commands.pointer_move_by_actions(x_offset, y_offset))
  end

  @doc "Double-click at the cursor's current position."
  @spec double_click(Session.t() | Element.t()) :: {:ok, nil} | {:error, term}
  def double_click(parent) do
    perform(parent, Commands.pointer_double_click_actions())
  end

  defp perform(parent, actions) do
    session = Element.root_session(parent)
    {method, params} = Commands.perform_actions(session.browsing_context, actions)

    case Protocol.cdp_send(session, method, params, []) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  # ----- Element geometry -----

  @doc "Element width/height in CSS pixels via getBoundingClientRect."
  @spec element_size(Element.t()) :: {:ok, {number, number}} | {:error, term}
  def element_size(%Element{} = element) do
    session = Element.root_session(element)

    case call_on_element(
           session,
           element,
           "function() { var r = this.getBoundingClientRect(); return [r.width, r.height]; }"
         ) do
      {:ok, [w, h]} -> {:ok, {w, h}}
      {:ok, other} -> {:error, {:unexpected_size, other}}
      err -> err
    end
  end

  @doc "Element top-left coordinates relative to the viewport."
  @spec element_location(Element.t()) :: {:ok, {number, number}} | {:error, term}
  def element_location(%Element{} = element) do
    session = Element.root_session(element)

    case call_on_element(
           session,
           element,
           "function() { var r = this.getBoundingClientRect(); return [r.left, r.top]; }"
         ) do
      {:ok, [x, y]} -> {:ok, {x, y}}
      {:ok, other} -> {:error, {:unexpected_location, other}}
      err -> err
    end
  end

  # ----- Element finding -----

  @doc """
  Push-based find. The bootstrap channel signals `{id, count}` once
  the query resolves, then we fetch the element refs as sharedIds
  via `script.callFunction` with `resultOwnership: "root"`.
  """
  @spec find_elements(Session.t() | Element.t(), Wallabidi.Query.t(), keyword) ::
          {:ok, [Element.t()]} | {:error, term}
  def find_elements(parent, %Wallabidi.Query{} = query, opts \\ []) do
    session = Element.root_session(parent)
    timeout = Keyword.get(opts, :timeout, 5_000)
    count = Wallabidi.Query.count(query)

    with {:ok, ops, _validated} <- Ops.from_wallaby(parent, query, nil) do
      query_id = "v2-bidi-q-#{System.unique_integer([:positive])}"
      ops_json = Jason.encode!(ops.ops)
      count_js = if is_integer(count), do: Integer.to_string(count), else: "null"
      root_js = if ops.parent_id, do: "this", else: "null"
      register_js = Bootstrap.register_js(query_id, ops_json, count_js, root_js)

      :ok = Protocol.register_find(session, query_id, timeout)

      # Fire the bootstrap. Same shape as CDP find: scope to the parent
      # element via `this`, or run at document scope.
      cast_register(session, ops.parent_id, register_js)

      case Protocol.await_find_result(session, query_id, timeout) do
        {:ok, found, _meta} when found > 0 ->
          fetch_element_refs(session, query_id, found)

        {:ok, _, _} ->
          {:ok, []}

        {:error, :invalid_selector} ->
          {:error, :invalid_selector}

        {:timeout, _} ->
          # Push didn't fire (count-shape mismatch — query asked for
          # exactly 1 but page has 2, etc). Run W.exec synchronously
          # so callers see the *actual* element count for error
          # messaging ("but found 2"). Mirrors CDPClient.final_sync_exec.
          final_sync_exec(session, ops_json, ops.parent_id)
      end
    end
  end

  defp final_sync_exec(%Session{browsing_context: ctx} = session, ops_json, parent_shared_id) do
    fn_decl =
      if parent_shared_id do
        "function() { return window.__w ? window.__w.exec(#{ops_json}, this).els : []; }"
      else
        "() => window.__w ? window.__w.exec(#{ops_json}, null).els : []"
      end

    base_params = %{
      "functionDeclaration" => fn_decl,
      "awaitPromise" => false,
      "resultOwnership" => "root",
      "target" => %{"context" => ctx}
    }

    params =
      if parent_shared_id do
        Map.put(base_params, "this", %{"sharedId" => parent_shared_id})
      else
        base_params
      end

    case Protocol.cdp_send(session, "script.callFunction", params, []) do
      {:ok, %{"type" => "success", "result" => %{"type" => "array", "value" => items}}}
      when is_list(items) ->
        elements =
          items
          |> Enum.map(fn
            %{"sharedId" => sid} when is_binary(sid) ->
              %Element{
                id: sid,
                bidi_shared_id: sid,
                parent: session,
                driver: session.driver,
                url: session.session_url
              }

            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, elements}

      _ ->
        {:ok, []}
    end
  end

  defp cast_register(%Session{browsing_context: ctx} = session, nil, register_js) do
    Protocol.cdp_cast(
      session,
      "script.callFunction",
      %{
        "functionDeclaration" => "() => { #{register_js} }",
        "awaitPromise" => false,
        "target" => %{"context" => ctx}
      },
      []
    )
  end

  defp cast_register(%Session{browsing_context: ctx} = session, parent_shared_id, register_js)
       when is_binary(parent_shared_id) do
    Protocol.cdp_cast(
      session,
      "script.callFunction",
      %{
        "functionDeclaration" => "function() { #{register_js} }",
        "this" => %{"sharedId" => parent_shared_id},
        "awaitPromise" => false,
        "target" => %{"context" => ctx}
      },
      []
    )
  end

  # Fetch the resolved query's element list as an array of sharedIds.
  # `resultOwnership: "root"` keeps node references alive on the
  # remote side so we can hold them past this call.
  defp fetch_element_refs(%Session{browsing_context: ctx} = session, query_id, found_count) do
    id_js = Jason.encode!(query_id)

    fn_decl = """
    () => {
      var q = window.__w && window.__w.queries && window.__w.queries[#{id_js}];
      return q ? q.elements : [];
    }
    """

    params = %{
      "functionDeclaration" => fn_decl,
      "awaitPromise" => false,
      "resultOwnership" => "root",
      "target" => %{"context" => ctx}
    }

    case Protocol.cdp_send(session, "script.callFunction", params, []) do
      {:ok, %{"type" => "success", "result" => %{"type" => "array", "value" => items}}}
      when is_list(items) ->
        elements =
          items
          |> Enum.map(fn
            %{"sharedId" => sid} when is_binary(sid) ->
              %Element{
                id: sid,
                bidi_shared_id: sid,
                parent: session,
                driver: session.driver,
                url: session.session_url
              }

            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)

        # Best-effort cleanup of the bootstrap's stored entry so memory
        # doesn't accumulate across queries.
        Protocol.cdp_cast(
          session,
          "script.callFunction",
          %{
            "functionDeclaration" => "() => { #{Bootstrap.cleanup_js(query_id)} }",
            "awaitPromise" => false,
            "target" => %{"context" => ctx}
          },
          []
        )

        {:ok, elements}

      _ ->
        # Page navigated mid-flight or the array's gone — emit
        # placeholders so callers see the count, but ops on them will
        # surface as stale_reference.
        {:ok,
         List.duplicate(%Element{parent: session, driver: session.driver}, found_count)}
    end
  end
end
