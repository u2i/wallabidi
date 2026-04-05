defmodule Wallabidi.Protocol.CDP do
  @moduledoc false

  # CDP protocol adapter. Used by the Lightpanda and ChromeCDP drivers.

  @behaviour Wallabidi.Protocol

  alias Wallabidi.BiDi.WebSocketClient
  alias Wallabidi.CDP.ResponseParser
  alias Wallabidi.Session

  @impl true
  def eval(%Session{} = session, js) do
    send_eval(session, js, await_promise: false)
  end

  @impl true
  def eval_async(%Session{} = session, js, timeout \\ 10_000) do
    task =
      Task.async(fn ->
        send_eval(session, js, await_promise: true, timeout: timeout + 1_000)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      _ -> {:error, :timeout}
    end
  end

  @impl true
  def current_url(%Session{} = session) do
    eval(session, "window.location.href")
  end

  @impl true
  def subscribe(%Session{bidi_pid: pid} = session, semantic) do
    # Session-scoped events (`:page_load`) are routed to the SessionProcess
    # so it can demultiplex them and drop noise without touching the test
    # process mailbox. Owner-scoped events (`:log`, `:dialog`, ...) go to
    # the calling process (typically the test process via the owner pid
    # stashed in the process dictionary by SessionProcess.init).
    subscriber =
      case semantic do
        :page_load ->
          Process.get(:wallabidi_session_process, self())

        _ ->
          Process.get(:wallabidi_session_owner, self())
      end

    # Page and Runtime are always enabled at session bootstrap; only
    # enable additional domains (Network, Fetch) lazily.
    case domain_for(semantic) do
      nil -> :ok
      "Page" -> :ok
      "Runtime" -> :ok
      domain -> send_cdp(session, "#{domain}.enable", %{}, 10_000)
    end

    # For flat-session CDP, scope subscriptions to this session's sessionId
    # so a shared WebSocket only delivers events for our target.
    session_id =
      if session.capabilities[:flat_session_id],
        do: session.browsing_context,
        else: :global

    Enum.each(wire_methods(semantic), fn method ->
      WebSocketClient.subscribe(pid, method, subscriber, session_id)
    end)

    :ok
  end

  @impl true
  def unsubscribe(%Session{bidi_pid: pid} = session, semantic) do
    subscriber = Process.get(:wallabidi_session_owner, self())

    session_id =
      if session.capabilities[:flat_session_id],
        do: session.browsing_context,
        else: :global

    Enum.each(wire_methods(semantic), fn method ->
      WebSocketClient.unsubscribe(pid, method, subscriber, session_id)
    end)

    :ok
  end

  @impl true
  def wire_methods(:log),
    do: ["Runtime.consoleAPICalled", "Runtime.exceptionThrown"]

  def wire_methods(:dialog), do: ["Page.javascriptDialogOpening"]
  def wire_methods(:network_request), do: ["Network.requestWillBeSent"]
  # Page.lifecycleEvent carries a loaderId that matches the loaderId returned
  # synchronously from Page.navigate, letting `visit/2` correlate events to
  # the specific navigation it triggered.
  def wire_methods(:page_load), do: ["Page.lifecycleEvent"]

  defp domain_for(:log), do: "Runtime"
  defp domain_for(:dialog), do: "Page"
  defp domain_for(:network_request), do: "Network"
  defp domain_for(:page_load), do: "Page"
  defp domain_for(_), do: nil

  # --- Internal ---

  defp send_eval(%Session{} = session, js, opts) do
    await_promise = Keyword.get(opts, :await_promise, false)
    timeout = Keyword.get(opts, :timeout, 10_000)

    params = %{
      expression: js,
      returnByValue: true,
      awaitPromise: await_promise
    }

    send_cdp(session, "Runtime.evaluate", params, timeout)
    |> ResponseParser.check_error()
    |> ResponseParser.extract_value()
  end

  defp send_cdp(%Session{bidi_pid: pid} = session, method, params, timeout) do
    session_id = session.browsing_context

    if session.capabilities[:flat_session_id] do
      WebSocketClient.send_command_flat(pid, method, params, session_id, timeout)
    else
      params = Map.put(params, :sessionId, session_id)
      WebSocketClient.send_command(pid, method, params, timeout)
    end
  end
end
