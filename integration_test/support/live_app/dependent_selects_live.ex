defmodule Wallabidi.Integration.LiveApp.DependentSelectsLive do
  # Reproduces the optimistic-UI shape from issue #67: one `phx-change`
  # form driving two dependent selects.
  #
  #   * #fast-region  — repopulated client-side by a page-local listener,
  #     synchronously in the same task as the `change` event. Its options
  #     exist before any server reply can.
  #   * #slow-region  — server-rendered from the socket assigns, so its
  #     options can only change after the round-trip completes.
  #
  # With `Wallabidi.LiveView.set_latency/2` holding the reply, a test can
  # assert the fast select updated while the slow one has not — which is
  # exactly what the latency simulator has to honour for the distinction
  # to be provable.

  use Phoenix.LiveView

  @regions %{
    "CA" => ["Ontario", "Quebec"],
    "US" => ["California", "Texas"]
  }

  def mount(_params, _session, socket) do
    {:ok, assign(socket, country: "US", regions: @regions["US"])}
  end

  def handle_event("change_country", %{"country" => country}, socket) do
    {:noreply, assign(socket, country: country, regions: Map.get(@regions, country, []))}
  end

  def render(assigns) do
    ~H"""
    <div id="dependent-selects">
      <h1>Dependent Selects</h1>

      <form phx-change="change_country">
        <select id="country" name="country">
          <option value="US" selected={@country == "US"}>United States</option>
          <option value="CA" selected={@country == "CA"}>Canada</option>
        </select>
      </form>

      <%!-- Client-owned: phx-update="ignore" so LV won't reconcile it
            away while we're observing the optimistic phase. --%>
      <select id="fast-region" phx-update="ignore">
        <option :for={region <- @regions} value={region}>{region}</option>
      </select>

      <%!-- Server-owned: only changes after the round-trip. --%>
      <select id="slow-region">
        <option :for={region <- @regions} value={region}>{region}</option>
      </select>
    </div>
    <script>
      (function() {
        var REGIONS = {"CA": ["Ontario", "Quebec"], "US": ["California", "Texas"]};
        var country = document.getElementById("country");
        var fast = document.getElementById("fast-region");
        if (!country || !fast) return;

        // Synchronous, same-task repopulation — no server involvement.
        country.addEventListener("change", function() {
          var names = REGIONS[country.value] || [];
          fast.innerHTML = "";
          names.forEach(function(name) {
            var opt = document.createElement("option");
            opt.value = name;
            opt.textContent = name;
            fast.appendChild(opt);
          });
        });
      })();
    </script>
    """
  end
end
