defmodule Wallabidi.Integration.LiveApp.CounterLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, count: 0, message: nil)}
  end

  def handle_event("increment", _params, socket) do
    {:noreply, assign(socket, count: socket.assigns.count + 1)}
  end

  def handle_event("slow_increment", _params, socket) do
    # Simulate slow server work
    Process.sleep(500)
    {:noreply, assign(socket, count: socket.assigns.count + 1, message: "done")}
  end

  def render(assigns) do
    ~H"""
    <div id="counter">
      <span id="count">{@count}</span>
      <button id="inc" phx-click="increment">+</button>
      <button id="slow-inc" phx-click="slow_increment">Slow +</button>
      <span :if={@message} id="message">{@message}</span>
    </div>
    """
  end
end
