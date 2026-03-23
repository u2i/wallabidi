defmodule Wallabidi.Integration.LiveApp.MultiElementLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, messages: ["Hello", "World"])}
  end

  def handle_event("add", _params, socket) do
    messages = socket.assigns.messages ++ ["New message"]
    {:noreply, assign(socket, messages: messages)}
  end

  def render(assigns) do
    ~H"""
    <div id="messages">
      <div :for={msg <- @messages} class="message">{msg}</div>
      <button id="add" phx-click="add">Add</button>
    </div>
    """
  end
end
