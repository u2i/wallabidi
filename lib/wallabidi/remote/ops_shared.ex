defmodule Wallabidi.Remote.OpsShared do
  @moduledoc false

  # Shared op bodies between V2.CDPClient and V2.BiDiClient.
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

  defmacro __using__(_opts) do
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

      # ----- Page introspection (shared) -----

      # Trivia accessors fall back to native expressions when window.__w
      # hasn't been installed yet (e.g. on about:blank before the
      # bootstrap preload runs). `(window.__w && window.__w.X()) || ...`
      # keeps centralization-aware callers happy without breaking the
      # blank-page case.

      @doc "Page URL via `W.run([['url']])` (location.href)."
      @spec current_url(Session.t()) :: {:ok, String.t()} | {:error, term}
      def current_url(%Session{} = session) do
        evaluate(session, "(window.__w && window.__w.run([['url']])) || location.href")
      end

      @doc "Path component of the URL via `W.run([['path']])` (location.pathname)."
      @spec current_path(Session.t()) :: {:ok, String.t()} | {:error, term}
      def current_path(%Session{} = session) do
        evaluate(session, "(window.__w && window.__w.run([['path']])) || location.pathname")
      end

      @doc "Page title via `W.run([['title']])` (document.title)."
      @spec page_title(Session.t()) :: {:ok, String.t()} | {:error, term}
      def page_title(%Session{} = session) do
        evaluate(session, "(window.__w && window.__w.run([['title']])) || document.title")
      end

      @doc "Outer HTML via `W.run([['source']])`."
      @spec page_source(Session.t()) :: {:ok, String.t()} | {:error, term}
      def page_source(%Session{} = session) do
        evaluate(
          session,
          "(window.__w && window.__w.run([['source']])) || document.documentElement.outerHTML"
        )
      end

      defoverridable text: 2,
                     attribute: 3,
                     displayed: 2,
                     click: 2,
                     set_value_dom: 3,
                     clear: 2,
                     clear: 3,
                     send_keys_text: 3,
                     current_url: 1,
                     current_path: 1,
                     page_title: 1,
                     page_source: 1
    end
  end
end
