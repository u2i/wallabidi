defmodule Wallabidi.Integration.LiveApp.CaptureListenerLive do
  # Repro for the lavash optimistic-UI gap: a LiveView with phx-click
  # buttons inside a wrapper that has a vanilla capture-phase click
  # listener attached at page-load time (NOT via phx-hook, because
  # this test app doesn't wire `hooks:` into LiveSocket).
  #
  # The listener writes its count to #optimistic-count. If the click
  # propagates capture-phase down through the wrapper before bubbling
  # up to LV's document-level delegate, both `#optimistic-count`
  # (client-side) and `#server-count` (server-side) should increment.

  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :count, 0)}
  end

  def handle_event("bump", _params, socket) do
    {:noreply, assign(socket, :count, socket.assigns.count + 1)}
  end

  def render(assigns) do
    ~H"""
    <div id="wrapper">
      <h1>Capture Listener LV</h1>
      <span id="optimistic-count" phx-update="ignore">0</span>
      <span id="server-count">{@count}</span>
      <button id="bump" phx-click="bump">Bump</button>
    </div>
    <script>
      (function() {
        var optEl = document.getElementById("optimistic-count");
        var wrapper = document.getElementById("wrapper");
        if (!optEl || !wrapper) return;

        // Capture-phase listener on the wrapper — same shape as lavash's
        // LavashOptimistic hook. Should fire BEFORE LV's document-level
        // delegate gets the event.
        wrapper.addEventListener("click", function(e) {
          var target = e.target.closest("[phx-click]");
          if (!target || !wrapper.contains(target)) return;
          optEl.textContent = String(Number(optEl.textContent) + 1);
        }, true);
      })();
    </script>
    """
  end
end
