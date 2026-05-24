defmodule Wallabidi.Remote.Browser.Lightpanda do
  @moduledoc false

  @behaviour Wallabidi.Remote.Browser

  @impl true
  def click_strategy, do: :simple
end
