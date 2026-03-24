defmodule Wallabidi.Integration.LiveApp.JsToggleLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="js-toggle-page">
      <button id="#menu-btn" phx-click={Phoenix.LiveView.JS.toggle(to: "#menu")}>Toggle Menu</button>
      <div id="menu" style="display: none;">
        <span id="menu-content">Menu is open</span>
      </div>
    </div>
    """
  end
end
