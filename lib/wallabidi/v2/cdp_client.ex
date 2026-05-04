defmodule Wallabidi.V2.CDPClient do
  @moduledoc false

  # Thin façade over `Wallabidi.V2.Session` providing CDP-shaped
  # operations (`Page.navigate`, `Runtime.evaluate`, etc.). Exists so
  # callers (drivers, tests) can write `V2.CDPClient.evaluate(s, ...)`
  # without knowing about the Session GenServer or wire-id correlation.
  #
  # Each function:
  #   1. Constructs the CDP method + params
  #   2. Calls `V2.Session.cdp_send/4`
  #   3. Returns `{:ok, result_map}` or `{:error, reason}`
  #
  # No retries, no waiters, no protocol-aware semantics — those are
  # the Session's job. This module is just the shape adapter.
  #
  # Operations are added one at a time, each with an integration test
  # against a live Lightpanda server. See test/wallabidi/v2/.

  alias Wallabidi.{Bootstrap, Element, Session}
  alias Wallabidi.CDP.{Commands, Ops, ResponseParser}
  alias Wallabidi.V2.Session, as: V2Session
  alias Wallabidi.V2.WebSocket

  @doc """
  Returns the CDP send opts (`:flat_session_id` + `:session_id`) for
  a given Session. Used internally by every CDP call.
  """
  @spec send_opts(Session.t()) :: keyword
  def send_opts(%Session{} = session) do
    if session.capabilities[:flat_session_id] do
      [flat_session_id: true, session_id: session.browsing_context]
    else
      [session_id: session.browsing_context]
    end
  end

  @doc false
  # Helper: send a raw CDP method+params via V2.Session and return
  # the unwrapped CDP result.
  def cdp_send(%Session{} = session, method, params) do
    V2Session.cdp_send(session, method, params, send_opts(session))
  end

  @doc false
  # Fire-and-forget CDP send. The response is dropped. CDP serializes
  # per-session, so any subsequent `cdp_send/3` still observes the
  # effects of the cast call.
  def cdp_cast(%Session{} = session, method, params) do
    V2Session.cdp_cast(session, method, params, send_opts(session))
  end

  # ----- Page domain enables -----

  @doc """
  Enables CDP's Page domain for the session and subscribes to
  `Page.lifecycleEvent`. After this returns, V2.Session is set up
  to resolve `await_page_load/4` calls when matching events arrive.

  Idempotent — safe to call more than once.
  """
  @spec enable_page_lifecycle_events(Session.t()) :: :ok | {:error, term}
  def enable_page_lifecycle_events(%Session{} = session) do
    # Subscribe BEFORE the enables so we don't miss the first
    # lifecycle event on the next visit. The enables themselves are
    # fire-and-forget — CDP applies commands in order per session,
    # so subsequent blocking sends still see their effects.
    :ok = V2Session.subscribe(session, "Page.lifecycleEvent")
    cdp_cast(session, "Page.enable", %{})
    cdp_cast(session, "Page.setLifecycleEventsEnabled", %{enabled: true})
    :ok
  end

  @doc """
  Installs the wallabidi browser-side bootstrap (`window.__w`):

    1. `Runtime.enable` — required for `Runtime.addBinding`.
    2. `Runtime.addBinding(name: "__wallabidi")` — exposes a binding
       that, when called from JS, fires a `Runtime.bindingCalled` event
       up the WebSocket. Subscribes the Session to that event.
    3. `Page.addScriptToEvaluateOnNewDocument(source: Bootstrap.cdp_iife())` —
       runs the bootstrap IIFE in every new document. Defines
       `window.__w` (opcode interpreter, find machinery, LV patch hook).

  After this, push-based element finding works: the V2 find path
  registers a query in `window.__w.queries`, calls `W.check()`, and
  awaits a `Runtime.bindingCalled` event matching its query id.

  Idempotent — calling twice re-registers the binding (harmless) and
  re-installs the preload (deduped JS-side via `if (window.__w) return`).
  """
  @spec install_bootstrap(Session.t()) :: :ok | {:error, term}
  def install_bootstrap(%Session{} = session) do
    # Subscribe + Runtime.enable can be cast (CDP applies in order).
    # Runtime.addBinding and Page.addScriptToEvaluateOnNewDocument
    # MUST complete before any find runs — those stay blocking.
    :ok = V2Session.subscribe(session, "Runtime.bindingCalled")
    cdp_cast(session, "Runtime.enable", %{})

    with {:ok, _} <- cdp_send(session, "Runtime.addBinding", %{name: "__wallabidi"}),
         {:ok, _} <-
           cdp_send(session, "Page.addScriptToEvaluateOnNewDocument", %{
             source: Wallabidi.Bootstrap.cdp_iife()
           }) do
      :ok
    end
  end

  # ----- Page.navigate -----

  @doc """
  Navigates the session's target to `url`. Returns
  `{:ok, %{loader_id: ..., frame_id: ...}}` on a successful nav.

  Note: this is a blocking *send* — it returns once Chrome has
  acknowledged the navigation request, NOT once the page has finished
  loading. To wait for `loadEventFired`, layer
  `await_page_load/2` (TBA) on top.

  Errors:
    * `{:error, {:navigate_failed, reason}}` for protocol-level errors
      surfaced via the `errorText` field
    * `{:error, term}` for transport/timeouts
  """
  @spec navigate(Session.t(), String.t()) ::
          {:ok, %{loader_id: String.t() | nil, frame_id: String.t() | nil}}
          | {:error, term}
  def navigate(%Session{} = session, url) when is_binary(url) do
    case cdp_send(session, "Page.navigate", %{url: url}) do
      {:ok, %{"errorText" => msg}} when is_binary(msg) and msg != "" ->
        {:error, {:navigate_failed, msg}}

      {:ok, result} when is_map(result) ->
        {:ok, %{loader_id: result["loaderId"], frame_id: result["frameId"]}}

      error ->
        error
    end
  end

  # ----- Element-scoped operations -----

  @doc """
  Runs a JS function against the given element's `objectId` (`this`),
  optionally with positional args. Returns the serialised value.

  Equivalent to `Runtime.callFunctionOn` with `returnByValue: true`.

  Used as a building block for element-scoped operations (text,
  attribute, displayed, etc.).
  """
  @spec call_on_element(Session.t(), Element.t(), String.t(), [term]) ::
          {:ok, term} | {:error, term}
  def call_on_element(
        %Session{} = session,
        %Element{bidi_shared_id: object_id},
        fn_decl,
        args \\ []
      )
      when is_binary(object_id) and is_binary(fn_decl) and is_list(args) do
    encoded_args = Enum.map(args, &%{value: &1})

    case cdp_send(session, "Runtime.callFunctionOn", %{
           objectId: object_id,
           functionDeclaration: fn_decl,
           arguments: encoded_args,
           returnByValue: true
         }) do
      {:ok, %{"result" => %{"value" => value}}} ->
        {:ok, value}

      {:ok, %{"result" => %{"type" => "undefined"}}} ->
        {:ok, nil}

      {:ok, %{"exceptionDetails" => details}} ->
        {:error, {:js_exception, details}}

      {:ok, _} = ok ->
        ok

      {:error, {_code, msg}} = err when is_binary(msg) ->
        # CDP signals a stale objectId via these messages. Translating
        # to :stale_reference lets Element.handle_*_result raise the
        # expected StaleReferenceError instead of a generic Runtime.
        if stale_marker?(msg), do: {:error, :stale_reference}, else: err

      error ->
        error
    end
  end

  defp stale_marker?(msg) when is_binary(msg) do
    String.contains?(msg, "Cannot find context") or
      String.contains?(msg, "No node with given id") or
      String.contains?(msg, "Could not find object with given id") or
      String.contains?(msg, "Object has been released")
  end

  @extract_text_js """
  function() {
    // Always use a DOM walker so the result is consistent across
    // engines that *have* a layout pass (Chrome, where innerText
    // already inserts newlines between blocks) and engines that
    // *don't* (Lightpanda, where innerText would just whitespace-
    // collapse). Mirrors what the legacy CDPClient.text does.
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

  @doc "Returns the element's visible text content (`innerText` / fallback)."
  @spec text(Session.t(), Element.t()) :: {:ok, String.t()} | {:error, term}
  def text(%Session{} = session, %Element{} = element) do
    # innerText handles whitespace/block-element newlines in real
    # browsers (Chrome). Headless engines without a layout pass
    # (Lightpanda) lack innerText, so fall back to a DOM walker that
    # inserts newlines between block-level elements — matching
    # Wallaby's contract for cross-engine text equality.
    call_on_element(session, element, @extract_text_js)
  end

  @doc """
  Returns the value of a named attribute on the element, or `nil` if
  not set. Treats `value`, `checked`, and `selected` specially —
  those map to live DOM properties rather than HTML attributes.
  """
  @spec attribute(Session.t(), Element.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term}
  def attribute(%Session{} = session, %Element{} = element, name) when is_binary(name) do
    # Detached nodes still hold a live JS reference, so call_on_element
    # would happily run `this.getAttribute(...)` on them. To match
    # Wallaby's "raise StaleReferenceError when the element has left
    # the document" contract, we check `isConnected` and signal stale
    # via a sentinel return value.
    case call_on_element(
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
         ) do
      {:ok, %{"__wallabidi_stale" => true}} -> {:error, :stale_reference}
      result -> result
    end
  end

  @doc """
  Returns whether the element would be considered visible to a user.

  Mirrors the existing CDPClient.displayed/1 contract:
    * isConnected (still in document tree)
    * own display/visibility not hidden
    * non-empty rect OR offsetParent OR fixed position
    * OPTION special-case (closed selects have no layout but are clickable)
  """
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

  @doc """
  Sets the value of an input element and dispatches `input` and
  `change` events. Suitable for `<input>`, `<textarea>`, and
  `<select>`. For `<select>`, sets `.value` and synthesises change.

  Mirrors today's CDPClient.set_value/2 (event-dispatching) shape —
  unlike clear/2 which has a `silent` mode that skips events.
  """
  @spec set_value(Session.t(), Element.t(), term) :: {:ok, nil} | {:error, term}
  def set_value(%Session{} = session, %Element{} = element, value) do
    # File inputs reject `.value = x` for security reasons. The only
    # programmatic way to populate them is CDP's DOM.setFileInputFiles.
    case file_input?(session, element) do
      {:ok, true} ->
        set_file_input(session, element, value)

      _ ->
        set_value_dom(session, element, value)
    end
  end

  defp file_input?(%Session{} = session, %Element{} = element) do
    call_on_element(
      session,
      element,
      "function() { return this.tagName === 'INPUT' && (this.type || '').toLowerCase() === 'file'; }"
    )
  end

  defp set_file_input(%Session{} = session, %Element{bidi_shared_id: object_id} = element, value) do
    raw_paths =
      case value do
        list when is_list(list) -> list
        v when is_binary(v) and v != "" -> [v]
        _ -> []
      end

    # Filter out non-existent paths so a missing file is a no-op,
    # matching legacy behavior. Tests rely on `Wallabidi.Element.value`
    # being empty when the file doesn't exist on disk.
    paths = Enum.filter(raw_paths, &File.exists?/1)

    with {:ok, %{"node" => %{"backendNodeId" => bid}}} <-
           cdp_send(session, "DOM.describeNode", %{objectId: object_id}),
         {:ok, _} <-
           cdp_send(session, "DOM.setFileInputFiles", %{
             files: paths,
             backendNodeId: bid
           }) do
      _ =
        call_on_element(
          session,
          element,
          """
          function() {
            this.dispatchEvent(new Event('input', {bubbles: true}));
            this.dispatchEvent(new Event('change', {bubbles: true}));
            return null;
          }
          """
        )

      {:ok, nil}
    end
  end

  defp set_value_dom(%Session{} = session, %Element{} = element, value) do
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
  Clears the element's value. With `silent: true` (default), no events
  are dispatched — used internally before fill_in to avoid firing
  phx-change for the intermediate empty state.
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
  Sends keys to the element. `keys` is a list of string segments;
  each segment is appended to the element's value, with `input` and
  `change` events dispatched after each.

  Special-key atoms (`:enter`, `:tab`, etc.) are NOT supported here —
  full key mapping comes when we layer in CDP's
  `Input.dispatchKeyEvent`. For now, just text input.
  """
  @spec send_keys(Session.t(), Element.t(), [String.t()] | String.t()) ::
          {:ok, nil} | {:error, term}
  def send_keys(%Session{} = session, %Element{} = element, keys) when is_binary(keys) do
    send_keys(session, element, [keys])
  end

  def send_keys(%Session{} = session, %Element{} = element, keys) when is_list(keys) do
    if Enum.all?(keys, &is_binary/1) do
      # Plain text — fast path keeps Lightpanda working (Input.dispatchKeyEvent
      # is broken there).
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
      # Mixed string+atom — focus the element and dispatch real key events
      # so :tab, :enter etc. fire. Requires a CDP browser that implements
      # Input.dispatchKeyEvent (Chrome does; Lightpanda doesn't).
      _ =
        cdp_send(session, "Runtime.callFunctionOn", %{
          objectId: element.bidi_shared_id,
          functionDeclaration: "function() { this.focus(); }",
          returnByValue: true
        })

      send_keys_to_session(session, keys)
    end
  end

  @doc """
  Send keys to whatever element currently has focus on the page.
  Atoms like `:tab`, `:enter` map to real key events via
  `Input.dispatchKeyEvent`.
  """
  @spec send_keys_to_session(Session.t(), [String.t() | atom]) :: {:ok, nil}
  def send_keys_to_session(%Session{} = session, keys) when is_list(keys) do
    Enum.each(keys, fn
      key when is_atom(key) ->
        {code, key_val} = key_mapping(key)
        send_key_event(session, code, key_val)

      text when is_binary(text) ->
        for char <- String.graphemes(text) do
          cdp_send(session, "Input.dispatchKeyEvent", %{type: "keyDown", text: char})
          cdp_send(session, "Input.dispatchKeyEvent", %{type: "keyUp", text: char})
        end
    end)

    {:ok, nil}
  end

  defp send_key_event(session, code, key_val) do
    cdp_send(session, "Input.dispatchKeyEvent", %{
      type: "rawKeyDown",
      key: key_val,
      code: code,
      windowsVirtualKeyCode: key_code(code)
    })

    cdp_send(session, "Input.dispatchKeyEvent", %{
      type: "keyUp",
      key: key_val,
      code: code,
      windowsVirtualKeyCode: key_code(code)
    })
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

  @doc """
  Classifies what kind of LV interaction `element` represents for an
  upcoming `interaction` (currently `:click` or `:change`).

  Reads `window.__w.classify(this, interaction)` (installed by the
  bootstrap), which inspects `phx-click` / `data-phx-link` /
  `phx-trigger-action` / form `action` / `<a href>` to decide:

    * `"patch"` — phx-click or live_redirect=patch; expect a DOM patch
    * `"navigate"` — data-phx-link=redirect or JS.navigate; new LV mount
    * `"full_page"` — submit button in a non-LV form, plain anchor
    * `"none"` — JS-only interaction (hash href, target=_blank, …)

  The string from JS is returned as-is.
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
  Click an element. Scrolls into view, focuses, then dispatches the
  click via the DOM API.

  This is a *simple* click — no LV-aware classification or
  post-click await. Use `click_aware/3` when the click may trigger a
  LiveView patch or navigation that the caller wants to wait for.
  """
  @spec click(Session.t(), Element.t()) :: {:ok, nil} | {:error, term}
  def click(%Session{} = session, %Element{} = element) do
    # Route through the bootstrap's W.clickEl so <option> clicks
    # update the parent <select>'s value + dispatch 'change' (a plain
    # `el.click()` on an option doesn't change selection in headless
    # Chrome). For everything else this is the same scroll+focus+click.
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
  LV-aware click. Captures `pre_page_id` BEFORE the click, classifies
  the element to decide what to await, then issues the click and
  blocks for the appropriate signal:

    * `"none"` — JS-only interaction (hash href, target=_blank).
      Returns immediately, no wait.
    * `"patch"` / `"navigate"` / `"full_page"` — awaits the next
      `page_ready` notification. The bootstrap's onPatchEnd hook
      bumps pageId on every LV patch, and a fresh document fires
      a new page_ready, so one signal covers all three cases.

  Returns `{:ok, classification}` on success, `{:error, :timeout}`
  if the expected signal didn't arrive within `:timeout` (default
  5_000 ms), or `{:error, term}` for transport errors.
  """
  @spec click_aware(Session.t(), Element.t(), keyword) ::
          {:ok, String.t()} | {:error, term}
  def click_aware(%Session{} = session, %Element{} = element, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    pre_page_id = V2Session.get_page_id(session)

    with :ok <- await_lv_ready(session, timeout),
         {:ok, classification} <- classify(session, element, :click),
         {:ok, _} <- click(session, element) do
      case classification do
        "none" ->
          {:ok, classification}

        _ ->
          case V2Session.await_page_ready_after(session, pre_page_id, timeout) do
            :ok -> {:ok, classification}
            :timeout -> {:error, :timeout}
          end
      end
    end
  end

  @doc """
  Like `click_aware/3` but returns the classification AND a status
  tag (`:ready` or `:timeout`) so callers can branch on the
  classification before deciding whether a page-ready timeout is
  actually an error. Patch-classified timeouts in particular are
  silent in the legacy click pipeline.
  """
  @spec click_aware_with_classification(Session.t(), Element.t(), keyword) ::
          {:ok, String.t(), :ready | :timeout} | {:error, term}
  def click_aware_with_classification(%Session{} = session, %Element{} = element, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    pre_page_id = V2Session.get_page_id(session)

    with :ok <- await_lv_ready(session, timeout),
         {:ok, classification} <- classify(session, element, :click),
         {:ok, _} <- click(session, element) do
      case classification do
        "none" ->
          {:ok, classification, :ready}

        _ ->
          case V2Session.await_page_ready_after(session, pre_page_id, timeout) do
            :ok -> {:ok, classification, :ready}
            :timeout -> {:ok, classification, :timeout}
          end
      end
    end
  end

  # Block until liveSocket.main is finished joining (or there's no
  # LiveView at all). Mirrors the pre-click readiness wait the legacy
  # click_full op does — without it, clicks fired during the join
  # window get dropped because the LV channel hasn't bound yet.
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

    case cdp_send(session, "Runtime.evaluate", %{
           expression: js,
           awaitPromise: true,
           returnByValue: true
         }) do
      {:ok, _} -> :ok
      _ -> :ok
    end
  end

  # ----- Frame switching -----

  @doc """
  Enables CDP's Page domain (already done by enable_page_lifecycle_events)
  AND subscribes to Runtime execution-context events so V2.Session can
  track the frameId → executionContextId mapping needed by
  focus_frame_by_id/2.

  Idempotent. Best to call once at session bootstrap, after
  install_bootstrap/1.
  """
  @spec enable_frame_tracking(Session.t()) :: :ok | {:error, term}
  def enable_frame_tracking(%Session{} = session) do
    with :ok <- V2Session.subscribe(session, "Runtime.executionContextCreated"),
         :ok <- V2Session.subscribe(session, "Runtime.executionContextDestroyed") do
      :ok
    end
  end

  @doc """
  Push a frame's `executionContextId` (resolved from its `frameId`)
  onto the focus stack. Subsequent JS evaluations target this frame.

  Returns `:ok` on success, `{:error, :unknown_frame}` if no
  execution context has been observed for `frame_id` yet — typically
  because the frame hasn't loaded.
  """
  @spec focus_frame_by_id(Session.t(), String.t()) :: :ok | {:error, term}
  def focus_frame_by_id(%Session{} = session, frame_id) when is_binary(frame_id) do
    case V2Session.lookup_frame_context(session, frame_id) do
      nil ->
        {:error, :unknown_frame}

      context_id when is_integer(context_id) ->
        V2Session.push_frame(session, context_id)
        :ok
    end
  end

  @doc "Pops the top frame off the focus stack (no-op at root)."
  @spec focus_parent_frame(Session.t()) :: :ok
  def focus_parent_frame(%Session{} = session) do
    V2Session.pop_frame(session)
    :ok
  end

  # ----- Cookies -----

  @doc """
  Returns the cookies visible to the current page.
  """
  @spec cookies(Session.t()) :: {:ok, [map]} | {:error, term}
  def cookies(%Session{} = session) do
    case cdp_send(session, "Network.getCookies", %{}) do
      {:ok, %{"cookies" => cookies}} when is_list(cookies) ->
        {:ok, Enum.map(cookies, &normalize_cookie/1)}

      {:ok, _} ->
        {:ok, []}

      error ->
        error
    end
  end

  # CDP returns `expires`, WebDriver tests assert `expiry`.
  defp normalize_cookie(cookie) do
    case Map.pop(cookie, "expires") do
      {nil, c} -> c
      {-1, c} -> c
      {expires, c} -> Map.put(c, "expiry", trunc(expires))
    end
  end

  @doc """
  Sets a cookie. `attrs` may include any standard CDP `setCookie`
  fields (`url`, `domain`, `path`, `expires`, `secure`, `httpOnly`,
  `sameSite`); a `:url` is helpful when you don't have a known domain
  and just want the cookie scoped to the current page.
  """
  @spec set_cookie(Session.t(), String.t(), String.t(), map) ::
          {:ok, true | false} | {:error, term}
  def set_cookie(%Session{} = session, name, value, attrs \\ %{})
      when is_binary(name) and is_binary(value) do
    # Network.setCookie requires either `url` or `domain` — pad in the
    # current URL when callers haven't supplied one. Also translate
    # WebDriver-style `:expiry` → CDP's `:expires`.
    attrs = Map.new(attrs)

    attrs =
      case Map.pop(attrs, :expiry) do
        {nil, m} -> m
        {expiry, m} -> Map.put_new(m, :expires, expiry)
      end

    attrs =
      if Map.has_key?(attrs, :url) or Map.has_key?(attrs, "url") or
           Map.has_key?(attrs, :domain) or Map.has_key?(attrs, "domain") do
        attrs
      else
        case current_url(session) do
          {:ok, url} when is_binary(url) and url != "" -> Map.put(attrs, :url, url)
          _ -> attrs
        end
      end

    params =
      attrs
      |> Map.put(:name, name)
      |> Map.put(:value, value)

    case cdp_send(session, "Network.setCookie", params) do
      {:ok, %{"success" => true}} -> {:ok, true}
      {:ok, %{"success" => false}} -> {:ok, false}
      {:ok, _} -> {:ok, true}
      error -> error
    end
  end

  # ----- Screenshot + window size -----

  @doc """
  Captures a PNG screenshot of the current page (viewport).
  Returns the raw binary (not base64).
  """
  @spec take_screenshot(Session.t()) :: {:ok, binary} | {:error, term}
  def take_screenshot(%Session{} = session) do
    case cdp_send(session, "Page.captureScreenshot", %{format: "png"}) do
      {:ok, %{"data" => data}} when is_binary(data) ->
        Base.decode64(data)

      {:ok, _} ->
        {:error, :no_screenshot_data}

      error ->
        error
    end
  end

  @doc "Returns the current viewport size as `{:ok, %{width: w, height: h}}`."
  @spec get_window_size(Session.t()) ::
          {:ok, %{width: non_neg_integer, height: non_neg_integer}} | {:error, term}
  def get_window_size(%Session{} = session) do
    # Prefer a previously-stashed `window.__wallabidi_window_size`
    # (set by set_window_size below) — `Emulation.setDeviceMetricsOverride`
    # is a no-op on engines without a real layout pass (Lightpanda),
    # so the JS override is the only source of truth there.
    case evaluate(
           session,
           "JSON.stringify(window.__wallabidi_window_size || {width: window.innerWidth, height: window.innerHeight})"
         ) do
      {:ok, json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{"width" => w, "height" => h}} -> {:ok, %{width: w, height: h}}
          _ -> {:error, :bad_size_response}
        end

      error ->
        error
    end
  end

  @doc """
  Resizes the viewport (and optionally the device) via
  `Emulation.setDeviceMetricsOverride`. Pass 0 for `device_scale_factor`
  / `mobile` to use defaults.
  """
  @spec set_window_size(Session.t(), non_neg_integer, non_neg_integer) ::
          {:ok, nil} | {:error, term}
  def set_window_size(%Session{} = session, width, height)
      when is_integer(width) and is_integer(height) do
    _ =
      cdp_send(session, "Emulation.setDeviceMetricsOverride", %{
        width: width,
        height: height,
        deviceScaleFactor: 0,
        mobile: false
      })

    # Mirror the legacy fallback: stash the requested size as a JS
    # global on the current page AND queue it onto every future
    # document so it persists across navigations. Engines that don't
    # implement Emulation (Lightpanda) read this from
    # get_window_size/1.
    js = "window.__wallabidi_window_size = {width: #{width}, height: #{height}};"
    _ = cdp_send(session, "Runtime.evaluate", %{expression: js, returnByValue: true})

    _ =
      cdp_send(session, "Page.addScriptToEvaluateOnNewDocument", %{
        source: js
      })

    {:ok, nil}
  end

  # ----- Element finding -----

  @doc """
  Find elements matching a Wallabidi.Query.

  `parent` is either a `Session` (search from `document`) or an
  `Element` (search within that element's subtree). Element-scoped
  searches use the bootstrap's `root_js="this"` form, which compiles
  to `callFunctionOn(parent.objectId)` so the query runs against the
  parent in its own realm.

  Uses the existing browser-side bootstrap (`window.__w`) and
  `Bootstrap.register_js/4` to push-register a query. When the
  bootstrap fires `__wallabidi(...)` with the matching query id,
  V2.Session resolves the waiter; we then fetch real CDP `objectId`s
  for the matched elements via `Runtime.getProperties` against the
  stored `window.__w.queries[id].elements` array.

  Returns `{:ok, [%Wallabidi.Element{}]}` with real `bidi_shared_id`
  fields populated.
  """
  @spec find_elements(Session.t() | Element.t(), Wallabidi.Query.t(), keyword) ::
          {:ok, [Element.t()]} | {:error, term}
  def find_elements(parent, %Wallabidi.Query{} = query, opts \\ []) do
    session = Element.root_session(parent)
    timeout = Keyword.get(opts, :timeout, 5_000)
    count = Wallabidi.Query.count(query)

    with {:ok, ops, _validated} <- Ops.from_wallaby(parent, query, nil) do
      query_id = "v2-q-#{System.unique_integer([:positive])}"
      ops_json = Jason.encode!(ops.ops)
      count_js = if is_integer(count), do: Integer.to_string(count), else: "null"
      root_js = if ops.parent_id, do: "this", else: "null"
      register_js = Bootstrap.register_js(query_id, ops_json, count_js, root_js)

      :ok = V2Session.register_find(session, query_id, timeout)

      # Fire-and-forget: register the query and call W.check(). For
      # element-scoped searches we use Runtime.callFunctionOn so the
      # bootstrap's `this` is the parent element. Document-level
      # searches use plain Runtime.evaluate.
      _ =
        if ops.parent_id do
          cdp_send(session, "Runtime.callFunctionOn", %{
            objectId: ops.parent_id,
            functionDeclaration: "function() { #{register_js} }",
            returnByValue: true
          })
        else
          # Thread the active frame's executionContextId so find runs
          # inside the focused iframe (set via focus_frame_by_id).
          base = %{expression: register_js, returnByValue: true}

          params =
            case V2Session.current_context_id(session) do
              nil -> base
              ctx -> Map.put(base, :contextId, ctx)
            end

          cdp_send(session, "Runtime.evaluate", params)
        end

      case V2Session.await_find_result(session, query_id, timeout) do
        {:ok, found_count, _meta} when found_count > 0 ->
          fetch_element_refs(session, query_id, found_count)

        {:ok, _, _} ->
          {:ok, []}

        {:error, :invalid_selector} ->
          {:error, :invalid_selector}

        {:timeout, _} ->
          # Push didn't fire (count-shape mismatch, etc). Do a final
          # sync exec so callers like Browser.find can see the *actual*
          # element count for error messaging ("but 5"). Mirrors the
          # legacy CDPClient.find_elements_ops timeout fallback.
          final_sync_exec(session, ops_json, ops.parent_id)
      end
    end
  end

  defp final_sync_exec(%Session{} = session, ops_json, parent_id) do
    # When the original query was scoped to a parent element, run the
    # final exec via callFunctionOn so `this` is the parent — keeping
    # the scoping intent intact. Document scope passes null root so
    # the bootstrap's `ctx = root || document` falls through to
    # document. Threads the focused iframe's executionContextId so
    # the fallback runs in the same realm as the original query.
    eval_result =
      if parent_id do
        cdp_send(session, "Runtime.callFunctionOn", %{
          objectId: parent_id,
          functionDeclaration:
            "function() { return window.__w ? window.__w.exec(#{ops_json}, this).els : []; }",
          returnByValue: false
        })
      else
        base = %{
          expression: "(window.__w ? window.__w.exec(#{ops_json}, null).els : [])",
          returnByValue: false
        }

        params =
          case V2Session.current_context_id(session) do
            nil -> base
            ctx -> Map.put(base, :contextId, ctx)
          end

        cdp_send(session, "Runtime.evaluate", params)
      end

    with {:ok, ev} <- eval_result,
         {:ok, array_id} when is_binary(array_id) <-
           ResponseParser.extract_object_id({:ok, ev}),
         {get_method, get_params} = Commands.get_properties(array_id),
         {:ok, props_result} <- cdp_send(session, get_method, get_params),
         {:ok, ids} <- ResponseParser.extract_element_ids({:ok, props_result}) do
      _ = cdp_send(session, "Runtime.releaseObject", %{objectId: array_id})

      elements =
        Enum.map(ids, fn object_id ->
          %Element{
            id: object_id,
            bidi_shared_id: object_id,
            parent: session,
            driver: session.driver,
            url: session.session_url
          }
        end)

      {:ok, elements}
    else
      _ -> {:ok, []}
    end
  end

  # After the bootstrap reports the count, look up the matched
  # elements array by query_id and walk it via Runtime.getProperties
  # to extract real CDP objectIds. Falls back to count-shaped
  # placeholder elements if the array is gone (page navigated, etc.).
  defp fetch_element_refs(%Session{} = session, query_id, found_count) do
    id_js = Jason.encode!(query_id)
    grab_js = "window.__w.queries[#{id_js}].elements"

    with {:ok, eval_result} <-
           cdp_send(session, "Runtime.evaluate", %{
             expression: grab_js,
             returnByValue: false
           }),
         {:ok, array_id} when is_binary(array_id) <-
           ResponseParser.extract_object_id({:ok, eval_result}),
         {get_method, get_params} = Commands.get_properties(array_id),
         {:ok, props_result} <- cdp_send(session, get_method, get_params),
         {:ok, ids} <- ResponseParser.extract_element_ids({:ok, props_result}) do
      # Best-effort cleanup: drop the stored array so memory/refs don't
      # accumulate. Failures here are harmless.
      _ = cdp_send(session, "Runtime.releaseObject", %{objectId: array_id})

      elements =
        Enum.map(ids, fn object_id ->
          %Element{
            id: object_id,
            bidi_shared_id: object_id,
            parent: session,
            driver: session.driver,
            url: session.session_url
          }
        end)

      {:ok, elements}
    else
      _ ->
        # Page navigated mid-flight or array gone — return placeholders
        # so callers see a non-empty count, but downstream ops on these
        # elements will fail (no objectId). The browser-driver layer
        # decides how to handle that (retry, etc.).
        {:ok, List.duplicate(%Element{parent: session, driver: session.driver}, found_count)}
    end
  end

  # ----- Page introspection -----

  @doc """
  Returns the page's current URL (`window.location.href`) as a string.
  """
  @spec current_url(Session.t()) :: {:ok, String.t()} | {:error, term}
  def current_url(%Session{} = session) do
    evaluate(session, "location.href")
  end

  @doc """
  Returns the page's current path (the URL's path component, defaulting
  to `"/"`).
  """
  @spec current_path(Session.t()) :: {:ok, String.t()} | {:error, term}
  def current_path(%Session{} = session) do
    case current_url(session) do
      {:ok, url} -> {:ok, URI.parse(url).path || "/"}
      error -> error
    end
  end

  @doc """
  Returns the page's `<title>` text.
  """
  @spec page_title(Session.t()) :: {:ok, String.t()} | {:error, term}
  def page_title(%Session{} = session) do
    evaluate(session, "document.title")
  end

  @doc """
  Returns the page's full HTML source (`document.documentElement.outerHTML`).
  """
  @spec page_source(Session.t()) :: {:ok, String.t()} | {:error, term}
  def page_source(%Session{} = session) do
    evaluate(session, "document.documentElement.outerHTML")
  end

  # ----- Visit (navigate + await load) -----

  @doc """
  Navigates to `url` and blocks until the page's `load` lifecycle
  event has fired. Returns `:ok` or `{:error, :timeout}`.

  Convenience over `navigate/2` + `await_page_load/4` for the common
  "visit a URL and wait for it" case.

  Same-document navigations (URL fragments) don't produce a new
  loader_id — those return `:ok` immediately without waiting.
  """
  @spec visit(Session.t(), String.t(), keyword) :: :ok | {:error, term}
  def visit(%Session{} = session, url, opts \\ []) when is_binary(url) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    with {:ok, %{loader_id: loader_id}} <- navigate(session, url) do
      result =
        if is_binary(loader_id) do
          case V2Session.await_page_load(session, loader_id, "load", timeout) do
            :ok -> :ok
            :timeout -> {:error, :timeout}
          end
        else
          # Same-document nav (fragment / cached) — no loaderId, no
          # new load cycle to await.
          :ok
        end

      # Browsers without native XPath (Lightpanda) need wgxpath injected
      # after each load — `Page.addScriptToEvaluateOnNewDocument` runs
      # before page scripts, but the polyfill must run AFTER document
      # parsing to attach properly.
      if result == :ok and session.capabilities[:needs_xpath_polyfill] do
        inject_xpath_polyfill(session)
      end

      result
    end
  end

  @xpath_polyfill_path Path.join(:code.priv_dir(:wallabidi), "cdp/wgxpath.install.js")
  @external_resource @xpath_polyfill_path
  @xpath_polyfill if File.exists?(@xpath_polyfill_path),
                    do: File.read!(@xpath_polyfill_path) <> "\nwgxpath.install(window);",
                    else: ""

  defp inject_xpath_polyfill(%Session{} = session) do
    cdp_send(session, "Runtime.evaluate", %{
      expression: @xpath_polyfill,
      returnByValue: true
    })

    :ok
  end

  # ----- Runtime.evaluate -----

  @doc """
  Runs a JS expression in the page's main realm and returns the
  serialised value. Equivalent to `Runtime.evaluate` with
  `returnByValue: true`.

  Examples:

      iex> evaluate(session, "1 + 1")
      {:ok, 2}

      iex> evaluate(session, "document.title")
      {:ok, "Wallabidi Test"}
  """
  @spec evaluate(Session.t(), String.t()) :: {:ok, term} | {:error, term}
  def evaluate(%Session{} = session, expression) when is_binary(expression) do
    evaluate_raw(session, expression)
  end

  @doc """
  Like `evaluate/2` but threads `args` into the script via
  `arguments[]`. Wraps the body so `return X` and `arguments[0]`
  references work like the user-facing `execute_script` API expects.

  When the script has no `return`/`arguments` references, this still
  works — but a bare expression like `"2 + 2"` evaluates inside a
  function with no return statement (yielding `undefined`). Callers
  who want plain expression evaluation should use `evaluate/2`.
  """
  @spec evaluate(Session.t(), String.t(), list) :: {:ok, term} | {:error, term}
  def evaluate(%Session{} = session, expression, args) when is_binary(expression) and is_list(args) do
    case encode_script_args(args) do
      {:elements, cdp_args} ->
        # Args contain WebDriver-encoded element references — pass them
        # through as real CDP objectIds via Runtime.callFunctionOn so
        # the script's `arguments[n]` is a live Element, not a JSON
        # blob. callFunctionOn needs an objectId, so use globalThis.
        evaluate_with_element_args(session, expression, cdp_args)

      {:no_elements, _} ->
        if needs_wrap?(expression, args) do
          args_json = Jason.encode!(args)
          wrapped = "(function(){#{expression}}).apply(this, #{args_json})"
          evaluate_raw(session, wrapped)
        else
          evaluate_raw(session, expression)
        end
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
          v -> %{value: v}
        end)

      {:elements, cdp_args}
    else
      {:no_elements, args}
    end
  end

  defp evaluate_with_element_args(%Session{} = session, expression, cdp_args) do
    # Wrap the script body in a function so `arguments[n]` and bare
    # `return X` work — same shape as the no-element path.
    wrapped = "function() { #{expression} }"

    with {:ok, eval_result} <-
           cdp_send(session, "Runtime.evaluate", %{
             expression: "globalThis",
             returnByValue: false
           }),
         {:ok, global_id} when is_binary(global_id) <-
           ResponseParser.extract_object_id({:ok, eval_result}) do
      result =
        cdp_send(session, "Runtime.callFunctionOn", %{
          objectId: global_id,
          functionDeclaration: wrapped,
          arguments: cdp_args,
          returnByValue: true
        })

      _ = cdp_send(session, "Runtime.releaseObject", %{objectId: global_id})

      case result do
        {:ok, %{"result" => %{"value" => v}}} -> {:ok, v}
        {:ok, %{"result" => %{"type" => "undefined"}}} -> {:ok, nil}
        {:ok, %{"exceptionDetails" => details}} -> {:error, {:js_exception, details}}
        other -> other
      end
    end
  end

  # If the script uses `return`/`arguments`, wrap. Otherwise treat as
  # an expression so `execute_script(s, "2+2", [])` returns 4 like the
  # legacy CDPClient.evaluate path.
  defp needs_wrap?(_expression, args) when args != [], do: true

  defp needs_wrap?(expression, []) do
    String.contains?(expression, "return") or String.contains?(expression, "arguments")
  end

  @doc """
  Async-script semantics: the script's last argument is a callback that
  resolves the awaited promise. Mirrors WebDriver's
  `Execute Async Script` so test code like
  `arguments[arguments.length - 1](value)` works.
  """
  @spec evaluate_async(Session.t(), String.t(), list) :: {:ok, term} | {:error, term}
  def evaluate_async(%Session{} = session, expression, args) when is_binary(expression) do
    args = args || []
    args_json = Jason.encode!(args)

    wrapped = """
    new Promise(function(__resolve, __reject) {
      try {
        (function() {
          var __args = #{args_json}.concat([__resolve]);
          (function() { #{expression} }).apply(this, __args);
        })();
      } catch (e) { __reject(e); }
    })
    """

    params =
      case V2Session.current_context_id(session) do
        nil ->
          %{expression: wrapped, returnByValue: true, awaitPromise: true}

        ctx ->
          %{expression: wrapped, returnByValue: true, awaitPromise: true, contextId: ctx}
      end

    case cdp_send(session, "Runtime.evaluate", params) do
      {:ok, %{"result" => %{"value" => value}}} -> {:ok, value}
      {:ok, %{"result" => %{"type" => "undefined"}}} -> {:ok, nil}
      {:ok, %{"exceptionDetails" => details}} -> {:error, {:js_exception, details}}
      {:ok, _} = ok -> ok
      error -> error
    end
  end

  defp evaluate_raw(%Session{} = session, expression) do
    params =
      case V2Session.current_context_id(session) do
        nil -> %{expression: expression, returnByValue: true}
        ctx -> %{expression: expression, returnByValue: true, contextId: ctx}
      end

    case cdp_send(session, "Runtime.evaluate", params) do
      {:ok, %{"result" => %{"value" => value}}} -> {:ok, value}
      {:ok, %{"result" => %{"type" => "undefined"}}} -> {:ok, nil}
      {:ok, %{"exceptionDetails" => details}} -> {:error, {:js_exception, details}}
      {:ok, _} = ok -> ok
      error -> error
    end
  end

  # ----- Element geometry -----

  @doc "Element width/height in CSS pixels via getBoundingClientRect."
  @spec element_size(Element.t()) :: {:ok, {number, number}} | {:error, term}
  def element_size(%Element{bidi_shared_id: object_id} = element) do
    session = Element.root_session(element)

    case cdp_send(session, "Runtime.callFunctionOn", %{
           objectId: object_id,
           functionDeclaration:
             "function() { var r = this.getBoundingClientRect(); return JSON.stringify([Math.round(r.width), Math.round(r.height)]); }",
           returnByValue: true
         }) do
      {:ok, %{"result" => %{"value" => json}}} ->
        case Jason.decode(json) do
          {:ok, [w, h]} -> {:ok, {w, h}}
          err -> err
        end

      err ->
        err
    end
  end

  @doc "Element top-left position in CSS pixels."
  @spec element_location(Element.t()) :: {:ok, {number, number}} | {:error, term}
  def element_location(%Element{bidi_shared_id: object_id} = element) do
    session = Element.root_session(element)

    case cdp_send(session, "Runtime.callFunctionOn", %{
           objectId: object_id,
           functionDeclaration:
             "function() { var r = this.getBoundingClientRect(); return JSON.stringify([Math.round(r.x), Math.round(r.y)]); }",
           returnByValue: true
         }) do
      {:ok, %{"result" => %{"value" => json}}} ->
        case Jason.decode(json) do
          {:ok, [x, y]} -> {:ok, {x, y}}
          err -> err
        end

      err ->
        err
    end
  end

  defp element_center(%Element{bidi_shared_id: object_id} = element) do
    session = Element.root_session(element)

    case cdp_send(session, "Runtime.callFunctionOn", %{
           objectId: object_id,
           functionDeclaration:
             "function() { var r = this.getBoundingClientRect(); return JSON.stringify({x: r.x + r.width/2, y: r.y + r.height/2}); }",
           returnByValue: true
         }) do
      {:ok, %{"result" => %{"value" => json}}} ->
        %{"x" => x, "y" => y} = Jason.decode!(json)
        {:ok, {x, y}}

      error ->
        error
    end
  end

  defp element_topleft(%Element{bidi_shared_id: object_id} = element) do
    session = Element.root_session(element)

    case cdp_send(session, "Runtime.callFunctionOn", %{
           objectId: object_id,
           functionDeclaration:
             "function() { var r = this.getBoundingClientRect(); return JSON.stringify({x: r.x, y: r.y}); }",
           returnByValue: true
         }) do
      {:ok, %{"result" => %{"value" => json}}} ->
        %{"x" => x, "y" => y} = Jason.decode!(json)
        {:ok, {x, y}}

      error ->
        error
    end
  end

  # ----- Mouse / touch -----

  @doc "Move the virtual mouse to the element's center."
  @spec hover(Element.t()) :: {:ok, nil} | {:error, term}
  def hover(%Element{} = element) do
    case element_center(element) do
      {:ok, {x, y}} ->
        put_mouse_pos(element, x, y)
        dispatch_mouse(element, "mouseMoved", x, y)

      err ->
        err
    end
  end

  @doc "Synthesize a single tap (touchStart + touchEnd) at element center."
  @spec tap(Element.t()) :: {:ok, nil} | {:error, term}
  def tap(%Element{} = element) do
    session = Element.root_session(element)

    case element_center(element) do
      {:ok, {x, y}} ->
        dispatch_touch(session, "touchStart", trunc(x), trunc(y))
        dispatch_touch(session, "touchEnd", trunc(x), trunc(y))

      err ->
        err
    end
  end

  @doc "Press a touch point at element top-left + offset."
  @spec touch_down(Session.t(), Element.t() | nil, integer, integer) ::
          {:ok, nil} | {:error, term}
  def touch_down(%Session{} = session, nil, x, y) do
    dispatch_touch(session, "touchStart", x, y)
  end

  def touch_down(%Session{}, %Element{} = element, x_offset, y_offset) do
    session = Element.root_session(element)

    case element_topleft(element) do
      {:ok, {ex, ey}} ->
        dispatch_touch(session, "touchStart", trunc(ex + x_offset), trunc(ey + y_offset))

      err ->
        err
    end
  end

  @doc "Release any active touch points."
  @spec touch_up(Session.t() | Element.t()) :: {:ok, nil}
  def touch_up(parent), do: dispatch_touch(parent, "touchEnd", 0, 0)

  @doc "Move the active touch point to absolute coordinates."
  @spec touch_move(Session.t() | Element.t(), integer, integer) :: {:ok, nil}
  def touch_move(parent, x, y), do: dispatch_touch(parent, "touchMove", x, y)

  @doc "Press a mouse button at the current cursor position."
  @spec button_down(Session.t() | Element.t(), :left | :middle | :right) :: {:ok, nil}
  def button_down(parent, button) do
    {x, y} = get_mouse_pos(parent)
    dispatch_mouse(parent, "mousePressed", x, y, button: mouse_button(button), clickCount: 1)
  end

  @doc "Release a mouse button at the current cursor position."
  @spec button_up(Session.t() | Element.t(), :left | :middle | :right) :: {:ok, nil}
  def button_up(parent, button) do
    {x, y} = get_mouse_pos(parent)
    dispatch_mouse(parent, "mouseReleased", x, y, button: mouse_button(button), clickCount: 1)
  end

  @doc "Mouse-pos-aware click: press+release at current cursor position."
  @spec click_at_cursor(Session.t() | Element.t(), :left | :middle | :right) :: {:ok, nil}
  def click_at_cursor(parent, button) do
    {x, y} = get_mouse_pos(parent)
    btn = mouse_button(button)
    dispatch_mouse(parent, "mousePressed", x, y, button: btn, clickCount: 1)
    dispatch_mouse(parent, "mouseReleased", x, y, button: btn, clickCount: 1)
  end

  @doc "Move mouse cursor by an offset from its last known position."
  @spec move_mouse_by(Session.t() | Element.t(), integer, integer) :: {:ok, nil}
  def move_mouse_by(parent, x_offset, y_offset) do
    {cx, cy} = get_mouse_pos(parent)
    nx = cx + x_offset
    ny = cy + y_offset
    put_mouse_pos(parent, nx, ny)
    dispatch_mouse(parent, "mouseMoved", nx, ny)
  end

  @doc "Double-click at the current cursor position."
  @spec double_click(Session.t() | Element.t()) :: {:ok, nil}
  def double_click(parent) do
    {x, y} = get_mouse_pos(parent)
    dispatch_mouse(parent, "mousePressed", x, y, button: "left", clickCount: 2)
    dispatch_mouse(parent, "mouseReleased", x, y, button: "left", clickCount: 2)
  end

  defp dispatch_mouse(parent, type, x, y, opts \\ []) do
    session = Element.root_session(parent)
    params = %{type: type, x: trunc(x), y: trunc(y)} |> Map.merge(Map.new(opts))
    cdp_send(session, "Input.dispatchMouseEvent", params)
    {:ok, nil}
  end

  defp dispatch_touch(parent, type, x, y) do
    session = Element.root_session(parent)
    touch_points = if type == "touchEnd", do: [], else: [%{x: x, y: y}]

    cdp_send(session, "Input.dispatchTouchEvent", %{
      type: type,
      touchPoints: touch_points
    })

    {:ok, nil}
  end

  defp put_mouse_pos(parent, x, y) do
    id = Element.root_session(parent).id
    Process.put({:v2_mouse, id}, {trunc(x), trunc(y)})
  end

  defp get_mouse_pos(parent) do
    id = Element.root_session(parent).id
    Process.get({:v2_mouse, id}, {0, 0})
  end

  defp mouse_button(:left), do: "left"
  defp mouse_button(:middle), do: "middle"
  defp mouse_button(:right), do: "right"
  defp mouse_button(other), do: to_string(other)

  @doc "True when the page is on a known blank URL (about:blank, data:,)."
  @spec blank_page?(Session.t()) :: boolean
  def blank_page?(%Session{} = session) do
    case current_url(session) do
      {:ok, url} -> url in ["data:,", "about:blank", ""]
      _ -> false
    end
  end

  # ----- Dialog handling (Page.javascriptDialogOpening) -----

  @doc """
  Spawn an inner action that opens a JavaScript dialog
  (`alert/confirm/prompt`), then accept or dismiss it. Mirrors
  `Wallabidi.ChromeCDP.handle_dialog/4`.

  `fun` must be the action that triggers the dialog (e.g. clicking
  the button that calls `alert(...)`). It runs concurrently with the
  dialog handler, since clicking the button blocks until the dialog
  is dismissed.

  Returns the dialog's message (the string passed to alert/confirm/prompt).
  """
  @spec handle_dialog(Session.t(), (Session.t() -> any), boolean, String.t() | nil) :: String.t()
  def handle_dialog(%Session{} = session, fun, accept, prompt_text \\ nil) do
    caller = self()

    # Subscribe BEFORE the action so the dialog event isn't missed.
    # Page domain must be enabled for the event to fire.
    _ = cdp_send(session, "Page.enable", %{})

    handler =
      spawn(fn ->
        # Subscribe directly at the V2.WebSocket level so the event is
        # routed straight to this handler — V2.Session normally
        # consumes events itself, but for one-shot dialog handling we
        # don't need its routing.
        ctx = session.browsing_context || :global
        :ok = WebSocket.subscribe(session.bidi_pid, "Page.javascriptDialogOpening", ctx, self())

        receive do
          {:v2_event, "Page.javascriptDialogOpening", event} ->
            msg = get_in(event, ["params", "message"]) || ""
            default = get_in(event, ["params", "defaultPrompt"])
            effective_text = prompt_text || default

            params = %{accept: accept}

            params =
              if is_binary(effective_text),
                do: Map.put(params, :promptText, effective_text),
                else: params

            _ = cdp_send(session, "Page.handleJavaScriptDialog", params)
            send(caller, {:dialog_handled, msg})
        after
          10_000 -> send(caller, {:dialog_handled, ""})
        end
      end)

    fun.(session)

    message =
      receive do
        {:dialog_handled, msg} -> msg
      after
        10_000 -> ""
      end

    _ = handler
    message
  end
end
