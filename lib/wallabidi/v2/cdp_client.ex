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
