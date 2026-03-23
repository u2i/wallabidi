defmodule Wallabidi.Integration.LiveApp.FullNavDestLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Slow connected mount widens the race window so tests can verify
      # that click waits for page load after full navigation
      Process.sleep(200)
      {:ok, assign(socket, lv_connected: true)}
    else
      {:ok, assign(socket, lv_connected: false)}
    end
  end

  def render(assigns) do
    ~H"""
    <div id="full-nav-dest">
      <h1 id="full-dest-title">Full Nav Destination</h1>
      <span id="full-lv-connected">{if @lv_connected, do: "yes", else: "no"}</span>
    </div>
    """
  end
end
