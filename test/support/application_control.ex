defmodule Wallabidi.TestSupport.ApplicationControl do
  @moduledoc """
  Test helpers for starting/stopping wallabidi during test setup
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Stops the wallabidi application
  """
  def stop_wallabidi(_) do
    Application.stop(:wallabidi)
  end

  @doc """
  Restarts wallabidi after the current test process exits.

  This ensures wallabidi is restarted in a fresh state after
  a test that modifies wallabidi's startup config.
  """
  def restart_wallabidi_on_exit!(_) do
    on_exit(fn ->
      # Stops wallabidi if it's been started so it can be
      # restarted successfully
      Application.stop(:wallabidi)

      case Application.start(:wallabidi) do
        :ok ->
          :ok

        result ->
          flunk("failed to restart wallabidi: #{inspect(result)}")
      end
    end)
  end
end
