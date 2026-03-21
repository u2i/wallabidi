defmodule Wallabidi.TestApp.PriceLive do
  use Phoenix.LiveView
  import SandboxShim
  sandbox_on_mount()

  alias Wallabidi.TestApp.PriceServer

  def mount(_params, _session, socket) do
    # start_supervised/1 passes $callers to the GenServer so
    # Mimic stubs and Ecto sandbox access propagate to it.
    {:ok, pid} = PriceServer.start_supervised()
    price = PriceServer.fetch_price(pid)

    {:ok, assign(socket, price: price)}
  end

  def render(assigns) do
    ~H"""
    <h1>Price</h1>
    <p id="price">{@price}</p>
    """
  end
end
