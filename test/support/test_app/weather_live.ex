defmodule Wallabidi.TestApp.WeatherLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    if connected?(socket) do
      mock = Application.get_env(:wallabidi, :weather_module, Wallabidi.TestApp.WeatherBehaviour)
      temp = mock.get_temperature()
      {:ok, assign(socket, temperature: temp)}
    else
      {:ok, assign(socket, temperature: "Loading...")}
    end
  end

  def render(assigns) do
    ~H"""
    <h1>Weather</h1>
    <p id="temp">{@temperature}</p>
    """
  end
end
