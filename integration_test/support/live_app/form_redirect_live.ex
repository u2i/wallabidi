defmodule Wallabidi.Integration.LiveApp.FormRedirectLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :submitted, false)}
  end

  def handle_event("submit", _params, socket) do
    # Redirect to a different live_session — triggers full page navigation
    {:noreply, redirect(socket, to: "/full-nav-dest")}
  end

  def render(assigns) do
    ~H"""
    <div id="form-redirect">
      <form id="redirect-form" phx-submit="submit">
        <button id="submit-btn" type="submit">Submit</button>
      </form>
    </div>
    """
  end
end
