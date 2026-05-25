defmodule Wallabidi.Integration.LiveApp.MarkerHookLive do
  # Tests phx-hook lifecycle directly. The MarkerHook (registered
  # via window.TestHooks in the page <script>) installs a capture-
  # phase click listener inside its `mounted()` callback.
  #
  # Two scenarios:
  #
  #   * Initial-render mount — the element with phx-hook="MarkerHook"
  #     is present from the first render. mounted() should fire as
  #     soon as the LV channel joins.
  #
  #   * Delayed mount — `@show_hook` starts false; clicking #toggle
  #     adds the phx-hook element. mounted() should fire on the
  #     post-update DOM patch.
  #
  # Hook side effects are written to two window globals the test can
  # read via execute_script:
  #
  #   window.__marker_mounted   (Number) — how many times mounted ran
  #   window.__marker_captured  (Number) — how many capture clicks ran
  #
  # If mounted() doesn't fire, __marker_mounted stays 0 even after the
  # channel joins. If mounted() fires but the listener doesn't pick up
  # the click, __marker_mounted moves but __marker_captured stays 0.

  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, show_hook: true, server_count: 0)}
  end

  def handle_event("bump", _params, socket) do
    {:noreply, update(socket, :server_count, &(&1 + 1))}
  end

  def handle_event("toggle-hook", _params, socket) do
    {:noreply, update(socket, :show_hook, &(not &1))}
  end

  def render(assigns) do
    ~H"""
    <div id="marker-page">
      <h1>Marker Hook</h1>

      <div :if={@show_hook} id="hook-host" phx-hook="MarkerHook">
        <button id="bump" phx-click="bump">Bump</button>
      </div>

      <button id="toggle" phx-click="toggle-hook">Toggle hook host</button>
      <span id="server-count">{@server_count}</span>
    </div>
    <script>
      window.TestHooks = window.TestHooks || {};
      window.__marker_mounted = 0;
      window.__marker_captured = 0;
      window.TestHooks.MarkerHook = {
        mounted() {
          window.__marker_mounted += 1;
          this.el.addEventListener("click", function() {
            window.__marker_captured += 1;
          }, true);
        }
      };
    </script>
    """
  end
end
