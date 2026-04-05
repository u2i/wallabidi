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
    # Page and Runtime are always enabled at session bootstrap; only
    # enable additional domains (Network, Fetch) lazily.
    case domain_for(semantic) do
      nil -> :ok
      "Page" -> :ok
      "Runtime" -> :ok
      domain -> send_cdp(session, "#{domain}.enable", %{}, 10_000)
    end

    Enum.each(wire_methods(semantic), &WebSocketClient.subscribe(pid, &1))
    :ok
  end

  @impl true
  def unsubscribe(%Session{}, _semantic), do: :ok

  @impl true
  def wire_methods(:log),
    do: ["Runtime.consoleAPICalled", "Runtime.exceptionThrown"]

  def wire_methods(:dialog), do: ["Page.javascriptDialogOpening"]
  def wire_methods(:network_request), do: ["Network.requestWillBeSent"]
  def wire_methods(:page_load), do: ["Page.loadEventFired"]

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
