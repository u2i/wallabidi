defmodule Wallabidi.Remote.WireProtocol.BiDi do
  @moduledoc false

  @behaviour Wallabidi.Remote.WireProtocol

  alias Wallabidi.Remote.BiDi.Client, as: BiDiClient

  @impl true
  def simple_click(session, element), do: BiDiClient.click(session, element)

  @impl true
  def classified_click(session, element),
    do: BiDiClient.click_aware_with_classification(session, element)

  @impl true
  def current_url(session), do: BiDiClient.current_url(session)
end
