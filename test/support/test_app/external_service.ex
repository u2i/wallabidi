defmodule Wallabidi.TestApp.ExternalService do
  @moduledoc """
  A module that can be mocked with Mimic in tests.
  """
  def fetch_greeting do
    "Hello from production"
  end
end
