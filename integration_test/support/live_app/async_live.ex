defmodule Wallabidi.Integration.LiveApp.AsyncLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, status: "idle", result: nil)}
  end

  def handle_event("load", _params, socket) do
    {:noreply,
     start_async(socket, :fetch, fn ->
       Process.sleep(300)
       "async result"
     end)}
  end

  def handle_async(:fetch, {:ok, result}, socket) do
    {:noreply, assign(socket, status: "done", result: result)}
  end

  def render(assigns) do
    ~H"""
    <div id="async-demo">
      <span id="status">{@status}</span>
      <span :if={@result} id="result">{@result}</span>
      <button id="load" phx-click="load">Load</button>
    </div>
    """
  end
end
