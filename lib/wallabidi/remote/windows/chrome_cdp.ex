defmodule Wallabidi.Remote.Windows.ChromeCDP do
  @moduledoc false

  # Window/tab management for Chrome over CDP — uses Target.*
  # commands against the shared WS to enumerate / attach / close tabs
  # in this session's browser context.

  @behaviour Wallabidi.Remote.Windows

  alias Wallabidi.{Element, Session}
  alias Wallabidi.Remote.CDP.Client, as: CDPClient
  alias Wallabidi.Remote.WebSocket

  @impl true
  def window_handle(%Session{pid: pid} = session) when is_pid(pid) do
    # The session struct in the caller's hand may carry a stale
    # target_id (focus_window/2 mutates the live state in the
    # GenServer). Re-fetch the current state.
    case GenServer.call(pid, :get_session) do
      %Session{capabilities: caps} -> {:ok, caps[:target_id]}
      _ -> {:ok, get_in(session.capabilities, [:target_id])}
    end
  catch
    :exit, _ -> {:ok, get_in(session.capabilities, [:target_id])}
  end

  def window_handle(%Session{} = session) do
    {:ok, get_in(session.capabilities, [:target_id])}
  end

  def window_handle(%Element{} = element) do
    window_handle(Element.root_session(element))
  end

  @impl true
  def window_handles(parent) do
    session = Element.root_session(parent)
    ws_pid = session.bidi_pid
    ctx_id = get_in(session.capabilities, [:browser_context_id])

    case WebSocket.send_sync(ws_pid, "Target.getTargets", %{}) do
      {:ok, %{"targetInfos" => targets}} ->
        handles =
          targets
          |> Enum.filter(fn t ->
            t["type"] == "page" && t["browserContextId"] == ctx_id
          end)
          |> Enum.map(fn t -> t["targetId"] end)

        {:ok, handles}

      _ ->
        {:ok, [get_in(session.capabilities, [:target_id])]}
    end
  end

  @impl true
  def focus_window(parent, target_id) when is_binary(target_id) do
    session = Element.root_session(parent)
    ws_pid = session.bidi_pid

    # Switch the Session's CDP target by re-attaching to the new
    # one (gets a new sessionId). Update session.browsing_context so
    # subsequent cdp_send opts route there.
    case WebSocket.send_sync(ws_pid, "Target.attachToTarget", %{
           targetId: target_id,
           flatten: true
         }) do
      {:ok, %{"sessionId" => session_id}} ->
        # Update session struct in the GenServer (the caller's struct
        # may be stale; window_handle/1 re-fetches via :get_session).
        if session.pid do
          GenServer.call(session.pid, {:update_browsing_context, session_id, target_id})
        end

        new_session = %{
          session
          | browsing_context: session_id,
            capabilities: Map.put(session.capabilities, :target_id, target_id)
        }

        # All four setup commands fire-and-forget so they pipeline on
        # the wire instead of round-tripping in series. CDPClient's
        # enable_page_lifecycle_events / install_bootstrap already use
        # cdp_cast internally; the inline IIFE was the last sync send,
        # so cast it too. Subsequent cdp_send calls (e.g. visit) will
        # naturally barrier until all four land.
        _ = CDPClient.enable_page_lifecycle_events(new_session)
        _ = CDPClient.install_bootstrap(new_session)

        # The new tab may have loaded its document BEFORE we attached.
        # Page.addScriptToEvaluateOnNewDocument (queued by
        # install_bootstrap) only fires for *future* documents, so the
        # bootstrap won't be present until the next nav. Run the IIFE
        # inline against the current document so subsequent finds
        # work without needing a reload.
        CDPClient.cdp_cast(new_session, "Runtime.evaluate", %{
          expression: Wallabidi.Remote.Bootstrap.cdp_iife(),
          returnByValue: true
        })

        {:ok, nil}

      err ->
        err
    end
  end

  @impl true
  def close_window(%Session{pid: pid} = session) when is_pid(pid) do
    # The caller's session struct may carry a stale target_id —
    # focus_window/2 mutates the live state in the GenServer. Re-fetch
    # so close_window closes the *currently focused* target, not the
    # one the caller's struct was first built with.
    current =
      try do
        GenServer.call(pid, :get_session)
      catch
        :exit, _ -> session
      end

    target_id = get_in(current.capabilities, [:target_id])
    ws_pid = session.bidi_pid
    _ = WebSocket.send_sync(ws_pid, "Target.closeTarget", %{targetId: target_id})
    {:ok, nil}
  end

  def close_window(%Session{} = session) do
    target_id = get_in(session.capabilities, [:target_id])
    ws_pid = session.bidi_pid
    _ = WebSocket.send_sync(ws_pid, "Target.closeTarget", %{targetId: target_id})
    {:ok, nil}
  end

  def close_window(%Element{} = element), do: close_window(Element.root_session(element))
end
