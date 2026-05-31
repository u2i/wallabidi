defmodule Wallabidi.Integration.LiveApp.StreamTimerLive do
  @moduledoc """
  Exercises post-mount, self-scheduled patch chains that no browser
  interaction triggers — the case that regressed in the wild
  (`stream_insert` from a `Process.send_after` chain never observed).

  Three independent signals, all kicked off at mount with no
  `connected?` guard so they run in the connected WS mount:

    * `#messages` — a `phx-update="stream"` list. Three items are
      stream-inserted one per 50ms tick. Tests that the auto-wait catches
      keyed stream inserts arriving across several unsolicited patches.

    * `#counter` — a plain assign incremented on each of 5 ticks. Tests a
      longer chain (assert on the *last* value, 5, not an intermediate).

    * `#always` — rendered at mount, present immediately (control).
  """
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream(:messages, [])
      |> assign(:pending, ["First message", "Second message", "Third message"])
      |> assign(:counter, 0)

    Process.send_after(self(), :tick, 50)
    {:ok, socket}
  end

  def handle_info(:tick, socket) do
    socket = bump_counter(socket)

    socket =
      case socket.assigns.pending do
        [] ->
          socket

        [next | rest] ->
          socket
          |> stream_insert(:messages, %{id: System.unique_integer([:positive]), text: next})
          |> assign(:pending, rest)
      end

    if socket.assigns.pending != [] or socket.assigns.counter < 5 do
      Process.send_after(self(), :tick, 50)
    end

    {:noreply, socket}
  end

  defp bump_counter(socket), do: assign(socket, :counter, socket.assigns.counter + 1)

  def render(assigns) do
    ~H"""
    <div id="messages" phx-update="stream">
      <div :for={{id, msg} <- @streams.messages} id={id}>{msg.text}</div>
    </div>
    <span id="counter">{@counter}</span>
    <button id="always">Rendered at mount</button>
    """
  end
end
