defmodule Wallabidi do
  @moduledoc """
  A concurrent feature testing library.

  ## Configuration

  Wallabidi supports the following options:

  * `:otp_app` - The name of your OTP application. This is used to check out your Ecto repos into the SQL Sandbox.
  * `:screenshot_dir` - The directory to store screenshots.
  * `:screenshot_on_failure` - if Wallabidi should take screenshots on test failures (defaults to `false`).
  * `:max_wait_time` - The amount of time that Wallabidi should wait to find an element on the page. (defaults to `3_000`)
  * `:js_errors` - if Wallabidi should re-throw JavaScript errors in elixir (defaults to true).
  * `:js_logger` - IO device where JavaScript console logs are written to. Defaults to :stdio. This option can also be set to a file or any other io device. You can disable JavaScript console logging by setting this to `nil`.
  """

  use Application

  alias Wallabidi.Session

  @doc false
  def start(_type, _args) do
    Wallabidi.Bench.Timing.setup()

    # The primary driver (the one untagged tests route to) must be
    # available — validate it and raise if not. Tag-routed drivers
    # (`@tag :browser` / `@tag :headless`) are started best-effort so a
    # single `mix test` run can route each test to the cheapest driver
    # that supports it without the consumer wiring up supervisors by hand.
    primary_mod = driver_module()

    case primary_mod.validate() do
      :ok -> :ok
      {:error, exception} -> raise exception
    end

    driver_children =
      configured_driver_modules()
      |> Enum.map(fn mod -> {mod, [name: Module.concat(mod, Supervisor)]} end)

    children = driver_children ++ [{Wallabidi.SessionStore, [name: Wallabidi.SessionStore]}]

    opts = [strategy: :one_for_one, name: Wallabidi.Supervisor]
    result = Supervisor.start_link(children, opts)

    if match?({:ok, _}, result) do
      primary_mod.cleanup_stale_sessions()
    end

    result
  end

  # The set of driver supervisor modules a single test run can route to:
  # the primary `:driver` plus the drivers `@tag :browser` / `@tag
  # :headless` tests resolve to (via the `driver_for/1` ladder). Deduped,
  # primary first.
  #
  # When `WALLABIDI_DRIVER` / `WALLABIDI_BROWSER` pins a single driver for
  # the run (per-driver CI matrices, the integration suite), tag routing
  # is disabled in `Feature.resolve_test_driver`, so we start only the
  # primary — no point booting Chrome for a Lightpanda-pinned run.
  defp configured_driver_modules do
    primary = driver_module()

    tag_routed =
      if driver_pinned_by_env?() do
        []
      else
        [driver_for(:headless), driver_for(:browser)]
        |> Enum.map(&driver_module_for/1)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == primary))
        # Non-primary drivers are best-effort: only start ones whose
        # module is loadable AND whose dependency is actually available
        # (e.g. Chrome installed). A failing one would otherwise crash the
        # whole supervision tree at boot.
        |> Enum.filter(fn mod -> module_loadable?(mod) and mod.validate() == :ok end)
      end

    [primary | tag_routed]
  end

  defp driver_pinned_by_env?, do: not is_nil(pinned_driver())

  # A tag-routed driver module is only startable if its module (and the
  # browser package behind it) is loadable — e.g. the Lightpanda driver
  # needs the `lightpanda` dep. Skip the ones that aren't there so a
  # CDP-only consumer doesn't fail to boot over an unconfigured tag route.
  defp module_loadable?(mod), do: Code.ensure_loaded?(mod)

  @type reason :: any
  @type start_session_opts :: {atom, any}

  @doc """
  Starts a browser session.

  ## Multiple sessions

  Each session runs in its own browser so that each test runs in isolation.
  Because of this isolation multiple sessions can be created for a test:

  ```
  @message_field Query.text_field("Share Message")
  @share_button Query.button("Share")
  @message_list Query.css(".messages")

  test "That multiple sessions work" do
    {:ok, user1} = Wallabidi.start_session
    user1
    |> visit("/page.html")
    |> fill_in(@message_field, with: "Hello there!")
    |> click(@share_button)

    {:ok, user2} = Wallabidi.start_session
    user2
    |> visit("/page.html")
    |> fill_in(@message_field, with: "Hello yourself")
    |> click(@share_button)

    assert user1 |> find(@message_list) |> List.last |> text == "Hello yourself"
    assert user2 |> find(@message_list) |> List.first |> text == "Hello there"
  end
  ```
  """
  @spec start_session([start_session_opts]) :: {:ok, Session.t()} | {:error, reason}
  def start_session(opts \\ []) do
    # Each Transport actor monitors its owner and runs cleanup in
    # terminate/2 when the owner dies, so we don't need on_exit hooks
    # or SessionStore monitoring for crashed-test cleanup.
    case resolve_driver(opts) do
      :live_view ->
        Wallabidi.LiveView.Driver.start_session(opts)

      :lightpanda ->
        Wallabidi.Remote.Drivers.LightpandaCDP.start_session(opts)

      :chrome_cdp ->
        Wallabidi.Remote.Drivers.ChromeCDP.start_session(opts)

      :chrome ->
        Wallabidi.Remote.Drivers.ChromeBiDi.start_session(opts)

      _browser ->
        Wallabidi.Remote.Drivers.ChromeCDP.start_session(opts)
    end
  end

  @doc """
  Ends a browser session.
  """
  @spec end_session(Session.t()) :: :ok | {:error, reason}
  def end_session(%Session{driver: driver} = session) do
    result = driver.end_session(session)

    # Drain any in-flight WebSocket events that arrived after session
    # teardown. Without this, :bidi_event messages linger in the test
    # process mailbox and can interfere with the next session.
    drain_bidi_events()
    result
  end

  defp drain_bidi_events do
    receive do
      {:bidi_event, _, _} -> drain_bidi_events()
    after
      0 -> :ok
    end
  end

  @doc false
  def stop(_state) do
    :ok
  end

  @doc false
  def driver_module, do: driver_module_for(primary_driver())

  @doc """
  The driver untagged tests / the app supervisor use as primary.

  A `WALLABIDI_DRIVER` / `WALLABIDI_BROWSER` env pin wins (so a pinned CI
  lane boots the right supervisor and routes every test there); otherwise
  the configured/default `:driver`.
  """
  def primary_driver do
    case pinned_driver() do
      nil -> driver_for(:default)
      driver -> driver
    end
  end

  @pinnable_drivers ~w(
    live_view
    lightpanda
    chrome_cdp
    chrome
  )

  @doc """
  The driver pinned via `WALLABIDI_DRIVER` / `WALLABIDI_BROWSER`, or `nil`.

  Raises if the env var holds an unknown driver name (loud beats a stray
  atom / silent wrong-driver run).
  """
  def pinned_driver do
    value = System.get_env("WALLABIDI_BROWSER") || System.get_env("WALLABIDI_DRIVER")

    cond do
      is_nil(value) ->
        nil

      value in @pinnable_drivers ->
        String.to_existing_atom(value)

      true ->
        raise ArgumentError,
              "WALLABIDI_DRIVER/WALLABIDI_BROWSER=#{inspect(value)} is not a known driver. " <>
                "Expected one of: #{Enum.join(@pinnable_drivers, ", ")}"
    end
  end

  @doc false
  def driver_module_for(driver) do
    case driver do
      :live_view -> Wallabidi.LiveView.Driver
      :lightpanda -> Wallabidi.Remote.Drivers.LightpandaCDP
      :chrome_cdp -> Wallabidi.Remote.Drivers.ChromeCDP
      :chrome -> Wallabidi.Remote.Drivers.ChromeBiDi
      _ -> Wallabidi.Remote.Drivers.ChromeCDP
    end
  end

  @doc """
  Resolves the driver for an untagged/default session.

  Explicit `opts[:driver]` wins; otherwise the configured default
  (`driver_for(:default)`). This is what a bare `Wallabidi.start_session/1`
  and untagged `feature` tests use.
  """
  def resolve_driver(opts \\ []) do
    Keyword.get_lazy(opts, :driver, fn -> driver_for(:default) end)
  end

  @doc """
  Resolves a driver for a capability tier, applying wallabidi's default
  ladder so the sensible path needs no configuration:

    * `:default`  — untagged tests / bare sessions. `config :driver`,
      else `:live_view` (in-process, fastest).
    * `:headless` — `@tag :headless`. `config :headless`, else
      Lightpanda when its package is available, else the `:browser`
      driver (so a Chrome-only project still runs headless tests).
    * `:browser`  — `@tag :browser`. `config :browser`, else `:chrome_cdp`.

  Each `config :wallabidi, <key>: <driver>` entry is purely an override.
  """
  def driver_for(:default), do: Application.get_env(:wallabidi, :driver, :live_view)

  def driver_for(:browser), do: Application.get_env(:wallabidi, :browser, :chrome_cdp)

  def driver_for(:headless) do
    case Application.get_env(:wallabidi, :headless) do
      nil -> if lightpanda_available?(), do: :lightpanda, else: driver_for(:browser)
      driver -> driver
    end
  end

  # The Lightpanda driver needs the `lightpanda` package (it provides the
  # binary + server). Gauge availability the same way the driver does.
  defp lightpanda_available?, do: Code.ensure_loaded?(Module.concat([Lightpanda, Server]))

  @doc false
  def screenshot_on_failure? do
    Application.get_env(:wallabidi, :screenshot_on_failure)
  end

  @doc false
  def js_errors? do
    Application.get_env(:wallabidi, :js_errors, true)
  end

  @doc false
  def js_logger do
    Application.get_env(:wallabidi, :js_logger, :stdio)
  end
end
