defmodule Wallabidi.Chrome.Chromedriver do
  @moduledoc false

  alias Wallabidi.Chrome.Chromedriver.Server

  def child_spec(_arg) do
    chromedriver_path = Wallabidi.BrowserPaths.chromedriver_path!()
    Server.child_spec([chromedriver_path, [name: __MODULE__]])
  end

  @spec wait_until_ready(timeout()) :: :ok | {:error, :timeout}
  def wait_until_ready(timeout) do
    Server.wait_until_ready(__MODULE__, timeout)
  end

  @spec base_url :: String.t()
  def base_url do
    Server.get_base_url(__MODULE__)
  end
end
