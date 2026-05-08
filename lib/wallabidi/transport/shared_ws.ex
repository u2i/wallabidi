defmodule Wallabidi.Transport.SharedWS do
  @moduledoc false

  # Transport: ONE V2.WebSocket per BEAM, shared across all sessions
  # via CDP's flat-session protocol. Each `acquire/1`:
  #
  #   1. Fetches the shared ws_pid from a connection-holder Agent
  #      (typically `Wallabidi.Chrome.SharedConnection`).
  #   2. Creates a fresh BrowserContext on that shared WS.
  #   3. Creates a Target inside that BrowserContext (about:blank).
  #   4. Attaches to the target (flat session) → gets a sessionId
  #      that becomes the routing key for this session.
  #
  # Teardown disposes the BrowserContext (which kills its targets)
  # but leaves the shared WS alone.

  @behaviour Wallabidi.Transport

  alias Wallabidi.Transport
  alias Wallabidi.WebSocket

  @impl true
  def acquire(opts) do
    connection = Keyword.fetch!(opts, :connection)
    driver_mod = Keyword.fetch!(opts, :driver)

    ws_pid = connection.get(driver_mod)

    with {:ok, %{"browserContextId" => ctx_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createBrowserContext", %{}),
         {:ok, %{"targetId" => target_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createTarget", %{
             url: "about:blank",
             browserContextId: ctx_id
           }),
         {:ok, session_id} <- Transport.attach_to_target(ws_pid, target_id) do
      teardown = fn _session -> Transport.dispose_browser_context(ws_pid, ctx_id) end

      {:ok,
       %{
         ws_pid: ws_pid,
         target_id: target_id,
         session_id: session_id,
         browser_context_id: ctx_id,
         teardown_fun: teardown,
         capabilities: %{
           target_id: target_id,
           browser_context_id: ctx_id,
           flat_session_id: true,
           shared_connection: true
         }
       }}
    end
  end
end
