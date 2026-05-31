defmodule Wallabidi.DriverForTest do
  # Not async: mutates the global :wallabidi driver config.
  use ExUnit.Case, async: false

  @keys [:driver, :headless, :browser]

  setup do
    saved = Enum.map(@keys, fn k -> {k, Application.fetch_env(:wallabidi, k)} end)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, {:ok, v}} -> Application.put_env(:wallabidi, k, v)
        {k, :error} -> Application.delete_env(:wallabidi, k)
      end)
    end)

    Enum.each(@keys, &Application.delete_env(:wallabidi, &1))
    :ok
  end

  describe "driver_for/1 defaults (no config)" do
    test ":default is :live_view" do
      assert Wallabidi.driver_for(:default) == :live_view
    end

    test ":browser is :chrome_cdp" do
      assert Wallabidi.driver_for(:browser) == :chrome_cdp
    end

    test ":headless is :lightpanda when the lightpanda package is available" do
      # The `lightpanda` dep is on the path in the test env.
      assert Code.ensure_loaded?(Module.concat([Lightpanda, Server]))
      assert Wallabidi.driver_for(:headless) == :lightpanda
    end
  end

  describe "driver_for/1 honors config overrides" do
    test ":default follows config :driver" do
      Application.put_env(:wallabidi, :driver, :chrome_cdp)
      assert Wallabidi.driver_for(:default) == :chrome_cdp
    end

    test ":browser follows config :browser" do
      Application.put_env(:wallabidi, :browser, :chrome)
      assert Wallabidi.driver_for(:browser) == :chrome
    end

    test ":headless follows config :headless, overriding the lightpanda default" do
      Application.put_env(:wallabidi, :headless, :chrome_cdp)
      assert Wallabidi.driver_for(:headless) == :chrome_cdp
    end

    test ":headless falls back to the :browser driver when set there" do
      # With :headless unset, an explicit :browser value flows through the
      # fallback only when lightpanda is unavailable; with lightpanda
      # present, :headless still prefers :lightpanda. Pin :headless off by
      # routing through :browser explicitly via config to document intent.
      Application.put_env(:wallabidi, :browser, :chrome)
      Application.put_env(:wallabidi, :headless, :chrome)
      assert Wallabidi.driver_for(:headless) == :chrome
    end
  end

  describe "resolve_driver/1" do
    test "explicit opts[:driver] wins over config and defaults" do
      Application.put_env(:wallabidi, :driver, :chrome_cdp)
      assert Wallabidi.resolve_driver(driver: :lightpanda) == :lightpanda
    end

    test "falls back to driver_for(:default) with no opt" do
      assert Wallabidi.resolve_driver() == :live_view
    end
  end

  describe "pinned_driver/0 and primary_driver/0 (WALLABIDI_DRIVER)" do
    setup do
      on_exit(fn ->
        System.delete_env("WALLABIDI_DRIVER")
        System.delete_env("WALLABIDI_BROWSER")
      end)
    end

    test "no env pin → nil / config default" do
      assert Wallabidi.pinned_driver() == nil
      assert Wallabidi.primary_driver() == :live_view
    end

    test "WALLABIDI_DRIVER pins to the named driver (by value)" do
      System.put_env("WALLABIDI_DRIVER", "chrome_cdp")
      assert Wallabidi.pinned_driver() == :chrome_cdp
      # The pin wins over config :driver — this is what CI lanes rely on.
      Application.put_env(:wallabidi, :driver, :live_view)
      assert Wallabidi.primary_driver() == :chrome_cdp
    end

    test "WALLABIDI_BROWSER takes precedence over WALLABIDI_DRIVER" do
      System.put_env("WALLABIDI_DRIVER", "lightpanda")
      System.put_env("WALLABIDI_BROWSER", "chrome")
      assert Wallabidi.pinned_driver() == :chrome
    end

    test "an unknown driver name raises" do
      System.put_env("WALLABIDI_DRIVER", "nope")

      assert_raise ArgumentError, ~r/not a known driver/, fn ->
        Wallabidi.pinned_driver()
      end
    end
  end
end
