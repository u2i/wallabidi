defmodule Wallabidi.Integration.LiveApp.PubSubLive do
  # Cross-session PubSub fixture. Both sessions visit /pubsub and subscribe
  # to the same topic. Session A clicks "broadcast"; session B must receive
  # the handle_info and re-render the new message.

  use Phoenix.LiveView

  @topic "pubsub_live"
  @pubsub Wallabidi.Integration.PubSub

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @topic)
    end

    {:ok, assign(socket, :message, "waiting")}
  end

  def handle_event("broadcast", _params, socket) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:new_message, "received"})
    {:noreply, socket}
  end

  def handle_info({:new_message, msg}, socket) do
    {:noreply, assign(socket, :message, msg)}
  end

  def render(assigns) do
    ~H"""
    <div id="pubsub-demo">
      <span id="message">{@message}</span>
      <button id="broadcast" phx-click="broadcast">Broadcast</button>
    </div>
    """
  end
end
