defmodule Wallabidi.TestApp.PriceServer do
  @moduledoc """
  A GenServer that fetches prices from an external service.

  When started with `start_supervised/1`, it inherits the caller's
  `$callers` chain so Mimic stubs propagate automatically.
  """
  use GenServer

  def start_supervised(opts \\ []) do
    callers = [self() | Process.get(:"$callers", [])]

    GenServer.start_link(__MODULE__, Keyword.put(opts, :callers, callers))
  end

  def fetch_price(pid) do
    GenServer.call(pid, :fetch_price)
  end

  @impl true
  def init(opts) do
    if callers = opts[:callers] do
      Process.put(:"$callers", callers)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call(:fetch_price, _from, state) do
    price = Wallabidi.TestApp.PriceService.fetch_price()
    {:reply, price, state}
  end
end
