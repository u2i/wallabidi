defmodule Wallabidi.Remote.Browser.Chrome do
  @moduledoc false

  @behaviour Wallabidi.Remote.Browser

  @impl true
  def click_strategy, do: :classified
end
