defmodule Wallabidi.Remote.Drivers.ChromeBiDi do
  @moduledoc false

  # Chrome driver speaking WebDriver-BiDi against a chromium-bidi
  # Node sidecar. All callback behaviour comes from
  # `Wallabidi.Remote.Driver.Generic`; only session lifecycle and the
  # Supervisor surface live here.

  use Supervisor

  use Wallabidi.Remote.Driver.Generic

  alias Wallabidi.{Metadata, Session}
  alias Wallabidi.Remote.BiDi.Client, as: BiDiClient
  alias Wallabidi.Remote.BiDi.WebSocketClient
  alias Wallabidi.Remote.Browser
  alias Wallabidi.Remote.Dialogs
  alias Wallabidi.Remote.Driver.Spec
  alias Wallabidi.Remote.Frames
  alias Wallabidi.Remote.Transport.BiDi
  alias Wallabidi.Remote.Transport.Protocol
  alias Wallabidi.Remote.Windows

  @driver_spec %Spec{
    browser: Browser.Chrome,
    wire_protocol: BiDiClient,
    dialogs: Dialogs.ChromeBiDi,
    windows: Windows.ChromeBiDi,
    frames: Frames.ChromeBiDi,
    touch_scroll: &__MODULE__.touch_scroll_impl/3,
    log_check_interactions?: true
  }

  # Mirrors ChromeCDP's base UA. When the feature passes BEAM sandbox
  # metadata, we append it (via `Wallabidi.Metadata`) and push it with
  # BiDi's `emulation.setUserAgentOverride` so server-side requests carry
  # the `BeamMetadata (...)` segment sandbox_shim reads to find the
  # sandbox owner. Without it, DB-backed browser tests crash with
  # DBConnection.OwnershipError.
  @base_user_agent "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"

  @doc false
  def driver_spec, do: @driver_spec

  # ----- Driver supervisor -----

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

  @bidi_server_name __MODULE__.BidiServer

  @impl Supervisor
  def init(_) do
    children = [
      {Wallabidi.Remote.ChromiumBiDi.Server, [name: @bidi_server_name]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def validate, do: :ok

  @doc false
  def cleanup_stale_sessions, do: :ok

  @doc """
  Default capabilities passed when starting a Chrome session via BiDi.
  """
  def default_capabilities do
    %{
      browserName: "chrome",
      unhandledPromptBehavior: "ignore"
    }
  end

  # ----- Session lifecycle -----

  @impl Wallabidi.Driver
  def start_session(opts \\ []) do
    base_url = resolve_base_url(opts)

    session_struct = %Session{
      id: "v2bidi-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      driver: __MODULE__,
      driver_spec: @driver_spec,
      browsing_context: nil,
      capabilities: Keyword.get(opts, :capabilities, %{}) |> Map.new()
    }

    with {:ok, session} <-
           BiDi.start_session(
             base_url: base_url,
             session_struct: session_struct,
             owner: Keyword.get(opts, :owner, self())
           ) do
      caller = Keyword.get(opts, :owner, self())
      _ = WebSocketClient.subscribe(session.bidi_pid, "log.entryAdded", caller, :global)

      if metadata = Keyword.get(opts, :metadata) do
        ua = Metadata.append(@base_user_agent, metadata)

        _ =
          Protocol.cdp_send(
            session,
            "emulation.setUserAgentOverride",
            %{"userAgent" => ua, "contexts" => [session.browsing_context]},
            []
          )
      end

      if window_size = Keyword.get(opts, :window_size) do
        _ = BiDiClient.set_viewport(session, window_size[:width], window_size[:height])
      end

      {:ok, session}
    end
  end

  defp resolve_base_url(opts) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) ->
        url

      _ ->
        # Convert the BidiServer's WS URL to its HTTP equivalent —
        # they share the host/port; chromium-bidi serves both.
        ws_url = bidi_ws_url_with_retry(5)

        ws_url
        |> URI.parse()
        |> Map.put(:scheme, "http")
        |> Map.put(:path, nil)
        |> URI.to_string()
    end
  end

  # The supervised BidiServer process can crash mid-suite (chromium-bidi
  # Node process exits non-zero; OOM on CI runners is the most common
  # cause). The one_for_one Supervisor restarts it, but there's a short
  # window where GenServer.call(@bidi_server_name, _) exits with
  # :noproc before the new pid registers under the name. Retry with a
  # small backoff to ride out the gap.
  defp bidi_ws_url_with_retry(0) do
    Wallabidi.Remote.ChromiumBiDi.Server.ws_url(@bidi_server_name)
  end

  defp bidi_ws_url_with_retry(retries_left) do
    Wallabidi.Remote.ChromiumBiDi.Server.ws_url(@bidi_server_name)
  catch
    :exit, _ ->
      Process.sleep(500)
      bidi_ws_url_with_retry(retries_left - 1)
  end

  @impl Wallabidi.Driver
  def end_session(%Session{} = session) do
    Protocol.stop(session)
    :ok
  end

  # ----- Per-driver overrides -----

  # touch_scroll uses BiDi's JS scrollBy workaround (touch pointer
  # actions don't reliably trigger scroll in headless Chrome).
  @doc false
  def touch_scroll_impl(%Wallabidi.Element{} = element, x_offset, y_offset) do
    case BiDiClient.call_on_element(
           Wallabidi.Element.root_session(element),
           element,
           "function(dx, dy) { this.scrollIntoView(); window.scrollBy(dx, dy); return null; }",
           [x_offset, y_offset]
         ) do
      {:ok, _} -> {:ok, nil}
      err -> err
    end
  end

  # Session-scoped send_keys for BiDi uses BiDiClient.send_keys_to_session.
  def send_keys(%Session{} = session, keys) when is_list(keys),
    do: BiDiClient.send_keys_to_session(session, keys)

  def send_keys(%Wallabidi.Element{} = element, keys),
    do: Wallabidi.Remote.Driver.Generic.send_keys(element, keys)

  defdelegate parse_log(log), to: Wallabidi.Remote.Chrome.Logger
end
