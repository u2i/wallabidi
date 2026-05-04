defmodule Wallabidi.Integration.V2.LightpandaSmokeTest do
  @moduledoc """
  End-to-end smoke test for the V2 transport stack against a real
  Lightpanda server. Proves that:

    * `V2.WebSocket` can connect and pass JSON frames
    * `V2.Session` correctly correlates request/response by wire id
    * The blocking `cdp_send` API returns `{:ok, _}` for a CDP RPC

  This test starts its own Lightpanda.Server (no shared state with the
  rest of the integration suite) so that the V2 bootstrap can be
  exercised in isolation. As V2 grows, more tests land here covering
  navigate, find, click, etc. — each one a one-trip exercise of the
  V2 stack against a known-good browser.
  """
  use ExUnit.Case, async: false

  @moduletag :v2

  alias Wallabidi.V2.{CDPClient, WebSocket}
  alias Wallabidi.V2.Session, as: V2Session

  setup do
    {:ok, server} = Lightpanda.Server.start_link(name: nil)
    ws_url = Lightpanda.Server.ws_url(server)
    {:ok, ws_pid} = WebSocket.start_link(ws_url)

    # Bootstrap a CDP target and attach to it. These run synchronously
    # against the WebSocket BEFORE we have a Session GenServer, so we
    # use the `send_sync` helper.
    {:ok, %{"targetId" => target_id}} =
      WebSocket.send_sync(ws_pid, "Target.createTarget", %{url: "about:blank"})

    {:ok, %{"sessionId" => session_id}} =
      WebSocket.send_sync(ws_pid, "Target.attachToTarget", %{
        targetId: target_id,
        flatten: true
      })

    on_exit(fn ->
      try do
        WebSocket.close(ws_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{ws_pid: ws_pid, target_id: target_id, session_id: session_id}
  end

  describe "V2 round-trip" do
    test "Runtime.evaluate returns a value", %{
      ws_pid: ws_pid,
      target_id: target_id,
      session_id: session_id
    } do
      session_struct = %Wallabidi.Session{
        id: "v2-smoke-#{System.unique_integer([:positive])}",
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

      assert {:ok, %{"result" => %{"value" => 2}}} =
               CDPClient.cdp_send(session, "Runtime.evaluate", %{
                 expression: "1 + 1",
                 returnByValue: true
               })

      V2Session.stop(session)
    end
  end
end
