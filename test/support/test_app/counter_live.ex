defmodule Wallabidi.TestApp.CounterLive do
  use Phoenix.LiveView
  import SandboxCase
  sandbox_on_mount()

  def mount(_params, _session, socket) do
    {:ok, assign(socket, count: 0)}
  end

  def handle_event("increment", _params, socket) do
    {:noreply, assign(socket, count: socket.assigns.count + 1)}
  end

  def render(assigns) do
    ~H"""
    <div id="counter">
      <span id="count">{@count}</span>
      <button id="inc" phx-click="increment">+</button>
    </div>
    """
  end
end
