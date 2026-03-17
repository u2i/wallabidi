defmodule Wallabidi.TestApp.GreetingLive do
  use Phoenix.LiveView
  import Wallabidi.Sandbox
  wallabidi_on_mount()

  alias Wallabidi.TestApp.ExternalService

  def mount(_params, _session, socket) do
    greeting = ExternalService.fetch_greeting()
    {:ok, assign(socket, greeting: greeting)}
  end

  def render(assigns) do
    ~H"""
    <h1>Greeting</h1>
    <p id="greeting">{@greeting}</p>
    """
  end
end
