defmodule Wallabidi.ChromeCDP.SharedConnectionTest do
  use ExUnit.Case, async: false

  alias Wallabidi.ChromeCDP.SharedConnection

  describe "discover_ws_url/1 — happy path" do
    test "resolves host:port to ws:// URL and rewrites the host back" do
      {:ok, port} = start_fake_devtools_server()

      url = SharedConnection.discover_ws_url("127.0.0.1:#{port}")

      assert url == "ws://127.0.0.1:#{port}/devtools/browser/fake-uuid-123"
    end

    test "strips trailing slash from endpoint" do
      {:ok, port} = start_fake_devtools_server()

      url = SharedConnection.discover_ws_url("127.0.0.1:#{port}/")

      assert url == "ws://127.0.0.1:#{port}/devtools/browser/fake-uuid-123"
    end
  end

  describe "discover_ws_url/1 — mailbox race" do
    # The SharedConnection Agent runs discover_ws_url/1 from inside its own
    # GenServer callback. By the time discovery runs, its mailbox may already
    # contain hundreds of unrelated messages (sandbox checkouts, earlier
    # WebSocket frames, etc.). Mint.HTTP.stream/2 returns :unknown for any
    # message it doesn't recognise; the current implementation handles this
    # by looping receive. Under load, that loop can burn enough time to hit
    # the 5s GenServer call timeout on SharedConnection.get.
    #
    # This test simulates the mailbox-noise scenario and enforces a tight
    # deadline to catch regressions where discovery becomes O(mailbox size).

    test "completes quickly even when mailbox is saturated with unrelated mail" do
      {:ok, port} = start_fake_devtools_server()

      # Stuff the caller's mailbox with 5_000 noise messages BEFORE discovery
      # runs. These are shaped like Mint transport messages but with bogus
      # socket refs, so Mint will return :unknown for each.
      bogus_socket = Port.open({:spawn, "true"}, [:binary])

      for i <- 1..5_000 do
        send(self(), {:tcp, bogus_socket, "garbage-#{i}"})
      end

      # Run discovery under a generous outer deadline. If the re-receive
      # loop is O(mailbox size) and CI-sensitive, this will blow through
      # the 2_000ms budget even though local iterations are fast.
      task =
        Task.async(fn ->
          SharedConnection.discover_ws_url("127.0.0.1:#{port}")
        end)

      url = Task.await(task, 2_000)

      assert url == "ws://127.0.0.1:#{port}/devtools/browser/fake-uuid-123"
    end
  end

  # --- Fake DevTools server ---

  # Minimal TCP server that serves a single canned /json/version response
  # and closes. No Bandit / Plug / Phoenix — we want zero setup overhead
  # and full control over timing.

  defp start_fake_devtools_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn -> accept_loop(listen) end)

    {:ok, port}
  end

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        spawn_link(fn -> handle_request(client) end)
        accept_loop(listen)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle_request(client) do
    # Consume the HTTP request — we don't care about the content, just
    # that the client sends something before we respond.
    _ = :gen_tcp.recv(client, 0, 1_000)

    body =
      Jason.encode!(%{
        "Browser" => "HeadlessChrome/fake",
        "Protocol-Version" => "1.3",
        "webSocketDebuggerUrl" => "ws://localhost/devtools/browser/fake-uuid-123"
      })

    response =
      [
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: #{byte_size(body)}\r\n",
        "Connection: close\r\n",
        "\r\n",
        body
      ]
      |> IO.iodata_to_binary()

    :gen_tcp.send(client, response)
    :gen_tcp.close(client)
  end
end
