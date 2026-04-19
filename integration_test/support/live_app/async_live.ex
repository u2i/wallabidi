defmodule Wallabidi.Integration.LiveApp.AsyncLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, status: "idle", result: nil, text: "idle")}
  end

  def handle_event("load", _params, socket) do
    {:noreply,
     start_async(socket, :fetch, fn ->
       Process.sleep(300)
       "async result"
     end)}
  end

  # Two-phase update: handle_event assigns :text synchronously, then
  # start_async overwrites it after a 500ms delay. Tests that click the
  # button and then assert on "Second" must wait for the async resolution,
  # not just the initial patch.
  def handle_event("two-phase", _params, socket) do
    socket =
      start_async(socket, :later, fn ->
        Process.sleep(500)
        "Second"
      end)

    {:noreply, assign(socket, :text, "First")}
  end

  def handle_async(:fetch, {:ok, result}, socket) do
    {:noreply, assign(socket, status: "done", result: result)}
  end

  def handle_async(:later, {:ok, text}, socket) do
    {:noreply, assign(socket, :text, text)}
  end

  def render(assigns) do
    ~H"""
    <div id="async-demo">
      <span id="status">{@status}</span>
      <span :if={@result} id="result">{@result}</span>
      <button id="load" phx-click="load">Load</button>
      <span id="text">{@text}</span>
      <button id="two-phase" phx-click="two-phase">Go</button>
    </div>
    """
  end
end
