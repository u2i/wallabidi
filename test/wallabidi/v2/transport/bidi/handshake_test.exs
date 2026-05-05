defmodule Wallabidi.V2.Transport.BiDi.HandshakeTest do
  use ExUnit.Case, async: false

  alias Wallabidi.V2.Transport.BiDi.Handshake
  alias Wallabidi.Chrome.BidiServer
  alias Wallabidi.BiDi.WebSocketClient

  @moduletag :browser

  describe "post_session/2" do
    setup do
      {:ok, server} = BidiServer.start_link([])
      ws_url = BidiServer.ws_url(server)

      base_url =
        ws_url
        |> URI.parse()
        |> Map.put(:scheme, "http")
        |> Map.put(:path, nil)
        |> URI.to_string()

      on_exit(fn ->
        try do
          if Process.alive?(server), do: GenServer.stop(server, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, base_url: base_url}
    end

    test "returns a per-session WebSocket URL", %{base_url: base_url} do
      assert {:ok, ws_url} = Handshake.post_session(base_url)
      assert is_binary(ws_url)
      assert ws_url =~ ~r{\Aws://}
      assert ws_url =~ "/session/"
    end

    test "returned URL accepts WebSocket upgrade + browsingContext.create", %{base_url: base_url} do
      # NOTE: chromium-bidi pre-binds the session to the WS upgrade —
      # it sends `session.new` itself using the capabilities from the
      # POST. The WS owner just opens the socket and sends ops.
      {:ok, ws_url} = Handshake.post_session(base_url)
      {:ok, client} = WebSocketClient.start_link(ws_url)

      result =
        WebSocketClient.send_command(
          client,
          "browsingContext.create",
          %{"type" => "tab"},
          15_000
        )

      assert {:ok, %{"context" => ctx}} = result
      assert is_binary(ctx) and ctx != ""

      WebSocketClient.close(client)
    end
  end
end
