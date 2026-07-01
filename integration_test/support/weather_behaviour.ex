defmodule Wallabidi.Integration.LiveApp.WeatherBehaviour do
  @callback get_temperature() :: String.t()
end
