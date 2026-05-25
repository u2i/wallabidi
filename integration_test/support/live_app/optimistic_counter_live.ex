defmodule Wallabidi.Integration.LiveApp.OptimisticCounterLive do
  # Models a LiveView counter with a client-side optimistic update.
  # The button has a `phx-click="increment"`. A page-local <script>
  # attaches a `click` listener that bumps the displayed count
  # immediately — before the server reply lands — by writing into the
  # `phx-update="ignore"`-wrapped <span> so LV won't blow it away
  # until reconciliation.
  #
  # When `Wallabidi.LiveView.set_latency/2` is used to slow the round-
  # trip down, tests can assert on the displayed text *during* the
  # in-flight phase, then again after `await_patch/2`.

  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :count, 0)}
  end

  def handle_event("increment", _params, socket) do
    {:noreply, assign(socket, :count, socket.assigns.count + 1)}
  end

  def render(assigns) do
    ~H"""
    <div id="optimistic-counter">
      <h1>Optimistic Counter</h1>
      <%!--
        Two spans:
          * #count — authoritative, server-rendered, LV manages it
          * #optimistic-count — phx-update="ignore", we own its text
        Tests can observe optimistic-count during the in-flight phase
        and #count after reconciliation.
      --%>
      <span id="count" data-count={@count}>{@count}</span>
      <span id="optimistic-count" phx-update="ignore" data-server={@count}>{@count}</span>
      <button id="inc" phx-click="increment">Increment</button>
    </div>
    <script>
      (function() {
        var optimisticDelta = 0;
        var btn = document.getElementById("inc");
        var optEl = document.getElementById("optimistic-count");
        var srvEl = document.getElementById("count");
        if (!btn || !optEl || !srvEl) return;

        btn.addEventListener("click", function() {
          // Phase 1: bump the optimistic span immediately.
          optimisticDelta += 1;
          var server = Number(optEl.getAttribute("data-server"));
          optEl.textContent = String(server + optimisticDelta);
        });

        // When the authoritative #count updates (server reply landed),
        // reconcile: reset the delta and re-anchor.
        new MutationObserver(function() {
          var newServer = Number(srvEl.getAttribute("data-count"));
          optimisticDelta = 0;
          optEl.setAttribute("data-server", String(newServer));
          optEl.textContent = String(newServer);
        }).observe(srvEl, {attributes: true, attributeFilter: ["data-count"], childList: true, subtree: true});
      })();
    </script>
    """
  end
end
