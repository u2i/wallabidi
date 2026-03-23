defmodule Wallabidi.Integration.LiveApp.NavDestLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Slow connected mount widens the race window so tests can verify
      # that click waits for LV connected after navigation
      Process.sleep(200)
      {:ok, assign(socket, page: "destination", lv_connected: true)}
    else
      {:ok, assign(socket, page: "destination", lv_connected: false)}
    end
  end

  def render(assigns) do
    ~H"""
    <div id="nav-dest">
      <h1 id="dest-title">Destination Page</h1>
      <span id="dest-status">arrived</span>
      <span id="lv-connected">{if @lv_connected, do: "yes", else: "no"}</span>
    </div>
    """
  end
end
