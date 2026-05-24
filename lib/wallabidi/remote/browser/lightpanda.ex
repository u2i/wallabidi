defmodule Wallabidi.Remote.Browser.Lightpanda do
  @moduledoc false

  @behaviour Wallabidi.Remote.Browser

  @impl true
  def click_strategy, do: :simple

  @impl true
  def wraps_interactions_in_log_check?, do: false
end
