defmodule Wallabidi.ChromeDriver.PoolImpl do
  @moduledoc false

  # `Wallabidi.Driver.Pool` impl for Chrome (CDP V2).
  #
  # Slot model — Phase 1, :rebuild strategy:
  #
  #   - A "slot" is a logical accounting unit. Chrome shares one
  #     `Wallabidi.WebSocket` across all sessions in the BEAM (the
  #     `SharedConnection` singleton), so opening a slot is essentially
  #     just storing a reference to that shared WS pid.
  #
  #   - Per-session work (BrowserContext + Target + Attach + bootstrap
  #     install) happens in `prepare_session/2`. Per-session teardown
  #     (BrowserContext dispose) happens in `finalize_session/2`. The
  #     pool keeps the slot warm by NOT tearing the slot down between
  #     sessions — the shared WS doesn't need recreating.
  #
  # The win over direct `ChromeDriver.start_session/1`: the pool
  # keeps N slots ready (size config). On checkout, the pool returns
  # an already-prepared session if available; otherwise it prepares
  # one synchronously. Effectively pre-warms the per-session
  # bring-up cost off the test critical path under low concurrency.
  #
  # Phase 2 (TBD) adds `reset_slot/1` returning `:ok` to keep the
  # session itself across multiple tests with a state reset (cookies,
  # storage, navigate to about:blank). Phase 1 always recycles via
  # finalize+prepare on the same slot — full BrowserContext rebuild.

  @behaviour Wallabidi.Driver.Pool

  alias Wallabidi.{Session, Transport, WebSocket}
  alias Wallabidi.Chrome.SharedConnection
  alias Wallabidi.CDPClient

  @impl true
  def open_slot(_opts) do
    # The shared WS is brought up by ChromeDriver's supervisor at
    # app start. We just reference it here. If it's not up the call
    # falls through; the pool's open_slot retry logic handles it.
    case SharedConnection.get(Wallabidi.ChromeDriver) do
      nil -> {:error, :shared_connection_not_started}
      ws_pid when is_pid(ws_pid) -> {:ok, %{ws_pid: ws_pid}}
    end
  end

  @impl true
  def close_slot(_handle) do
    # Shared WS is owned by the application supervisor — don't touch.
    :ok
  end

  @impl true
  def prepare_session(handle, session_opts) do
    caller = Keyword.get(session_opts, :owner, self())
    ws_pid = handle.ws_pid

    with {:ok, acquired} <-
           Transport.SharedWS.acquire(
             connection: SharedConnection,
             driver: Wallabidi.ChromeDriver
           ) do
      session_struct = %Session{
        id: "v2-chrome-pool-#{System.unique_integer([:positive])}",
        url: "about:blank",
        session_url: "about:blank",
        driver: Wallabidi.ChromeDriver,
        protocol: nil,
        bidi_pid: acquired.ws_pid,
        browsing_context: acquired.session_id,
        capabilities: Map.merge(Keyword.get(session_opts, :capabilities, %{}), acquired.capabilities)
      }

      with {:ok, session} <-
             Transport.start_session_from(acquired, session_struct, owner: caller) do
        # Mirror ChromeDriver.start_session/1's per-test side effects.
        _ = WebSocket.subscribe(ws_pid, "Runtime.consoleAPICalled", acquired.session_id, caller)
        _ = WebSocket.subscribe(ws_pid, "Runtime.exceptionThrown", acquired.session_id, caller)

        if metadata = Keyword.get(session_opts, :metadata) do
          ua = Wallabidi.Metadata.append(base_user_agent(), metadata)
          _ = CDPClient.cdp_send(session, "Network.setUserAgentOverride", %{userAgent: ua})
        end

        if window_size = Keyword.get(session_opts, :window_size) do
          _ = CDPClient.set_window_size(session, window_size[:width], window_size[:height])
        end

        {:ok, %{session: session, acquired: acquired}}
      end
    end
  end

  @impl true
  def finalize_session(_handle, %{session: session}) do
    # Phase 1: dispose the BrowserContext via the standard end_session
    # path. The shared WS slot itself stays alive in the pool.
    Wallabidi.ChromeDriver.end_session(session)
    :ok
  end

  def finalize_session(_handle, :crashed) do
    # Caller crashed before checking back in. Best-effort cleanup
    # only — the underlying session GenServer monitors the caller and
    # has already begun its own teardown.
    :ok
  end

  def finalize_session(_handle, _other), do: :ok

  defp base_user_agent do
    "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
      "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"
  end
end
