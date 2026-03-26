defmodule Wallabidi.Integration.LiveApp.FormLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, email: "", submitted_email: nil)}
  end

  def handle_event("validate", %{"email" => email}, socket) do
    {:noreply, assign(socket, email: email)}
  end

  def handle_event("submit", %{"email" => email}, socket) do
    {:noreply, assign(socket, submitted_email: email)}
  end

  def render(assigns) do
    ~H"""
    <div id="form-page">
      <form id="email-form" phx-change="validate" phx-submit="submit">
        <input type="text" id="email" name="email" value={@email} />
        <span id="server-email">{@email}</span>
        <button id="submit-email" type="submit">Submit</button>
      </form>
      <span :if={@submitted_email} id="submitted">{@submitted_email}</span>
    </div>
    """
  end
end
