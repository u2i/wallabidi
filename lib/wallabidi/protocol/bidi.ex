defmodule Wallabidi.Protocol.BiDi do
  @moduledoc false

  # BiDi protocol adapter. Used by the Chrome (chromedriver + BiDi) driver.

  @behaviour Wallabidi.Protocol

  alias Wallabidi.BiDi.{Commands, ResponseParser, WebSocketClient}
  alias Wallabidi.Session

  @impl true
  def eval(%Session{} = session, js) do
    context = session.browsing_context
    {method, params} = Commands.evaluate(context, js)

    session
    |> send_command(method, params)
    |> ResponseParser.extract_value()
  end

  @impl true
  def eval_async(%Session{} = session, js, timeout \\ 10_000) do
    context = session.browsing_context
    {method, params} = Commands.evaluate(context, js, %{await_promise: true})

    task =
      Task.async(fn ->
        send_command(session, method, params, timeout + 1_000)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, response} -> ResponseParser.extract_value(response)
      _ -> {:error, :timeout}
    end
  end

  @impl true
  def current_url(%Session{} = session) do
    eval(session, "window.location.href")
  end

  @impl true
  def subscribe(%Session{bidi_pid: pid}, semantic) do
    methods = wire_methods(semantic)
    subscriber = Process.get(:wallabidi_session_owner, self())

    {cmd, params} = Commands.subscribe(methods)
    WebSocketClient.send_command(pid, cmd, params)

    Enum.each(methods, &WebSocketClient.subscribe(pid, &1, subscriber))
    :ok
  end

  @impl true
  def unsubscribe(%Session{}, _semantic), do: :ok

  @impl true
  def wire_methods(:log), do: ["log.entryAdded"]
  def wire_methods(:dialog), do: ["browsingContext.userPromptOpened"]
  def wire_methods(:network_request), do: ["network.beforeRequestSent"]
  def wire_methods(:page_load), do: ["browsingContext.load"]

  defp send_command(%Session{bidi_pid: pid}, method, params, timeout \\ 10_000) do
    WebSocketClient.send_command(pid, method, params, timeout)
  end
end
