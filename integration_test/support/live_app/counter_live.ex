defmodule Wallabidi.Integration.LiveApp.CounterLive do
  use Phoenix.LiveView
  import SandboxShim
  
  sandbox_on_mount()

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

  def handle_event("very_slow_increment", _params, socket) do
    # >1s, deliberately past the click-flow's 1s patch-promise window.
    # Used to exercise the post-patch-window fallback (await_ack):
    # patch-aware flow stays close to handle_event time; simple
    # await_page_ready_after flows burn extra polling latency.
    Process.sleep(2_000)
    {:noreply, assign(socket, count: socket.assigns.count + 1, message: "very slow done")}
  end

  def render(assigns) do
    ~H"""
    <div id="counter">
      <span id="count">{@count}</span>
      <button id="inc" phx-click="increment">+</button>
      <button id="slow-inc" phx-click="slow_increment">Slow +</button>
      <button id="very-slow-inc" phx-click="very_slow_increment">Very Slow +</button>
      <span :if={@message} id="message">{@message}</span>
    </div>
    """
  end
end
