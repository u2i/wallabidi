defmodule Wallabidi.Remote.Transport do
  @moduledoc false

  # Strategy for the "where does a session get its WebSocket" question.
  #
  # The V2 stack already has a shape for talking to a CDP-speaking
  # browser: a `V2.WebSocket` pid + a routing key (the CDP `sessionId`,
  # used for flat-session multiplexing). The thing that varies across
  # browsers is *how a session acquires that pid* at start_session time.
  #
  # Three concrete shapes today:
  #
  #   * `SharedWS`        — Chrome CDP. One V2.WebSocket per BEAM, held
  #                         in an Agent. Each session gets a fresh
  #                         BrowserContext + Target + sessionId on the
  #                         shared WS.
  #
  #   * `PerSession`      — Lightpanda. One shared browser process per
  #                         BEAM, but one WebSocket per session
  #                         (Lightpanda accepts many WS to one binary).
  #                         Each WS lives inside a `PerSession.Actor`
  #                         GenServer.
  #
  #   * `IsolatedProcess` — One browser process AND one V2.WebSocket
  #                         per session. Slower but isolated. Used as
  #                         a fallback / for browsers we can't share.
  #
  # Each impl returns the same shape so the surrounding driver code
  # (install_bootstrap, await_page_load, click_aware, …) is unchanged.

  alias Wallabidi.Remote.Transport.Session, as: V2Session
  alias Wallabidi.Remote.WebSocket

  @typedoc """
  What `acquire/1` returns. The driver builds a `Wallabidi.Session`
  from these fields and hands `teardown_fun` to V2.Session as its
  on-terminate callback.

    * `:ws_pid`       — the V2.WebSocket the session sends through
    * `:target_id`    — Chrome target id (CDP) for window-handle
                        bookkeeping; nil if N/A
    * `:session_id`   — the CDP flat-session sessionId (routing key);
                        nil if the transport doesn't multiplex
    * `:browser_context_id` — for SharedWS only; teardown
                        disposes this rather than closing the WS
    * `:teardown_fun` — 1-arity called from V2.Session.terminate/2;
                        receives the session struct
    * `:capabilities` — opaque map merged into the session capabilities
  """
  @type acquired :: %{
          ws_pid: pid,
          target_id: String.t() | nil,
          session_id: String.t() | nil,
          browser_context_id: String.t() | nil,
          teardown_fun: (Wallabidi.Session.t() -> any),
          capabilities: map
        }

  @doc """
  Acquire a transport context for one session. Called by
  `start_session/1`. Failure should propagate as `{:error, term}`.
  """
  @callback acquire(opts :: keyword) :: {:ok, acquired} | {:error, term}

  # ----- Default implementations of common teardown shapes -----
  # Drivers can use these directly or build their own.

  @doc """
  Teardown that closes the WebSocket. Use when the session OWNS
  its WS (PerSession, IsolatedProcess).
  """
  @spec close_ws(pid) :: :ok
  def close_ws(ws_pid) when is_pid(ws_pid) do
    try do
      WebSocket.close(ws_pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @doc """
  Teardown that disposes a Chrome BrowserContext on the shared WS.
  Use with `SharedWS`.
  """
  @spec dispose_browser_context(pid, String.t()) :: :ok
  def dispose_browser_context(ws_pid, ctx_id)
      when is_pid(ws_pid) and is_binary(ctx_id) do
    try do
      WebSocket.send_sync(ws_pid, "Target.disposeBrowserContext", %{
        browserContextId: ctx_id
      })
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @doc """
  Convenience that calls `attachToTarget(targetId, flatten: true)` on
  `ws_pid` and returns `{:ok, sessionId}`. Used by SharedWS and
  PerSession impls.
  """
  @spec attach_to_target(pid, String.t()) :: {:ok, String.t()} | {:error, term}
  def attach_to_target(ws_pid, target_id) do
    case WebSocket.send_sync(ws_pid, "Target.attachToTarget", %{
           targetId: target_id,
           flatten: true
         }) do
      {:ok, %{"sessionId" => sid}} -> {:ok, sid}
      err -> err
    end
  end

  # ----- Shared session bring-up -----

  @doc """
  Builds the Session struct + hands it to V2.Session.start_link with
  the supplied teardown_fun. Then runs the standard V2 init sequence
  (page lifecycle, bootstrap, frame tracking, optional metadata UA,
  optional window_size).

  Returns `{:ok, %Wallabidi.Session{}}` ready for callers to use.
  """
  @spec start_session_from(acquired, Wallabidi.Session.t(), keyword) ::
          {:ok, Wallabidi.Session.t()} | {:error, term}
  def start_session_from(%{ws_pid: ws_pid, teardown_fun: teardown}, session_struct, opts) do
    caller = Keyword.get(opts, :owner, self())

    case V2Session.start_link(
           ws_pid: ws_pid,
           init_fun: fn -> {:ok, session_struct} end,
           teardown_fun: teardown,
           owner: caller
         ) do
      {:ok, session} ->
        :ok = Wallabidi.CDPClient.enable_page_lifecycle_events(session)
        :ok = Wallabidi.CDPClient.install_bootstrap(session)
        :ok = Wallabidi.CDPClient.enable_frame_tracking(session)
        {:ok, session}

      err ->
        # Already-attempted teardown so the V2.WebSocket / context isn't
        # leaked when the Session GenServer fails to come up.
        try do
          teardown.(session_struct)
        catch
          _, _ -> :ok
        end

        err
    end
  end
end
