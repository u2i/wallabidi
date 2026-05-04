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

  # ----- Page domain enables -----

  @doc """
  Enables CDP's Page domain for the session and subscribes to
  `Page.lifecycleEvent`. After this returns, V2.Session is set up
  to resolve `await_page_load/4` calls when matching events arrive.

  Idempotent — safe to call more than once.
  """
  @spec enable_page_lifecycle_events(Session.t()) :: :ok | {:error, term}
  def enable_page_lifecycle_events(%Session{} = session) do
    with :ok <- V2Session.subscribe(session, "Page.lifecycleEvent"),
         {:ok, _} <- cdp_send(session, "Page.enable", %{}),
         {:ok, _} <-
           cdp_send(session, "Page.setLifecycleEventsEnabled", %{enabled: true}) do
      :ok
    end
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
    with :ok <- V2Session.subscribe(session, "Runtime.bindingCalled"),
         {:ok, _} <- cdp_send(session, "Runtime.enable", %{}),
         {:ok, _} <- cdp_send(session, "Runtime.addBinding", %{name: "__wallabidi"}),
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

      error ->
        error
    end
  end

  @doc "Returns the element's visible text content (`innerText` / fallback)."
  @spec text(Session.t(), Element.t()) :: {:ok, String.t()} | {:error, term}
  def text(%Session{} = session, %Element{} = element) do
    call_on_element(
      session,
      element,
      "function() { return this.innerText || this.textContent || ''; }"
    )
  end

  @doc """
  Returns the value of a named attribute on the element, or `nil` if
  not set. Treats `value`, `checked`, and `selected` specially —
  those map to live DOM properties rather than HTML attributes.
  """
  @spec attribute(Session.t(), Element.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term}
  def attribute(%Session{} = session, %Element{} = element, name) when is_binary(name) do
    call_on_element(
      session,
      element,
      """
      function(name) {
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
    case call_on_element(
           session,
           element,
           """
           function(v) {
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
    text = keys |> Enum.filter(&is_binary/1) |> Enum.join("")

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
  end

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
    case call_on_element(
           session,
           element,
           """
           function() {
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

    with {:ok, classification} <- classify(session, element, :click),
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

  # ----- Cookies -----

  @doc """
  Returns the cookies visible to the current page.
  """
  @spec cookies(Session.t()) :: {:ok, [map]} | {:error, term}
  def cookies(%Session{} = session) do
    case cdp_send(session, "Network.getCookies", %{}) do
      {:ok, %{"cookies" => cookies}} when is_list(cookies) -> {:ok, cookies}
      {:ok, _} -> {:ok, []}
      error -> error
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
    case evaluate(
           session,
           "JSON.stringify({width: window.innerWidth, height: window.innerHeight})"
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
    case cdp_send(session, "Emulation.setDeviceMetricsOverride", %{
           width: width,
           height: height,
           deviceScaleFactor: 0,
           mobile: false
         }) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
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
          cdp_send(session, "Runtime.evaluate", %{expression: register_js, returnByValue: true})
        end

      case V2Session.await_find_result(session, query_id, timeout) do
        {:ok, found_count, _meta} when found_count > 0 ->
          fetch_element_refs(session, query_id, found_count)

        {:ok, _, _} ->
          {:ok, []}

        {:error, :invalid_selector} ->
          {:error, :invalid_selector}

        {:timeout, _} ->
          {:ok, []}
      end
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
    end
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
    case cdp_send(session, "Runtime.evaluate", %{
           expression: expression,
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

      error ->
        error
    end
  end
end
