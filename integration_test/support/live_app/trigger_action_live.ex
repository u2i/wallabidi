defmodule Wallabidi.Integration.LiveApp.TriggerActionLive do
  # Models the AshAuthentication.Phoenix two-phase sign-in pattern:
  #
  # 1. phx-submit="submit" — LiveView validates.
  # 2. On success, @trigger_action flips truthy.
  # 3. LiveView JS sees the flip and fires a native form submit to `action=`.
  # 4. The POST hits a controller that redirects to the post-auth page.
  #
  # The classifier must recognise phx-trigger-action and wait for the full
  # page load, not just the LiveView patch.

  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, trigger_action: false)}
  end

  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_action, true)}
  end

  def render(assigns) do
    ~H"""
    <div id="trigger-action-demo">
      <form
        id="ta-form"
        phx-submit="submit"
        phx-trigger-action={@trigger_action}
        action="/trigger-action-target"
        method="post"
      >
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <button id="ta-submit" type="submit">Sign in</button>
      </form>
    </div>
    """
  end
end
