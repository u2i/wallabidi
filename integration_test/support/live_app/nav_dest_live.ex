defmodule Wallabidi.Integration.LiveApp.NavDestLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page, "destination")}
  end

  def render(assigns) do
    ~H"""
    <div id="nav-dest">
      <h1 id="dest-title">Destination Page</h1>
      <span id="dest-status">arrived</span>
    </div>
    """
  end
end
