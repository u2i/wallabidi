defmodule Wallabidi.Remote.WireProtocol.CDP do
  @moduledoc false

  @behaviour Wallabidi.Remote.WireProtocol

  alias Wallabidi.Remote.CDP.Client, as: CDPClient

  @impl true
  def simple_click(session, element), do: CDPClient.click(session, element)

  @impl true
  def classified_click(session, element),
    do: CDPClient.click_aware_with_classification(session, element)

  @impl true
  def current_url(session), do: CDPClient.current_url(session)
end
