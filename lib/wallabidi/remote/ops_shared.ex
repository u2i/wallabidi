defmodule Wallabidi.Remote.OpsShared do
  @moduledoc false

  # Shared op bodies between CDPClient and BiDiClient.
  #
  # Each function here is a JS-on-element shim that already has an
  # identical implementation in both clients today. The shared
  # versions delegate the actual wire call to the using module via
  # `unquote(__MODULE__).call_on_element/4` etc — so each client
  # keeps its own protocol-specific wire layer, but the orchestration
  # / JS bodies live in one place.
  #
  # ## Contract
  #
  # Modules that `use Wallabidi.Remote.OpsShared` must export:
  #
  #   * `call_on_element(session, element, fn_decl, args \\ [])` —
  #     run `fn_decl` (a JS function expression) with `this` bound
  #     to the element. Args are positional. Returns
  #     `{:ok, deserialized_value} | {:error, :stale_reference | term}`.
  #     The {__wallabidi_stale: true} sentinel must be translated to
  #     `{:error, :stale_reference}`.
  #
  #   * `evaluate(session, expression)` and
  #     `evaluate(session, expression, args)` — evaluate JS at
  #     document scope. Returns `{:ok, deserialized_value} | {:error, term}`.
  #
  #   * `evaluate_async(session, expression)` — evaluate a JS expression
  #     that yields a Promise, returning the resolved value.

  alias Wallabidi.{Element, Session}

  @xpath_polyfill_path Path.join(:code.priv_dir(:wallabidi), "cdp/wgxpath.install.js")
  @external_resource @xpath_polyfill_path
  @xpath_polyfill if File.exists?(@xpath_polyfill_path),
                    do: File.read!(@xpath_polyfill_path) <> "\nwgxpath.install(window);",
                    else: ""

  @doc false
  # Returns the wgxpath polyfill JS bundle. Lightpanda (and any other
  # browser that doesn't ship a real `document.evaluate`) needs this
  # injected after each page load. Callers gate this on
  # `session.capabilities[:needs_xpath_polyfill]`.
  def xpath_polyfill_js, do: @xpath_polyfill

  # Single dispatch function — the Elixir side never ships per-op JS
  # bodies; just an opcode-list. Implementations live in
  # priv/wallabidi.js as the W.run interpreter (W.text, W.attribute,
  # etc. are the underlying primitives that W.run dispatches to).
  #
  # Wire shape: `[[op_name, arg1, arg2, ...]]` — a list of ops, each
  # encoded as `[name | args]`. Element-scoped: `this` is the element.
  @dispatch_fn "function(ops){return window.__w.run(ops,this);}"

  @doc false
  def dispatch_fn, do: @dispatch_fn

  @doc false
  # Builds the JS expression for a trivia accessor: prefers W.run when
  # the bootstrap is installed, falls back to a native expression
  # otherwise (e.g. on about:blank before any page has loaded).
  def trivia_js(op, native_fallback) when is_binary(op) and is_binary(native_fallback) do
    "(window.__w && window.__w.run([['" <> op <> "']])) || " <> native_fallback
  end

  # The injected `quote do` block is intentionally long — each clause
  # is a thin protocol-agnostic op body shared between CDP and BiDi.
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      @doc "Returns the element's visible text content."
      @spec text(Session.t(), Element.t()) :: {:ok, String.t()} | {:error, term}
      def text(%Session{} = session, %Element{} = element) do
        call_on_element(session, element, unquote(@dispatch_fn), [[["text"]]])
      end

      @doc """
      Returns the value of a named attribute on the element, or `nil`
      if not set. Treats `value`, `checked`, and `selected` specially
      — those map to live DOM properties rather than HTML attributes.
      Returns `{:error, :stale_reference}` for detached nodes.
      """
      @spec attribute(Session.t(), Element.t(), String.t()) ::
              {:ok, String.t() | nil} | {:error, term}
      def attribute(%Session{} = session, %Element{} = element, name) when is_binary(name) do
        call_on_element(session, element, unquote(@dispatch_fn), [[["attribute", name]]])
      end

      @doc """
      Returns whether the element would be considered visible to a user.

      Heuristic: must be connected to the document, must not have
      `display: none` or `visibility: hidden` ancestors, and must have
      a non-zero rect OR an offsetParent OR fixed positioning.
      `<option>` is a special case (closed selects have no layout but
      are clickable).
      """
      @spec displayed(Session.t(), Element.t()) :: {:ok, boolean} | {:error, term}
      def displayed(%Session{} = session, %Element{} = element) do
        call_on_element(session, element, unquote(@dispatch_fn), [[["displayed"]]])
      end

      @doc """
      Click an element. Routes through `window.__w.clickEl` (the
      bootstrap's helper) which knows how to properly trigger
      `<option>` selection + `change` events.
      """
      @spec click(Session.t(), Element.t()) :: {:ok, nil} | {:error, term}
      def click(%Session{} = session, %Element{} = element) do
        case call_on_element(session, element, unquote(@dispatch_fn), [[["click"]]]) do
          {:ok, _} -> {:ok, nil}
          err -> err
        end
      end

      @doc """
      Sets the value of an input element via the DOM and dispatches
      `input` / `change` events. Handles checkboxes, radios, options
      (within their parent `<select>`), and text/textarea inputs.

      File inputs are NOT handled here — concrete clients override
      `set_value/3` to detect file inputs and route differently.
      """
      @spec set_value_dom(Session.t(), Element.t(), term) :: {:ok, nil} | {:error, term}
      def set_value_dom(%Session{} = session, %Element{} = element, value) do
        case call_on_element(session, element, unquote(@dispatch_fn), [[["set_value_dom", value]]]) do
          {:ok, _} -> {:ok, nil}
          err -> err
        end
      end

      @doc """
      Clears the element's value. With `silent: true` (default), no
      events are dispatched — used internally before `fill_in` to
      avoid firing `phx-change` for the intermediate empty state.
      """
      @spec clear(Session.t(), Element.t(), keyword) :: {:ok, nil} | {:error, term}
      def clear(%Session{} = session, %Element{} = element, opts \\ []) do
        silent? = Keyword.get(opts, :silent, true)

        case call_on_element(session, element, unquote(@dispatch_fn), [[["clear", silent?]]]) do
          {:ok, _} -> {:ok, nil}
          err -> err
        end
      end

      @doc """
      Fast-path send_keys for text-only input. Concatenates `text`
      onto the element's existing value and dispatches `input` /
      `change` events.

      For mixed text + special-key atoms (`:enter`, `:tab`, ...),
      concrete clients override `send_keys/3` and dispatch via the
      protocol's key event mechanism.
      """
      @spec send_keys_text(Session.t(), Element.t(), String.t()) ::
              {:ok, nil} | {:error, term}
      def send_keys_text(%Session{} = session, %Element{} = element, text) when is_binary(text) do
        case call_on_element(session, element, unquote(@dispatch_fn), [[["send_keys_text", text]]]) do
          {:ok, _} -> {:ok, nil}
          err -> err
        end
      end

      @doc """
      Toggle a checkbox or radio button to match `target`. Reads current
      `.checked` / `.selected` state and clicks only when it differs.
      One round-trip vs the legacy selected? + click two-step.
      """
      @spec set_checked(Session.t(), Element.t(), boolean) :: {:ok, nil} | {:error, term}
      def set_checked(%Session{} = session, %Element{} = element, target)
          when is_boolean(target) do
        case call_on_element(session, element, unquote(@dispatch_fn), [[["set_checked", target]]]) do
          {:ok, _} -> {:ok, nil}
          err -> err
        end
      end

      @doc """
      Classify what kind of LiveView interaction this element represents
      for an upcoming `:click` or `:change`. See `W.classify` in
      priv/wallabidi.js — returns one of `"patch"`, `"navigate"`,
      `"full_page"`, or `"none"`.
      """
      @spec classify(Session.t(), Element.t(), :click | :change) ::
              {:ok, String.t()} | {:error, term}
      def classify(%Session{} = session, %Element{} = element, interaction)
          when interaction in [:click, :change] do
        call_on_element(session, element, unquote(@dispatch_fn), [
          [["classify", Atom.to_string(interaction)]]
        ])
      end

      @doc """
      Fused fill_in: silent clear + set_value + (optionally) drainPatches
      in one V8 call. `drain_idle_ms > 0` triggers a post-fill wait for
      LiveView patches to settle. Saves up to two round-trips vs the
      legacy element-op-per-step.

      File inputs are NOT handled here — concrete clients override
      `set_value/3` to detect file inputs and route differently.
      """
      @spec fill_in(Session.t(), Element.t(), String.t() | number, non_neg_integer) ::
              {:ok, nil} | {:error, term}
      def fill_in(%Session{} = session, %Element{} = element, value, drain_idle_ms \\ 0)
          when is_integer(drain_idle_ms) do
        str = if is_number(value), do: to_string(value), else: value
        opts = if drain_idle_ms > 0, do: [await_promise: true], else: []

        case call_on_element(
               session,
               element,
               unquote(@dispatch_fn),
               [[["fill_in", str, drain_idle_ms]]],
               opts
             ) do
          {:ok, _} -> {:ok, nil}
          err -> err
        end
      end

      @doc """
      Wait until the element's `value` (for inputs) equals the given
      target, or `timeout_ms` elapses. Returns `{:ok, true}` on match,
      `{:ok, false}` on timeout. Uses MutationObserver + onPatchEnd —
      one round-trip vs Elixir-side polling of Element.value.
      """
      @spec await_value(Session.t(), Element.t(), term, non_neg_integer) ::
              {:ok, boolean} | {:error, term}
      def await_value(%Session{} = session, %Element{} = element, target, timeout_ms \\ 5_000) do
        call_on_element(
          session,
          element,
          unquote(@dispatch_fn),
          [[["await_element_match", "value", target, timeout_ms]]],
          await_promise: true
        )
      end

      @doc """
      Wait until the element's textContent contains `text`, or
      `timeout_ms` elapses. Returns `{:ok, true}` on match,
      `{:ok, false}` on timeout. One round-trip vs Elixir-side polling
      of Element.text.
      """
      @spec await_text(Session.t(), Element.t(), String.t(), non_neg_integer) ::
              {:ok, boolean} | {:error, term}
      def await_text(%Session{} = session, %Element{} = element, text, timeout_ms \\ 5_000)
          when is_binary(text) do
        call_on_element(
          session,
          element,
          unquote(@dispatch_fn),
          [[["await_element_match", "text_contains", text, timeout_ms]]],
          await_promise: true
        )
      end

      # ----- Page introspection (shared) -----

      # Trivia accessors fall back to native expressions when window.__w
      # hasn't been installed yet (e.g. on about:blank before the
      # bootstrap preload runs). `(window.__w && window.__w.X()) || ...`
      # keeps centralization-aware callers happy without breaking the
      # blank-page case.

      @doc "Page URL via `W.run([['url']])` (location.href)."
      @spec current_url(Session.t()) :: {:ok, String.t()} | {:error, term}
      def current_url(%Session{} = session),
        do: evaluate(session, unquote(__MODULE__).trivia_js("url", "location.href"))

      @doc "Path component of the URL via `W.run([['path']])` (location.pathname)."
      @spec current_path(Session.t()) :: {:ok, String.t()} | {:error, term}
      def current_path(%Session{} = session),
        do: evaluate(session, unquote(__MODULE__).trivia_js("path", "location.pathname"))

      @doc "Page title via `W.run([['title']])` (document.title)."
      @spec page_title(Session.t()) :: {:ok, String.t()} | {:error, term}
      def page_title(%Session{} = session),
        do: evaluate(session, unquote(__MODULE__).trivia_js("title", "document.title"))

      @doc "Outer HTML via `W.run([['source']])`."
      @spec page_source(Session.t()) :: {:ok, String.t()} | {:error, term}
      def page_source(%Session{} = session),
        do:
          evaluate(
            session,
            unquote(__MODULE__).trivia_js("source", "document.documentElement.outerHTML")
          )

      @doc "True when the session's current URL is a known blank URL."
      @spec blank_page?(Session.t()) :: boolean
      def blank_page?(%Session{} = session) do
        case current_url(session) do
          {:ok, url} -> url in ["data:,", "about:blank", ""]
          _ -> false
        end
      end

      @doc """
      Set a file input's value via the DataTransfer + File trick.

      Browsers reject `el.value = "/path"` on file inputs for security
      reasons; this fabricates an empty `File` and assigns it via
      `DataTransfer`. Tests only inspect `.value` (which the browser
      exposes as `C:\\fakepath\\<basename>`), so file *contents* are
      irrelevant. When `path` doesn't exist on disk, no-ops to match
      the legacy contract.
      """
      @spec set_file_input_via_data_transfer(Session.t(), Element.t(), String.t()) ::
              {:ok, nil} | {:error, term}
      def set_file_input_via_data_transfer(%Session{} = session, %Element{} = element, path)
          when is_binary(path) do
        if File.exists?(path) do
          case call_on_element(
                 session,
                 element,
                 """
                 function(p) {
                   var dt = new DataTransfer();
                   var name = p.split('/').pop() || p.split('\\\\').pop();
                   var f = new File([''], name, {type: 'application/octet-stream'});
                   dt.items.add(f);
                   this.files = dt.files;
                   this.dispatchEvent(new Event('change', {bubbles: true}));
                   return null;
                 }
                 """,
                 [path]
               ) do
            {:ok, _} -> {:ok, nil}
            err -> err
          end
        else
          {:ok, nil}
        end
      end

      @doc "Element width/height in CSS pixels via getBoundingClientRect."
      @spec element_size(Element.t()) :: {:ok, {number, number}} | {:error, term}
      def element_size(%Element{} = element) do
        case call_on_element(Element.root_session(element), element, unquote(@dispatch_fn), [
               [["rect", "size"]]
             ]) do
          {:ok, [w, h]} -> {:ok, {w, h}}
          err -> err
        end
      end

      @doc "Element top-left position in CSS pixels."
      @spec element_location(Element.t()) :: {:ok, {number, number}} | {:error, term}
      def element_location(%Element{} = element) do
        case call_on_element(Element.root_session(element), element, unquote(@dispatch_fn), [
               [["rect", "position"]]
             ]) do
          {:ok, [x, y]} -> {:ok, {x, y}}
          err -> err
        end
      end

      @doc """
      Is the element checked (checkbox/radio) or selected (option)?
      Routes through the bootstrap so the DOM property is the source
      of truth (the `selected` attribute may not reflect later state).
      """
      @spec selected(Session.t(), Element.t()) :: {:ok, boolean} | {:error, term}
      def selected(%Session{} = session, %Element{} = element) do
        case call_on_element(session, element, unquote(@dispatch_fn), [[["is_selected"]]]) do
          {:ok, v} -> {:ok, v == true}
          err -> err
        end
      end

      @doc """
      Navigate the session to `url` and wait for `load`.

      The host module must export `navigate/2` returning
      `{:ok, %{loader_id: id_or_nil}} | {:error, term}`. When the
      navigation has no loader id (same-document / cached) we skip the
      load wait. Browsers whose JS engine lacks a real
      `document.evaluate` (Lightpanda) ask for the polyfill via
      `session.capabilities[:needs_xpath_polyfill] = true` and we
      inject wgxpath after the load completes.
      """
      @spec visit(Session.t(), String.t(), keyword) :: :ok | {:error, term}
      def visit(%Session{} = session, url, opts \\ []) when is_binary(url) do
        timeout = Keyword.get(opts, :timeout, 10_000)

        with {:ok, %{loader_id: loader_id}} <- navigate(session, url) do
          result =
            if is_binary(loader_id) do
              case Wallabidi.Remote.Transport.Protocol.await_page_load(
                     session,
                     loader_id,
                     "load",
                     timeout
                   ) do
                :ok -> :ok
                :timeout -> {:error, :timeout}
              end
            else
              :ok
            end

          if result == :ok and session.capabilities[:needs_xpath_polyfill] do
            _ = evaluate(session, unquote(__MODULE__).xpath_polyfill_js())
            :ok
          end

          result
        end
      end

      # ----- Find elements (shared across CDP and BiDi) -----
      #
      # The orchestration is identical: build the W.run opcode list,
      # encode + register the query, fire the parent-scoped IIFE, await
      # the bootstrap push, and either fetch refs eagerly or return
      # lazy handles. The protocol-specific bits (`cast_register/3`,
      # `fetch_element_refs/3`, `final_sync_exec/3`) are exported by
      # each client.

      @doc """
      Find elements matching `query`. Eager mode: each returned
      Element carries a concrete protocol-specific ref (V8 objectId
      for CDP, shared id for BiDi).
      """
      @spec find_elements(Session.t() | Element.t(), Wallabidi.Query.t(), keyword) ::
              {:ok, [Element.t()]} | {:error, term}
      def find_elements(parent, %Wallabidi.Query{} = query, opts \\ []) do
        unquote(__MODULE__).do_find_elements(__MODULE__, parent, query, opts, :eager)
      end

      @doc """
      Like `find_elements/3` but returns lazy-handle Elements that
      re-resolve via W.run on each call. Use when the elements will
      be consumed by a handful of ops and discarded.
      """
      @spec find_elements_lazy(Session.t() | Element.t(), Wallabidi.Query.t(), keyword) ::
              {:ok, [Element.t()]} | {:error, term}
      def find_elements_lazy(parent, %Wallabidi.Query{} = query, opts \\ []) do
        unquote(__MODULE__).do_find_elements(__MODULE__, parent, query, opts, :lazy)
      end

      defoverridable text: 2,
                     attribute: 3,
                     displayed: 2,
                     click: 2,
                     set_value_dom: 3,
                     clear: 2,
                     clear: 3,
                     send_keys_text: 3,
                     set_checked: 3,
                     classify: 3,
                     fill_in: 3,
                     fill_in: 4,
                     await_value: 3,
                     await_value: 4,
                     await_text: 3,
                     await_text: 4,
                     current_url: 1,
                     current_path: 1,
                     page_title: 1,
                     page_source: 1,
                     find_elements: 2,
                     find_elements: 3,
                     find_elements_lazy: 2,
                     find_elements_lazy: 3,
                     visit: 2,
                     visit: 3
    end
  end

  # ----- Shared find_elements implementation -----
  #
  # `do_find_elements/5` is the protocol-agnostic orchestration of the
  # query-register + bootstrap-push + await + ref-fetch / lazy-handle
  # flow. The calling client module supplies three protocol-specific
  # primitives via its module atom:
  #
  #   * `client.cast_register(session, parent_id, register_js)` — fire
  #     the query-register IIFE either at document scope or scoped to
  #     a parent element (`this` bound to it).
  #   * `client.fetch_element_refs(session, query_id, found_count)` —
  #     pull the materialised element refs back from the page.
  #   * `client.final_sync_exec(session, ops_json, parent_id)` —
  #     run W.run synchronously for the count-shape-mismatch fallback
  #     so callers see the actual element count for error messaging.

  alias Wallabidi.Remote.Bootstrap
  alias Wallabidi.Remote.CDP.Ops
  alias Wallabidi.Remote.Transport.Protocol

  @doc false
  @spec do_find_elements(
          module,
          Session.t() | Element.t(),
          Wallabidi.Query.t(),
          keyword,
          :eager | :lazy
        ) ::
          {:ok, [Element.t()]} | {:error, term}
  def do_find_elements(client, parent, %Wallabidi.Query{} = query, opts, mode) do
    session = Element.root_session(parent)
    timeout = Keyword.get(opts, :timeout, 5_000)
    count = Wallabidi.Query.count(query)

    with {:ok, ops, _validated} <- Ops.from_wallaby(parent, query) do
      query_id = "v2-q-#{System.unique_integer([:positive])}"
      ops_json = Jason.encode!(ops.ops)
      count_js = if is_integer(count), do: Integer.to_string(count), else: "null"
      root_js = if ops.parent_id, do: "this", else: "null"
      register_js = Bootstrap.register_js(query_id, ops_json, count_js, root_js)

      :ok = Protocol.register_find(session, query_id, timeout)
      client.cast_register(session, ops.parent_id, register_js)

      case Protocol.await_find_result(session, query_id, timeout) do
        {:ok, found, _meta} when found > 0 ->
          case mode do
            :lazy -> {:ok, lazy_elements(parent, ops.ops, found)}
            :eager -> client.fetch_element_refs(session, query_id, found)
          end

        {:ok, _, _} ->
          {:ok, []}

        {:error, :invalid_selector} ->
          {:error, :invalid_selector}

        {:timeout, _} ->
          # Push didn't fire (count-shape mismatch — e.g. query asked
          # for exactly 1 but page has 2). Run W.run synchronously so
          # callers see the actual element count for error messaging.
          client.final_sync_exec(session, ops_json, ops.parent_id)
      end
    end
  end

  @doc false
  def lazy_elements(parent, ops, count) do
    parent_id = parent_object_id(parent)
    session = Element.root_session(parent)

    Enum.map(0..(count - 1), fn idx ->
      %Element{
        handle: {:lazy, ops, idx, parent_id},
        parent: session,
        driver: session.driver,
        url: session.session_url,
        session_url: session.session_url
      }
    end)
  end

  defp parent_object_id(%Element{handle: id}) when is_binary(id), do: id
  defp parent_object_id(_), do: nil
end
