defmodule Wallabidi.Integration.LiveApp.SlowNavDestLive do
  # Destination with a connected mount slower than the default 5s
  # await_liveview_connected deadline. Used to exercise the navigate
  # classification timeout path — confirms wallabidi propagates the
  # timeout instead of silently reporting :ok.

  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.sleep(6_000)
      {:ok, assign(socket, page: "slow-destination", lv_connected: true)}
    else
      {:ok, assign(socket, page: "slow-destination", lv_connected: false)}
    end
  end

  def render(assigns) do
    ~H"""
    <div id="slow-nav-dest">
      <h1 id="slow-dest-title">Slow Destination</h1>
      <span id="slow-lv-connected">{if @lv_connected, do: "yes", else: "no"}</span>
    </div>
    """
  end
end
