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
  # A GenServer (not an Agent) serializes the connect: the first `get/1`
  # establishes the one shared WS while concurrent callers park in the
  # mailbox and are answered once it's ready. This means exactly one
  # connection is ever created — no redundant sockets, no racing — and the
  # one-time startup wait (Chrome booting, handled by `Chrome.Server`)
  # isn't multiplied across callers. Once connected, `get/1` is a cheap
  # `Process.alive?` reply.

  use GenServer

  alias Wallabidi.Remote.WebSocket

  # Must exceed Chrome.Server's @startup_timeout (30s): on a cold start the
  # first get/1 blocks in connect until Chrome emits its DevTools URL, and
  # parked callers wait for that same reply.
  @get_timeout 40_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Returns the shared WebSocket pid, lazily connecting on first call.
  Caller passes the driver module so we can resolve the local server
  name when no remote URL is configured.
  """
  @spec get(module) :: pid
  def get(driver_mod) do
    GenServer.call(__MODULE__, {:get, driver_mod}, @get_timeout)
  end

  # Microseconds spent in the one-time connect (Chrome cold start + WS
  # handshake), or 0 if not yet connected. The connect cost is incurred
  # once, synchronously, by whichever caller triggers it — which in tests
  # is some unlucky test's setup. SlowTestGuard reads this to discount the
  # shared startup from that test's runtime budget. Stored in
  # persistent_term so a formatter process can read it without coupling.
  @connect_us_key {__MODULE__, :connect_us}

  @spec connect_us() :: non_neg_integer()
  def connect_us, do: :persistent_term.get(@connect_us_key, 0)

  @impl true
  def init(nil), do: {:ok, %{pid: nil}}

  @impl true
  def handle_call({:get, driver_mod}, _from, %{pid: pid} = state) do
    if is_pid(pid) and Process.alive?(pid) do
      {:reply, pid, state}
    else
      # Connect once. Concurrent callers are parked in the mailbox and get
      # this same pid when we reply — no second connect, nothing to close.
      {us, new_pid} = :timer.tc(fn -> connect(driver_mod) end)
      :persistent_term.put(@connect_us_key, us)
      {:reply, new_pid, %{state | pid: new_pid}}
    end
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
