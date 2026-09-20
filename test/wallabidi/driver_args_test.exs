defmodule Wallabidi.DriverArgsTest do
  use ExUnit.Case, async: false

  alias Wallabidi.Remote.Chrome.Server, as: ChromeServer
  alias Wallabidi.Remote.Drivers.{ChromeCDP, LightpandaCDP}

  import Wallabidi.SettingsTestHelpers

  setup do
    ensure_setting_is_reset(:wallabidi, :chrome_args)
    ensure_setting_is_reset(:wallabidi, :lightpanda_args)
    Application.delete_env(:wallabidi, :chrome_args)
    Application.delete_env(:wallabidi, :lightpanda_args)
  end

  describe "Chrome CDP arguments" do
    test "uses no additional arguments by default" do
      assert chrome_server_args() == []
    end

    test "forwards configured arguments" do
      args = ["--disable-features=MacAppCodeSignClone", "--window-size=1440,900"]
      Application.put_env(:wallabidi, :chrome_args, args)

      assert chrome_server_args() == args
    end
  end

  describe "Lightpanda arguments" do
    test "forwards configured arguments" do
      Application.put_env(:wallabidi, :lightpanda_args, ["--log-level", "debug"])

      {:ok, {_supervisor_flags, children}} = LightpandaCDP.init(:ok)

      %{start: {Lightpanda.Server, :start_link, [options]}} =
        Enum.find(children, &(&1.id == Lightpanda.Server))

      assert Enum.take(Keyword.fetch!(options, :extra_args), -2) == ["--log-level", "debug"]
    end
  end

  defp chrome_server_args do
    {:ok, {_supervisor_flags, children}} = ChromeCDP.init(:ok)

    %{start: {ChromeServer, :start_link, [options]}} =
      Enum.find(children, &(&1.id == ChromeServer))

    Keyword.fetch!(options, :args)
  end
end
