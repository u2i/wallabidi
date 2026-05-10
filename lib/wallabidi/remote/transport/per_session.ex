defmodule Wallabidi.Remote.Transport.PerSession do
  @moduledoc false

  # Transport: ONE actor per session. The actor owns its own raw Mint
  # WebSocket directly — no separate V2.WebSocket process, no
  # V2.Session in front. Compared to the old PerSessionWS
  # (V2.WebSocket + V2.Session linked together) this halves the
  # per-cdp-call hop count.
  #
  # All inbound WS frames AND all outbound caller calls land in ONE
  # mailbox. Causal ordering between events and responses is preserved
  # without any barrier.
  #
  # Used by V2Driver when a shared Lightpanda server is running: each
  # session opens its own WS to the same binary, runs Target.create-
  # Target + attachToTarget on that WS, and the resulting actor
  # handles everything for that session.

  alias Wallabidi.Session
  alias Wallabidi.CDPClient
  alias Wallabidi.Remote.Transport.PerSession.Actor

  @doc """
  Bring up a new session.

  Required opts:
    * `:ws_url`  — the shared browser's WebSocket URL
    * `:session_struct` — `%Wallabidi.Session{}` to back the session
      with (driver fills in id/url/capabilities/etc.)

  Optional:
    * `:owner`        — process to monitor; defaults to `self()`
    * `:teardown_fun` — 1-arity called from `terminate/2` after the
      session ends. Defaults to a no-op.
  """
  @spec start_session(keyword) :: {:ok, Session.t()} | {:error, term}
  def start_session(opts) do
    ws_url = Keyword.fetch!(opts, :ws_url)
    session_struct = Keyword.fetch!(opts, :session_struct)
    teardown_fun = Keyword.get(opts, :teardown_fun, fn _ -> :ok end)
    owner = Keyword.get(opts, :owner, self())

    with {:ok, session} <-
           Actor.start_link(
             ws_url: ws_url,
             init_fun: fn -> {:ok, session_struct} end,
             teardown_fun: teardown_fun,
             owner: owner
           ),
         # Open a CDP target on this brand-new WS. attachToTarget
         # produces the flat sessionId we'll use for routing.
         {:ok, %{"targetId" => target_id}} <-
           CDPClient.cdp_send(session, "Target.createTarget", %{url: "about:blank"}),
         {:ok, %{"sessionId" => session_id}} <-
           CDPClient.cdp_send(session, "Target.attachToTarget", %{
             targetId: target_id,
             flatten: true
           }) do
      # Update the session struct so subsequent CDP calls carry the
      # right flat_session_id + target_id.
      session = update_session_for_target(session, session_id, target_id)

      :ok = CDPClient.enable_page_lifecycle_events(session)
      :ok = CDPClient.install_bootstrap(session)
      :ok = CDPClient.enable_frame_tracking(session)

      {:ok, session}
    end
  end

  defp update_session_for_target(%Session{} = session, session_id, target_id) do
    GenServer.call(session.pid, {:update_browsing_context, session_id, target_id})

    %{
      session
      | browsing_context: session_id,
        capabilities: Map.put(session.capabilities, :target_id, target_id)
    }
  end
end
