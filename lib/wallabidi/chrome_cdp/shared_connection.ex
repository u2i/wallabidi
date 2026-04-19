defmodule Wallabidi.ChromeCDP.SharedConnection do
  @moduledoc false

  # Manages a single shared WebSocket connection to Chrome's browser-level
  # debugging endpoint. All ChromeCDP sessions multiplex over this one
  # connection using CDP's flat-session protocol (sessionId in every
  # message). This matches Playwright's "one browser, many contexts" model.
  #
  # Started as a child of the ChromeCDP supervisor. Lazy-connects on first
  # `get/0` call (after ChromeServer has provided the ws_url).

  use Agent

  alias Wallabidi.BiDi.WebSocketClient

  def start_link(_opts) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  @doc "Returns the shared WebSocket pid, connecting lazily if needed."
  def get do
    Agent.get_and_update(__MODULE__, fn
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {pid, pid}
        else
          connect()
        end

      nil ->
        connect()
    end)
  end

  defp connect do
    ws_url =
      case Wallabidi.BrowserPaths.chrome_url() || legacy_remote_url() do
        nil ->
          # Local Chrome — get ws_url from the server we launched
          Wallabidi.Chrome.Server.ws_url(Wallabidi.ChromeCDP.Server)

        "ws://" <> _ = url ->
          # Full WebSocket URL — use directly
          url

        "wss://" <> _ = url ->
          url

        endpoint ->
          # DevTools endpoint (host:port) — discover the ws URL.
          # Run in a fresh process so the HTTP receive loop doesn't contend
          # with the Agent's own mailbox (which may contain unrelated messages
          # from prior test sessions, causing Mint.HTTP.stream/2 to return
          # :unknown repeatedly and exhaust the Agent's call timeout).
          task = Task.async(fn -> discover_ws_url(endpoint) end)
          Task.await(task, 10_000)
      end

    {:ok, pid} = WebSocketClient.start_link(ws_url)
    {pid, pid}
  end

  @doc false
  # Discover the browser WebSocket URL from a Chrome DevTools endpoint.
  # Calls GET /json/version with a Host header workaround (Chrome rejects
  # requests where the Host doesn't match its expectation).
  # Public for testing — not part of the stable API.
  def discover_ws_url(endpoint) do
    endpoint = String.trim_trailing(endpoint, "/")

    {:ok, conn} = Mint.HTTP.connect(:http, host(endpoint), port(endpoint))

    {:ok, conn, ref} =
      Mint.HTTP.request(
        conn,
        "GET",
        "/json/version",
        [
          {"host", host_header(endpoint)}
        ],
        nil
      )

    {body, conn} = receive_body!(conn, ref)
    _ = Mint.HTTP.close(conn)

    case Jason.decode(body) do
      {:ok, %{"webSocketDebuggerUrl" => ws_url}} ->
        # Rewrite the host so it's reachable from our perspective
        # (Chrome reports localhost from its container's perspective)
        rewrite_ws_host(ws_url, endpoint)

      {:ok, other} ->
        raise "Chrome /json/version did not include webSocketDebuggerUrl: #{inspect(other)}"

      {:error, _} ->
        raise "Chrome /json/version returned invalid JSON: #{body}"
    end
  end

  defp receive_body!(conn, ref, acc \\ "") do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            {conn, body} =
              Enum.reduce(responses, {conn, acc}, fn
                {:data, ^ref, data}, {c, a} -> {c, a <> data}
                {:done, ^ref}, {c, a} -> {c, a}
                _, {c, a} -> {c, a}
              end)

            if Enum.any?(responses, &match?({:done, ^ref}, &1)) do
              {body, conn}
            else
              receive_body!(conn, ref, body)
            end

          :unknown ->
            # Message wasn't for this Mint connection — skip and re-receive.
            # The Agent's mailbox may contain unrelated messages from earlier
            # test sessions.
            receive_body!(conn, ref, acc)

          {:error, _conn, reason, _} ->
            raise "Chrome /json/version request failed: #{inspect(reason)}"
        end
    after
      5_000 -> raise "Chrome /json/version timed out"
    end
  end

  defp host(endpoint) do
    case String.split(endpoint, ":") do
      [h | _] -> h
      _ -> endpoint
    end
  end

  defp port(endpoint) do
    case String.split(endpoint, ":") do
      [_, p] -> String.to_integer(p)
      _ -> 9222
    end
  end

  defp host_header(_endpoint) do
    # Chrome's DevTools HTTP handler rejects requests unless the Host
    # header is "localhost", an IP address, or "chromium.org". When
    # connecting via a Docker hostname like "chrome:9222", we must
    # send Host: localhost to pass the allowlist check.
    "localhost"
  end

  defp rewrite_ws_host(ws_url, endpoint) do
    uri = URI.parse(ws_url)
    target_host = host(endpoint)
    target_port = port(endpoint)
    URI.to_string(%{uri | host: target_host, port: target_port})
  end

  defp legacy_remote_url do
    Application.get_env(:wallabidi, :chrome_cdp, []) |> Keyword.get(:remote_url)
  end
end
