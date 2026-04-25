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

defmodule Wallabidi.Integration.LiveApp.SlowEventToSlowMountLive do
  # Models the teamology StudentImpersonationTest flake. The source-side
  # handle_event takes >1s (Ash action: DB write, state transitions),
  # then push_navigates to a destination whose mount is also slow (Ash
  # query loading conversation + student + character + messages under
  # sandbox ownership). The combination forces wallabidi's click path
  # through the :timeout branch: await_patch can't catch beforeunload
  # because the server hasn't fired push_navigate yet at t=1s.
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_event("start-session", _params, socket) do
    # 1.5s simulates a real Ash action (DB write + state transitions)
    # under CI load. >1s pushes await_patch past its budget so we hit
    # the :timeout branch instead of :page_navigated. Then push_navigate
    # fires, triggering beforeunload, but only after await_patch has
    # already fallen through.
    Process.sleep(1_500)
    {:noreply, push_navigate(socket, to: "/slow-evt-slow-dest-target")}
  end

  def render(assigns) do
    ~H"""
    <div id="fast-source">
      <a id="start-link" href="#" phx-click="start-session">Start Session</a>
    </div>
    """
  end
end

defmodule Wallabidi.Integration.LiveApp.SlowMountDestLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # 3s connected mount > the 1s await_page_ready_after deadline in
      # the patch-classified click branch. Without raising that deadline,
      # do_post_click returns before page_ready fires for the new mount.
      # 7s mount is past the assert_has 5s poll *and* the await_page_ready_after
      # 1s budget in the patch-classified click branch. The fix raises that
      # budget to match the navigate branch's 5s default — but even then,
      # 7s exceeds it. The real win is that `current_url` and other
      # non-polling reads return the correct page after the click.
      Process.sleep(7_000)
      {:ok, assign(socket, :ready, true)}
    else
      {:ok, assign(socket, :ready, false)}
    end
  end

  def render(assigns) do
    ~H"""
    <div id="slow-mount-dest">
      <h1 id="dest-title">Slow Mount Destination</h1>
      <input id="message-form-input" type="text" />
      <span id="ready">{if @ready, do: "ready", else: "loading"}</span>
    </div>
    """
  end
end
