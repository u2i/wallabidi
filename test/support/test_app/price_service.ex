defmodule Wallabidi.TestApp.PriceService do
  @moduledoc """
  A module that can be mocked with Mimic in tests.
  Simulates an external API call.
  """
  def fetch_price do
    "$99.99"
  end
end
