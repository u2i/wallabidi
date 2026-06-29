defmodule Wallabidi.Remote.Drivers.LightpandaCDP do
  @moduledoc false

  # Lightpanda driver speaking CDP over the wallabidi transport stack.
  # All callback behaviour comes from `Wallabidi.Remote.Driver.Generic`;
  # only session lifecycle and the Supervisor surface live here.

  use Supervisor

  use Wallabidi.Remote.Driver.Generic

  alias Wallabidi.{Element, Metadata, Session}
  alias Wallabidi.Remote.Browser
  alias Wallabidi.Remote.CDP.Client, as: CDPClient
  alias Wallabidi.Remote.Dialogs
  alias Wallabidi.Remote.Driver.Spec
  alias Wallabidi.Remote.Frames
  alias Wallabidi.Remote.Transport
  alias Wallabidi.Remote.Transport.Protocol
  alias Wallabidi.Remote.Windows

  @driver_spec %Spec{
    browser: Browser.Lightpanda,
    wire_protocol: CDPClient,
    dialogs: Dialogs.Unsupported,
    windows: Windows.Single,
    frames: Frames.Unsupported,
    touch_scroll: nil,
    log_check_interactions?: false
  }

  # Lightpanda reports `Lightpanda/1.0` by default. We append the BEAM
  # sandbox metadata onto that so server-side requests carry the same
  # `BeamMetadata (...)` segment the Chrome driver emits — without it,
  # sandbox_shim can't find the sandbox owner and DB-backed tests crash
  # with DBConnection.OwnershipError. Lightpanda honors
  # `Network.setUserAgentOverride` (verified against the fork binary).
  @base_user_agent "Lightpanda/1.0"

  @doc false
  def driver_spec, do: @driver_spec

  # ----- Driver supervisor -----
  #
  # Starts a single shared Lightpanda binary if the package is on the
  # load path. Sessions multiplex over this binary by opening their
  # own WebSocket against its URL (Transport.PerSession). Falls back
  # to per-session binary spawn (Transport.IsolatedProcess) if no
  # shared server is running.

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @lightpanda_server Module.concat([Lightpanda, Server])
  @lightpanda_server_name __MODULE__.LightpandaServer

  # Lightpanda's --cdp-max-connections defaults to 16, which gets hit
  # at mc=16 plus a few session-isolation tests creating extra sessions.
  @cdp_max_connections 24

  @impl Supervisor
  def init(_) do
    resolve_binary_path()

    children =
      if Code.ensure_loaded?(@lightpanda_server) do
        opts = [
          name: @lightpanda_server_name,
          extra_args: [
            "--cdp-max-connections",
            Integer.to_string(@cdp_max_connections)
          ],
          wrapper_script: wrapper_script()
        ]

        [{@lightpanda_server, opts}]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Make `Wallabidi.BrowserPaths` authoritative for Lightpanda's binary
  # location, mirroring how the Chrome drivers resolve through it. We
  # translate the resolved path into `config :lightpanda, :path`, which
  # `Lightpanda.bin_path/0` honors at the top of its precedence.
  #
  # An explicitly-configured `:path` (the dev sibling checkout) wins —
  # we never overwrite it. When BrowserPaths resolves nothing (no env
  # override, no `LIGHTPANDA=` line), we leave config untouched so the
  # package's own resolution (`:install_dir` → `.browsers/`, else
  # `_build/`) applies.
  defp resolve_binary_path do
    if is_nil(Application.get_env(:lightpanda, :path)) do
      case Wallabidi.BrowserPaths.lightpanda_path() do
        {:ok, path} -> Application.put_env(:lightpanda, :path, path)
        :error -> :ok
      end
    end
  end

  @doc false
  def validate, do: :ok

  @doc false
  def cleanup_stale_sessions, do: :ok

  # ----- Session lifecycle -----

  @impl Wallabidi.Driver
  def start_session(opts \\ []) do
    case pick_transport(opts) do
      {:per_session, ws_url} ->
        start_per_session(opts, ws_url)

      {transport_mod, transport_opts} ->
        start_legacy(opts, transport_mod, transport_opts)
    end
  end

  defp start_per_session(opts, ws_url) do
    session_struct = %Session{
      id: "v2drv-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      driver: __MODULE__,
      driver_spec: @driver_spec,
      browsing_context: nil,
      capabilities: %{
        flat_session_id: true,
        # Lightpanda's JS engine doesn't ship a real document.evaluate
        # — CDPClient.visit injects wgxpath after each page load.
        needs_xpath_polyfill: true
      }
    }

    with {:ok, session} <-
           Transport.PerSession.start_session(
             ws_url: ws_url,
             session_struct: session_struct,
             owner: Keyword.get(opts, :owner, self())
           ) do
      apply_session_opts(session, opts)
      {:ok, session}
    end
  end

  defp start_legacy(opts, transport_mod, transport_opts) do
    with {:ok, acquired} <- transport_mod.acquire(transport_opts) do
      session_struct = %Session{
        id: "v2drv-#{System.unique_integer([:positive])}",
        url: "about:blank",
        session_url: "about:blank",
        driver: __MODULE__,
        driver_spec: @driver_spec,
        bidi_pid: acquired.ws_pid,
        browsing_context: acquired.session_id,
        capabilities: acquired.capabilities
      }

      with {:ok, session} <- Transport.start_session_from(acquired, session_struct, opts) do
        apply_session_opts(session, opts)
        {:ok, session}
      end
    end
  end

  # Apply post-start session options shared by both transports: the BEAM
  # sandbox metadata user-agent override (mirrors ChromeCDP) and the
  # optional window size.
  defp apply_session_opts(session, opts) do
    if metadata = Keyword.get(opts, :metadata) do
      ua = Metadata.append(@base_user_agent, metadata)
      _ = CDPClient.cdp_send(session, "Network.setUserAgentOverride", %{userAgent: ua})
    end

    if window_size = Keyword.get(opts, :window_size) do
      _ = CDPClient.set_window_size(session, window_size[:width], window_size[:height])
    end

    :ok
  end

  defp pick_transport(opts) do
    base_caps = %{needs_xpath_polyfill: true}

    cond do
      url = Keyword.get(opts, :ws_url) ->
        {Transport.IsolatedProcess, [ws_url: url, extra_capabilities: base_caps]}

      Process.whereis(@lightpanda_server_name) ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        ws_url = apply(@lightpanda_server, :ws_url, [@lightpanda_server_name])
        {:per_session, ws_url}

      Code.ensure_loaded?(@lightpanda_server) ->
        {Transport.IsolatedProcess,
         [
           # credo:disable-for-next-line Credo.Check.Refactor.Apply
           spawn_fun: fn ->
             apply(@lightpanda_server, :start_link, [[name: nil, wrapper_script: wrapper_script()]])
           end,
           # credo:disable-for-next-line Credo.Check.Refactor.Apply
           url_fun: fn server -> apply(@lightpanda_server, :ws_url, [server]) end,
           extra_capabilities: base_caps
         ]}

      true ->
        raise "V2Driver requires either a :ws_url opt or the `lightpanda` package on the path"
    end
  end

  @impl Wallabidi.Driver
  def end_session(%Session{} = session) do
    Protocol.stop(session)
    :ok
  end

  # ----- Helpers -----

  defp wrapper_script do
    Path.absname("priv/run_command.sh", Application.app_dir(:wallabidi))
  end

  # ----- Per-driver overrides -----

  # Session-scoped send_keys: not supported by Lightpanda's input
  # synthesis. Element-scoped works via the Generic delegate.
  def send_keys(%Session{}, _keys), do: {:error, :not_implemented}

  def send_keys(%Element{} = element, keys),
    do: Wallabidi.Remote.Driver.Generic.send_keys(element, keys)
end
