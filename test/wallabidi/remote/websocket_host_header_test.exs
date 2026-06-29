defmodule Wallabidi.Remote.WebSocketHostHeaderTest do
  use ExUnit.Case, async: false

  require Logger

  # Verifies that the WebSocket upgrade request sent by
  # Wallabidi.Remote.WebSocket carries `Host: localhost`.
  #
  # Chromium 148 tightened DevTools' host allowlist: the WS upgrade is
  # rejected with a 500 unless the Host header is `localhost` or an IP
  # address. When wallabidi reaches the chromedp/headless-shell
  # container by docker hostname (e.g. `chrome:9222`), the default
  # behavior of sending `Host: chrome:9222` triggers that rejection.

  alias Wallabidi.Remote.BiDi.WebSocketClient
  alias Wallabidi.Remote.WebSocket

  # The fake server replies 500, which the WS process logs at :error.
  # Suppress globally for this module — the 500 is intentional.
  # The WS processes crash on the 500, so trap exits to prevent
  # the linked BiDi client from taking the test down with it.
  setup do
    Process.flag(:trap_exit, true)
    level = Logger.level()
    Logger.configure(level: :critical)
    on_exit(fn -> Logger.configure(level: level) end)
    :ok
  end

  test "Remote.WebSocket upgrade carries Host: localhost regardless of target hostname" do
    {port, listen_socket} = listen_loopback()
    spawn_accept(listen_socket, self())
    ws_url = "ws://127.0.0.1:#{port}/devtools/browser/abc"
    {:ok, pid} = WebSocket.start(ws_url)
    assert_host_localhost!()
    # Wait for the WS process to process the 500 and exit so its
    # log messages are emitted while Logger is still suppressed.
    ref = Process.monitor(pid)
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      2_000 -> :ok
    end
  end

  test "Remote.BiDi.WebSocketClient upgrade carries Host: localhost" do
    {port, listen_socket} = listen_loopback()
    spawn_accept(listen_socket, self())
    ws_url = "ws://127.0.0.1:#{port}/session/abc"
    {:ok, pid} = WebSocketClient.start_link(ws_url)
    assert_host_localhost!()
    ref = Process.monitor(pid)
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      2_000 -> :ok
    end
  end

  defp spawn_accept(listen_socket, parent) do
    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen_socket)
      send(parent, {:headers, read_http_request(socket)})
      # Reply with the exact 500 Chromium 148 sends, so the client
      # surfaces a clean error rather than crashing on `nil` websocket.
      body = "Host header is specified and is not an IP address or localhost."

      response =
        "HTTP/1.1 500 Internal Server Error\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n" <>
          "Content-Type: text/html\r\n\r\n" <>
          body

      :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
    end)
  end

  defp assert_host_localhost! do
    assert_receive {:headers, headers}, 2_000
    host = Map.get(headers, "host")
    assert host == "localhost", "expected Host: localhost, got #{inspect(host)}"
  end

  defp listen_loopback do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen_socket)
    {port, listen_socket}
  end

  defp read_http_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} ->
        data = acc <> chunk

        if String.contains?(data, "\r\n\r\n") do
          parse_headers(data)
        else
          read_http_request(socket, data)
        end

      {:error, _} ->
        parse_headers(acc)
    end
  end

  defp parse_headers(raw) do
    [_request_line | header_lines] =
      raw
      |> String.split("\r\n\r\n", parts: 2)
      |> hd()
      |> String.split("\r\n")

    Enum.reduce(header_lines, %{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> Map.put(acc, String.downcase(name), String.trim(value))
        _ -> acc
      end
    end)
  end
end
