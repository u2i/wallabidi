defmodule Wallabidi.Protocol do
  @moduledoc false

  # Protocol abstraction for the low-level operations that drivers share.
  #
  # Wallabidi currently supports two wire protocols over WebSocket:
  #
  # - **BiDi** (Chrome) — W3C WebDriver BiDi via chromedriver
  # - **CDP** (Chrome CDP, Lightpanda) — Chrome DevTools Protocol
  #
  # Higher-level features (LiveView patch awaiting, navigation lifecycle,
  # console capture, settle) only need to evaluate JavaScript, wait for
  # promises, and subscribe to semantic events. Those primitives are what
  # a protocol adapter must provide.
  #
  # Drivers set `session.protocol` to the adapter module implementing this
  # behaviour. Shared feature code calls `Protocol.eval(session, js)` etc.
  # and the adapter translates to the appropriate BiDi or CDP command.
  #
  # ## Semantic events
  #
  # Event names differ across protocols, so the abstraction uses semantic
  # names that each adapter maps to its wire-level name:
  #
  # | Semantic         | BiDi                                | CDP                           |
  # | ---------------- | ----------------------------------- | ----------------------------- |
  # | `:log`           | `log.entryAdded`                    | `Runtime.consoleAPICalled` etc |
  # | `:dialog`        | `browsingContext.userPromptOpened`  | `Page.javascriptDialogOpening` |
  # | `:network_request` | `network.beforeRequestSent`       | `Network.requestWillBeSent`   |
  # | `:page_load`     | `browsingContext.load`              | `Page.loadEventFired`         |
  #
  # Events are delivered to the subscribing process as
  # `{:protocol_event, semantic_event, raw_event_map}`.

  alias Wallabidi.Session

  @type result :: {:ok, any} | {:error, any}
  @type semantic_event :: :log | :dialog | :network_request | :page_load

  @doc """
  Evaluates a JavaScript expression and returns its value (serialized to
  an Elixir term). Equivalent to BiDi `script.evaluate` or CDP
  `Runtime.evaluate` with `returnByValue: true`.
  """
  @callback eval(Session.t(), String.t()) :: result

  @doc """
  Evaluates a JavaScript expression that returns a Promise, awaits the
  promise, and returns its resolved value. The call blocks on the
  WebSocket until the promise settles or `timeout` elapses.
  """
  @callback eval_async(Session.t(), String.t(), timeout()) :: result

  @doc """
  Returns the current page URL as a string.
  """
  @callback current_url(Session.t()) :: result

  @doc """
  Subscribes the current process to a semantic event. Enables the
  necessary protocol-level domain (if any) and registers the caller to
  receive matching wire-level events via the underlying WebSocket.

  Events arrive as `{:bidi_event, wire_method, event_map}` — the wire
  method matches what `wire_methods/1` returns.

  Implementations should be idempotent — calling subscribe twice for the
  same event and caller is harmless.
  """
  @callback subscribe(Session.t(), semantic_event) :: :ok

  @doc """
  Unsubscribes the current process from a semantic event.
  """
  @callback unsubscribe(Session.t(), semantic_event) :: :ok

  @doc """
  Returns the wire-level method names that emit events for a given
  semantic event. Consumers pattern-match on these names in their
  receive loops.

  For example, `:log` maps to `["log.entryAdded"]` in BiDi and to
  `["Runtime.consoleAPICalled", "Runtime.exceptionThrown"]` in CDP.
  """
  @callback wire_methods(semantic_event) :: [String.t()]

  @optional_callbacks subscribe: 2, unsubscribe: 2, wire_methods: 1

  # --- Dispatch helpers (call the session's protocol adapter) ---

  @spec eval(Session.t(), String.t()) :: result
  def eval(%Session{protocol: mod} = session, js) when not is_nil(mod),
    do: mod.eval(session, js)

  @spec eval_async(Session.t(), String.t(), timeout()) :: result
  def eval_async(%Session{protocol: mod} = session, js, timeout \\ 10_000)
      when not is_nil(mod),
      do: mod.eval_async(session, js, timeout)

  @spec current_url(Session.t()) :: result
  def current_url(%Session{protocol: mod} = session) when not is_nil(mod),
    do: mod.current_url(session)

  @spec subscribe(Session.t(), semantic_event) :: :ok
  def subscribe(%Session{protocol: mod} = session, event)
      when not is_nil(mod) and is_atom(event) do
    # Code.ensure_loaded?/1 is required here — function_exported?/3 returns
    # false for not-yet-loaded modules, giving a false negative.
    if Code.ensure_loaded?(mod) and function_exported?(mod, :subscribe, 2) do
      mod.subscribe(session, event)
    else
      :ok
    end
  end

  @spec unsubscribe(Session.t(), semantic_event) :: :ok
  def unsubscribe(%Session{protocol: mod} = session, event)
      when not is_nil(mod) and is_atom(event) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :unsubscribe, 2) do
      mod.unsubscribe(session, event)
    else
      :ok
    end
  end

  @spec wire_methods(Session.t(), semantic_event) :: [String.t()]
  def wire_methods(%Session{protocol: mod}, event)
      when not is_nil(mod) and is_atom(event) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :wire_methods, 1) do
      mod.wire_methods(event)
    else
      []
    end
  end
end
