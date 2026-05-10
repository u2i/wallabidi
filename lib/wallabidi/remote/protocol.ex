defmodule Wallabidi.Remote.Protocol do
  @moduledoc false

  # Driver-agnostic dispatcher for JS evaluation and a few page-info
  # primitives. Routes to the CDP or BiDi client based on session
  # driver. Shared feature code (e.g. LiveViewAware) calls through
  # here so it doesn't have to branch on driver.

  alias Wallabidi.Session

  @type result :: {:ok, any} | {:error, any}

  @doc """
  Evaluates a JavaScript expression and returns its value (serialized
  to an Elixir term). Equivalent to BiDi `script.evaluate` or CDP
  `Runtime.evaluate` with `returnByValue: true`.
  """
  @spec eval(Session.t(), String.t()) :: result
  def eval(%Session{driver: driver} = session, js)
      when driver in [Wallabidi.Remote.Drivers.LightpandaCDP, Wallabidi.Remote.Drivers.ChromeCDP],
      do: Wallabidi.Remote.CDP.Client.evaluate(session, js)

  def eval(%Session{driver: Wallabidi.Remote.Drivers.ChromeBiDi} = session, js),
    do: Wallabidi.Remote.BiDi.Client.evaluate(session, js)

  @doc """
  Evaluates a JS expression that returns a Promise, awaits it, and
  returns the resolved value.
  """
  @spec eval_async(Session.t(), String.t(), timeout()) :: result
  def eval_async(session, js, timeout \\ 10_000)

  def eval_async(%Session{driver: driver} = session, js, _timeout)
      when driver in [Wallabidi.Remote.Drivers.LightpandaCDP, Wallabidi.Remote.Drivers.ChromeCDP] do
    case Wallabidi.Remote.CDP.Client.cdp_send(session, "Runtime.evaluate", %{
           expression: js,
           awaitPromise: true,
           returnByValue: true
         }) do
      {:ok, %{"result" => %{"value" => v}}} -> {:ok, v}
      {:ok, %{"result" => %{"type" => "undefined"}}} -> {:ok, nil}
      other -> other
    end
  end

  def eval_async(%Session{driver: Wallabidi.Remote.Drivers.ChromeBiDi} = session, js, _timeout),
    do: Wallabidi.Remote.BiDi.Client.evaluate_async(session, js)

  @doc "Returns the current page URL as a string."
  @spec current_url(Session.t()) :: result
  def current_url(%Session{driver: driver} = session)
      when driver in [Wallabidi.Remote.Drivers.LightpandaCDP, Wallabidi.Remote.Drivers.ChromeCDP],
      do: Wallabidi.Remote.CDP.Client.current_url(session)

  def current_url(%Session{driver: Wallabidi.Remote.Drivers.ChromeBiDi} = session),
    do: Wallabidi.Remote.BiDi.Client.current_url(session)
end
