defmodule Wallabidi.Remote.Browser.Chrome do
  @moduledoc false

  @behaviour Wallabidi.Remote.Browser

  @impl true
  def click_strategy, do: :classified

  @impl true
  def wraps_interactions_in_log_check?, do: true
end
