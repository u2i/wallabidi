defmodule Wallabidi.TestApp.WeatherLive do
  use Phoenix.LiveView
  import SandboxCase
  sandbox_on_mount()

  def mount(_params, _session, socket) do
    mock = Application.get_env(:wallabidi, :weather_module, Wallabidi.TestApp.WeatherBehaviour)
    temp = mock.get_temperature()
    {:ok, assign(socket, temperature: temp)}
  end

  def render(assigns) do
    ~H"""
    <h1>Weather</h1>
    <p id="temp">{@temperature}</p>
    """
  end
end
