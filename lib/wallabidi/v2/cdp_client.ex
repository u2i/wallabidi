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

  alias Wallabidi.Session
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
