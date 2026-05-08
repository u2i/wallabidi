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
    driver_mod = driver_module()

    case driver_mod.validate() do
      :ok -> :ok
      {:error, exception} -> raise exception
    end

    children = [
      {driver_mod, [name: Wallabidi.Driver.Supervisor]},
      {Wallabidi.SessionStore, [name: Wallabidi.SessionStore]}
    ]

    opts = [strategy: :one_for_one, name: Wallabidi.Supervisor]
    result = Supervisor.start_link(children, opts)

    if match?({:ok, _}, result) do
      driver_mod.cleanup_stale_sessions()
    end

    result
  end

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
    # SessionProcess monitors the caller and runs cleanup in terminate/2
    # when the caller dies, so we don't need on_exit hooks or SessionStore
    # monitoring for crashed-test cleanup.
    # Old driver atoms (`:chrome`, `:chrome_cdp`, `:lightpanda`) now
    # route to their V2 implementations. V1 modules (Wallabidi.Chrome,
    # ChromeCDP, Lightpanda) are slated for removal — see CHANGELOG.
    # The `_v2`-suffixed atoms remain as aliases for compatibility with
    # any caller that pinned them explicitly.
    case resolve_driver(opts) do
      :live_view -> Wallabidi.LiveViewDriver.start_session(opts)
      d when d in [:lightpanda, :lightpanda_v2] -> Wallabidi.V2Driver.start_session(opts)
      d when d in [:chrome_cdp, :chrome_cdp_v2] -> Wallabidi.V2ChromeDriver.start_session(opts)
      d when d in [:chrome, :chrome_bidi_v2] -> Wallabidi.V2BiDiDriver.start_session(opts)
      _browser -> Wallabidi.V2ChromeDriver.start_session(opts)
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
  def driver_module do
    case resolve_driver() do
      :live_view -> Wallabidi.LiveViewDriver
      d when d in [:lightpanda, :lightpanda_v2] -> Wallabidi.V2Driver
      d when d in [:chrome_cdp, :chrome_cdp_v2] -> Wallabidi.V2ChromeDriver
      d when d in [:chrome, :chrome_bidi_v2] -> Wallabidi.V2BiDiDriver
      _ -> Wallabidi.V2ChromeDriver
    end
  end

  @doc """
  Resolves which driver to use.

  Checks in order: explicit opts, application config, default (:chrome_cdp).
  """
  def resolve_driver(opts \\ []) do
    Keyword.get_lazy(opts, :driver, fn ->
      Application.get_env(:wallabidi, :driver, :chrome_cdp)
    end)
  end

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
