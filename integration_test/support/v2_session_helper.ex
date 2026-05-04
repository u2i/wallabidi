defmodule Wallabidi.Integration.V2SessionHelper do
  @moduledoc false

  # Test helper for V2 integration tests. Brings up a real
  # Lightpanda binary, opens a V2.WebSocket, bootstraps a CDP
  # target, and starts a V2.Session — all the moving parts that
  # let a test go straight into V2.CDPClient calls.
  #
  # Each call to `start_session/0` returns a fresh
  # `{session, ws_pid, server}` triple AND registers an `on_exit`
  # to tear it down at test end.

  alias Wallabidi.V2.WebSocket
  alias Wallabidi.V2.Session, as: V2Session

  @doc """
  Brings up a Lightpanda server, V2.WebSocket, V2.Session, and
  returns `%{session: ..., ws_pid: ..., server_pid: ...}`. The
  caller should pass this map into its tests via `setup`.

  Cleans up automatically via `on_exit`.
  """
  @spec start_session(ExUnit.Callbacks.on_exit_callback() | nil) :: map
  def start_session(_on_exit_fn \\ nil) do
    {:ok, server} = Lightpanda.Server.start_link(name: nil)
    ws_url = Lightpanda.Server.ws_url(server)
    {:ok, ws_pid} = WebSocket.start_link(ws_url)

    {:ok, %{"targetId" => target_id}} =
      WebSocket.send_sync(ws_pid, "Target.createTarget", %{url: "about:blank"})

    {:ok, %{"sessionId" => session_id}} =
      WebSocket.send_sync(ws_pid, "Target.attachToTarget", %{
        targetId: target_id,
        flatten: true
      })

    session_struct = %Wallabidi.Session{
      id: "v2-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      driver: __MODULE__,
      protocol: nil,
      bidi_pid: ws_pid,
      browsing_context: session_id,
      capabilities: %{
        target_id: target_id,
        flat_session_id: true
      }
    }

    {:ok, session} =
      V2Session.start_link(
        ws_pid: ws_pid,
        init_fun: fn -> {:ok, session_struct} end,
        teardown_fun: fn _ -> :ok end
      )

    :ok = Wallabidi.V2.CDPClient.enable_page_lifecycle_events(session)
    :ok = Wallabidi.V2.CDPClient.install_bootstrap(session)

    ExUnit.Callbacks.on_exit(fn ->
      cleanup(session, ws_pid, server)
    end)

    %{session: session, ws_pid: ws_pid, server_pid: server}
  end

  defp cleanup(session, ws_pid, server) do
    try do
      V2Session.stop(session)
    catch
      :exit, _ -> :ok
    end

    try do
      WebSocket.close(ws_pid)
    catch
      :exit, _ -> :ok
    end

    try do
      GenServer.stop(server, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end
  end
end
