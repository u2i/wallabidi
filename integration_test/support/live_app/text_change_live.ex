defmodule Wallabidi.Integration.LiveApp.TextChangeLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Simulate async data loading — text changes after mount
      send(self(), :load_data)
    end

    {:ok, assign(socket, title: "Loading...", status: "pending")}
  end

  def handle_info(:load_data, socket) do
    Process.sleep(200)
    {:noreply, assign(socket, title: "Dashboard", status: "ready")}
  end

  def handle_event("change_title", %{"title" => title}, socket) do
    {:noreply, assign(socket, title: title)}
  end

  def render(assigns) do
    ~H"""
    <div id="page">
      <h1 id="title">{@title}</h1>
      <span id="status">{@status}</span>
      <button id="rename" phx-click="change_title" phx-value-title="Renamed">Rename</button>
    </div>
    """
  end
end
