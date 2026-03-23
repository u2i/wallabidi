defmodule Wallabidi.Integration.LiveApp.NavSourceLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page, "source")}
  end

  def render(assigns) do
    ~H"""
    <div id="nav-source">
      <h1>Source Page</h1>
      <.link navigate="/nav-dest" id="go-to-dest">Go to Destination</.link>
    </div>
    """
  end
end
