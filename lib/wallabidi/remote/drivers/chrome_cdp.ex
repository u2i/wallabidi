defmodule Wallabidi.Remote.Drivers.ChromeCDP do
  @moduledoc false

  # Chrome driver over the transport stack — one shared WebSocket per BEAM
  # (held by `Chrome.SharedConnection`), per-session BrowserContext +
  # Target + sessionId for routing.
  #
  # All callback behaviour comes from `Wallabidi.Remote.Driver.Generic`,
  # which dispatches via `session.driver_spec` (stamped by start_session).
  # Only the lifecycle (start/end_session) and the Supervisor surface
  # live here.

  use Supervisor

  use Wallabidi.Remote.Driver.Generic

  alias Wallabidi.{DependencyError, Metadata, Session}
  alias Wallabidi.Remote.{Browser, Transport, WebSocket}
  alias Wallabidi.Remote.CDP.Client, as: CDPClient
  alias Wallabidi.Remote.Chrome.Server, as: ChromeServer
  alias Wallabidi.Remote.Chrome.SharedConnection
  alias Wallabidi.Remote.Dialogs
  alias Wallabidi.Remote.Driver.Spec
  alias Wallabidi.Remote.Frames
  alias Wallabidi.Remote.Transport.Protocol
  alias Wallabidi.Remote.Windows

  @driver_spec %Spec{
    browser: Browser.Chrome,
    wire_protocol: CDPClient,
    dialogs: Dialogs.ChromeCDP,
    windows: Windows.ChromeCDP,
    frames: Frames.ChromeCDP,
    touch_scroll: &__MODULE__.touch_scroll_impl/3,
    log_check_interactions?: true
  }

  @doc false
  def driver_spec, do: @driver_spec

  @base_user_agent "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"

  # ----- Supervisor -----

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl Supervisor
  def init(_) do
    children =
      if remote_url() do
        [SharedConnection]
      else
        [{ChromeServer, [name: __MODULE__.Server]}, SharedConnection]
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def validate do
    cond do
      remote_url() ->
        :ok

      chrome_available?() ->
        :ok

      true ->
        {:error,
         DependencyError.exception(
           "Chrome not found. Run `mix wallabidi.install` or set WALLABIDI_CHROME_URL."
         )}
    end
  end

  @doc false
  def cleanup_stale_sessions, do: :ok

  # ----- Session lifecycle -----

  @impl Wallabidi.Driver
  def start_session(opts \\ []) do
    caller = Keyword.get(opts, :owner, self())

    with {:ok, acquired} <-
           Transport.SharedWS.acquire(connection: SharedConnection, driver: __MODULE__) do
      user_caps = Keyword.get(opts, :capabilities, %{})

      session_struct = %Session{
        id: "v2-chrome-#{System.unique_integer([:positive])}",
        url: "about:blank",
        session_url: "about:blank",
        driver: __MODULE__,
        driver_spec: @driver_spec,
        bidi_pid: acquired.ws_pid,
        browsing_context: acquired.session_id,
        capabilities: Map.merge(user_caps, acquired.capabilities)
      }

      with {:ok, session} <-
             Transport.start_session_from(acquired, session_struct, owner: caller) do
        # Forward console + exception events to the test caller's mailbox
        # so LogChecker.check_logs! can drain them after each operation.
        _ =
          WebSocket.subscribe(
            acquired.ws_pid,
            "Runtime.consoleAPICalled",
            acquired.session_id,
            caller
          )

        _ =
          WebSocket.subscribe(
            acquired.ws_pid,
            "Runtime.exceptionThrown",
            acquired.session_id,
            caller
          )

        if metadata = Keyword.get(opts, :metadata) do
          ua = Metadata.append(@base_user_agent, metadata)
          _ = CDPClient.cdp_send(session, "Network.setUserAgentOverride", %{userAgent: ua})
        end

        if window_size = Keyword.get(opts, :window_size) do
          _ = CDPClient.set_window_size(session, window_size[:width], window_size[:height])
        end

        {:ok, session}
      end
    end
  end

  @impl Wallabidi.Driver
  def end_session(%Session{} = session) do
    Protocol.stop(session)
    :ok
  end

  # ----- Per-driver overrides -----

  # Session-scoped send_keys (Chrome sends real keystrokes via CDP).
  # Element-scoped send_keys comes from `use Generic`.
  def send_keys(%Session{} = session, keys) when is_list(keys),
    do: CDPClient.send_keys_to_session(session, keys)

  def send_keys(%Session{} = session, key) when is_binary(key) or is_atom(key),
    do: CDPClient.send_keys_to_session(session, [key])

  # The Generic-injected send_keys/2 for Element is shadowed by the
  # clauses above when the first arg is a Session; for Element we keep
  # the generic delegate.
  def send_keys(%Wallabidi.Element{} = element, keys),
    do: Wallabidi.Remote.Driver.Generic.send_keys(element, keys)

  # touch_scroll uses CDP's Input.synthesizeScrollGesture — referenced
  # via @driver_spec.touch_scroll.
  @doc false
  def touch_scroll_impl(%Wallabidi.Element{} = element, x_offset, y_offset) do
    session = Wallabidi.Element.root_session(element)

    case CDPClient.element_location(element) do
      {:ok, _} ->
        CDPClient.cdp_send(session, "Input.synthesizeScrollGesture", %{
          x: 0,
          y: 0,
          xDistance: -x_offset,
          yDistance: -y_offset
        })

        {:ok, nil}

      err ->
        err
    end
  end

  # parse_log: Chrome.Logger raises Wallabidi.JSError on SEVERE entries
  # and prints console output, which is exactly what JSErrorsTest checks
  # for. The Generic-injected parse_log/1 routes here via session.driver,
  # so we override the generic stub.
  defdelegate parse_log(log), to: Wallabidi.Remote.Chrome.Logger

  # ----- Internal -----

  @doc false
  def remote_url do
    Wallabidi.BrowserPaths.chrome_url() ||
      Application.get_env(:wallabidi, :chrome_cdp_v2, []) |> Keyword.get(:remote_url)
  end

  defp chrome_available? do
    match?({:ok, _}, Wallabidi.BrowserPaths.chrome_path())
  end
end
