defmodule Wallabidi.Remote.Chrome.SharedConnection do
  @moduledoc false

  # Single shared `WebSocket` connection to Chrome's browser-level
  # debugging endpoint. All `V2ChromeDriver` sessions multiplex over
  # this one WS via CDP flat-session protocol.
  #
  # Lazy-connect on first `get/1` call — by then the driver supervisor
  # has already started either a local Chrome (`Chrome.Server`) or we
  # have a remote URL to connect to.
  #
  # The connected pid is an immutable, process-wide value, so the read
  # path needs no serialization: `get/1` reads it lock-free from
  # `:persistent_term` and returns it directly. Only the rare *write* (the
  # one-time cold connect, or a reconnect after the WS dies) is serialized,
  # through a thin Agent — so exactly one connection is ever created
  # (concurrent first-acquirers all resolve to the same pid via a
  # double-check), and the one-time startup wait isn't multiplied. Every
  # subsequent `get/1` (≈ once per test) is a lock-free term read, not a
  # message round-trip.

  use Agent

  alias Wallabidi.Remote.WebSocket

  @pid_key {__MODULE__, :ws_pid}

  # Must exceed Chrome.Server's @startup_timeout (30s): on a cold start the
  # serialized connect blocks until Chrome emits its DevTools URL, and
  # callers queued behind it wait for that same connect.
  @connect_timeout 40_000

  # The Agent holds no state — the pid lives in :persistent_term. The Agent
  # exists purely to serialize the connect (its mailbox is the one-at-a-time
  # gate). State is `nil`.
  def start_link(_opts) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  @doc """
  Returns the shared WebSocket pid, lazily connecting on first call.
  Caller passes the driver module so we can resolve the local server
  name when no remote URL is configured.
  """
  @spec get(module) :: pid
  def get(driver_mod) do
    case :persistent_term.get(@pid_key, nil) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: connect_serialized(driver_mod)

      nil ->
        connect_serialized(driver_mod)
    end
  end

  # Serialize the connect through the Agent. The update fn double-checks
  # persistent_term: a caller queued behind a concurrent connect will see
  # the now-live pid and return it rather than connecting again.
  defp connect_serialized(driver_mod) do
    Agent.get_and_update(
      __MODULE__,
      fn nil ->
        pid =
          case :persistent_term.get(@pid_key, nil) do
            p when is_pid(p) -> if Process.alive?(p), do: p, else: do_connect(driver_mod)
            nil -> do_connect(driver_mod)
          end

        {pid, nil}
      end,
      @connect_timeout
    )
  end

  defp do_connect(driver_mod) do
    pid = connect(driver_mod)
    :persistent_term.put(@pid_key, pid)
    pid
  end

  defp connect(driver_mod) do
    ws_url =
      case Wallabidi.BrowserPaths.chrome_url() || legacy_remote_url() do
        nil ->
          # Local Chrome — get ws_url from the server we launched.
          Wallabidi.Remote.Chrome.Server.ws_url(Module.concat(driver_mod, Server))

        "ws://" <> _ = url ->
          url

        "wss://" <> _ = url ->
          url

        endpoint ->
          # DevTools HTTP endpoint (host:port) — discover via /json/version.
          # Run the discovery in a fresh Task so its receive loop doesn't
          # contend with the Agent's own mailbox.
          task = Task.async(fn -> discover_ws_url(endpoint) end)
          Task.await(task, 10_000)
      end

    # WebSocket.start_link would link to the *current caller* (the test
    # process invoking get/1), so the shared WS would die when each test
    # exits. Use `start/1` for an unlinked process whose lifetime is tied
    # to the SharedConnection Agent instead.
    {:ok, pid} = WebSocket.start(ws_url)
    pid
  end

  # Same /json/version discovery logic as ChromeCDP.SharedConnection.
  # Kept here verbatim to avoid coupling to the BiDi-era module.
  defp discover_ws_url(endpoint) do
    endpoint = String.trim_trailing(endpoint, "/")

    {:ok, conn} = Mint.HTTP.connect(:http, host(endpoint), port(endpoint))

    {:ok, conn, ref} =
      Mint.HTTP.request(
        conn,
        "GET",
        "/json/version",
        [{"host", "localhost"}],
        nil
      )

    {body, conn} = receive_body!(conn, ref)
    _ = Mint.HTTP.close(conn)

    case Jason.decode(body) do
      {:ok, %{"webSocketDebuggerUrl" => ws_url}} ->
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

  defp rewrite_ws_host(ws_url, endpoint) do
    uri = URI.parse(ws_url)
    URI.to_string(%{uri | host: host(endpoint), port: port(endpoint)})
  end

  defp legacy_remote_url do
    Application.get_env(:wallabidi, :chrome_cdp_v2, []) |> Keyword.get(:remote_url)
  end
end
