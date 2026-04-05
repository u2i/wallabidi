defmodule Wallabidi.ChromeCDP.SharedConnection do
  @moduledoc false

  # Manages a single shared WebSocket connection to Chrome's browser-level
  # debugging endpoint. All ChromeCDP sessions multiplex over this one
  # connection using CDP's flat-session protocol (sessionId in every
  # message). This matches Playwright's "one browser, many contexts" model.
  #
  # Started as a child of the ChromeCDP supervisor. Lazy-connects on first
  # `get/0` call (after ChromeServer has provided the ws_url).

  use Agent

  alias Wallabidi.BiDi.WebSocketClient

  def start_link(_opts) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  @doc "Returns the shared WebSocket pid, connecting lazily if needed."
  def get do
    Agent.get_and_update(__MODULE__, fn
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {pid, pid}
        else
          connect()
        end

      nil ->
        connect()
    end)
  end

  defp connect do
    ws_url =
      if url = remote_url() do
        url
      else
        Wallabidi.Chrome.Server.ws_url(Wallabidi.ChromeCDP.Server)
      end

    {:ok, pid} = WebSocketClient.start_link(ws_url)
    {pid, pid}
  end

  defp remote_url do
    Application.get_env(:wallabidi, :chrome_cdp, []) |> Keyword.get(:remote_url)
  end
end
