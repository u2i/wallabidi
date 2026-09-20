defmodule Wallabidi.Driver.UtilsTest do
  use ExUnit.Case, async: true

  alias Wallabidi.Driver.Utils

  describe "find_available_port/0" do
    test "returns an unused port" do
      port = Utils.find_available_port()

      assert port >= 0
      assert port <= 65535
    end
  end

  describe "merge_args/3" do
    test "appends arguments when no list arguments are configured" do
      args = ["chrome", "--headless"]
      extra_args = ["--disable-features=TranslateUI"]

      assert Utils.merge_args(args, extra_args, []) == args ++ extra_args
    end

    test "merges values for whitelisted list arguments" do
      args = [
        "--headless",
        "--enable-features=NetworkService",
        "--disable-features=TranslateUI"
      ]

      extra_args = [
        "--enable-features=NetworkServiceInProcess",
        "--disable-features=MacAppCodeSignClone",
        "--window-size=1440,900"
      ]

      assert Utils.merge_args(args, extra_args, ["enable-features", "disable-features"]) == [
               "--headless",
               "--enable-features=NetworkService,NetworkServiceInProcess",
               "--disable-features=TranslateUI,MacAppCodeSignClone",
               "--window-size=1440,900"
             ]
    end

    test "joins values without parsing or deduplicating them" do
      args = ["--enable-features=NetworkService,NetworkServiceInProcess"]
      extra_args = ["--enable-features=NetworkServiceInProcess"]

      assert Utils.merge_args(args, extra_args, ["enable-features"]) == [
               "--enable-features=NetworkService,NetworkServiceInProcess,NetworkServiceInProcess"
             ]
    end

    test "works for any whitelisted list argument" do
      args = ["--js-flags=--expose-gc"]
      extra_args = ["--js-flags=--trace-gc"]

      assert Utils.merge_args(args, extra_args, ["js-flags"]) == [
               "--js-flags=--expose-gc,--trace-gc"
             ]
    end

    test "leaves non-whitelisted arguments unchanged" do
      args = ["--headless", "--window-size=1280,800"]
      extra_args = ["--window-size=1440,900"]

      assert Utils.merge_args(args, extra_args, ["enable-features", "disable-features"]) ==
               args ++ extra_args
    end
  end
end
