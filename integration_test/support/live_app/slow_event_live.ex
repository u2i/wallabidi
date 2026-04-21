defmodule Wallabidi.Integration.LiveApp.SlowEventLive do
  # Models the teamology "Start Session" pattern: phx-click on an <a>
  # whose server handler does slow work (DB, state transitions) before
  # calling push_navigate. Under CI load, the handler takes longer than
  # wallabidi's default await_patch budget (1s), so the post-click wait
  # falls through before the redirect fires.
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :starting, false)}
  end

  def handle_event("start-session", _params, socket) do
    # Simulate slow server work: DB writes, state machine transitions.
    # 5s is > wallabidi's entire post-click budget (1s await_patch +
    # 1s await_page_ready_after) AND > the default 3s max_wait_time
    # that backs assert_has. Without the ack-based wait, the click
    # returns while the server is still processing, assert_has polls
    # for 3s finding nothing, and the test fails.
    Process.sleep(3_000)
    {:noreply, push_navigate(socket, to: "/slow-event-dest")}
  end

  def render(assigns) do
    ~H"""
    <div id="slow-event-source">
      <h1>Start Session Source</h1>
      <a id="start-link" href="#" phx-click="start-session">Start Session</a>
    </div>
    """
  end
end

defmodule Wallabidi.Integration.LiveApp.SlowEventDestLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, assign(socket, :clicked, false)}

  def handle_event("dest-click", _params, socket) do
    {:noreply, assign(socket, :clicked, true)}
  end

  def render(assigns) do
    ~H"""
    <div id="slow-event-dest">
      <h1 id="dest-title">Session Started</h1>
      <input id="message-form-input" type="text" />
      <button id="dest-btn" phx-click="dest-click">Continue</button>
      <span id="dest-clicked">{if @clicked, do: "yes", else: "no"}</span>
    </div>
    """
  end
end
