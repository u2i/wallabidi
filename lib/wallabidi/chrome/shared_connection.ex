defmodule Wallabidi.Chrome.SharedConnection do
  @moduledoc false

  # Caches lazily-connected `V2.WebSocket` pids keyed by Chrome
  # server name. Originally a single shared WS to one Chrome
  # instance; extended to a small per-server map so the
  # `Wallabidi.Chrome.ServerPool` can spread sessions across
  # multiple Chrome processes.
  #
  # The default keyed entry is `:default`, matching the legacy
  # single-Chrome supervised by `ChromeDriver.init/1` — that path
  # still works unchanged. With the server pool active, each call
  # to `get/1` round-robins across N entries via
  # `ServerPool.next_server/1`.

  use Agent

  alias Wallabidi.WebSocket

  def start_link(_opts) do
    # State: %{server_name_atom => ws_pid}
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Returns a V2.WebSocket pid for the given Chrome driver. Routes
  through the configured `Wallabidi.Chrome.ServerPool` when one
  is present (round-robins across N Chrome processes); falls back
  to a single default WS otherwise.
  """
  @spec get(module) :: pid
  def get(driver_mod) do
    server_name =
      case server_pool_name(driver_mod) do
        nil -> Module.concat(driver_mod, Server)
        pool -> Wallabidi.Chrome.ServerPool.next_server(pool)
      end

    get_for(driver_mod, server_name)
  end

  @doc """
  Returns the V2.WebSocket pid for a specific Chrome server name,
  lazily connecting on first call.
  """
  @spec get_for(module, atom) :: pid
  def get_for(driver_mod, server_name) do
    Agent.get_and_update(__MODULE__, fn cache ->
      case Map.get(cache, server_name) do
        pid when is_pid(pid) ->
          if Process.alive?(pid),
            do: {pid, cache},
            else: connect_and_cache(cache, driver_mod, server_name)

        nil ->
          connect_and_cache(cache, driver_mod, server_name)
      end
    end)
  end

  defp connect_and_cache(cache, driver_mod, server_name) do
    pid = connect(driver_mod, server_name)
    {pid, Map.put(cache, server_name, pid)}
  end

  defp connect(driver_mod, server_name) do
    ws_url =
      case Wallabidi.BrowserPaths.chrome_url() || legacy_remote_url() do
        nil ->
          # Local Chrome — get ws_url from the named server.
          Wallabidi.Chrome.Server.ws_url(server_name)

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

    _ = driver_mod

    # WebSocket.start_link would link to the *current caller* (the test
    # process invoking Agent.get_and_update), so the shared WS would die
    # when each test exits. Use `start/1` for an unlinked process whose
    # lifetime is tied to the SharedConnection Agent instead.
    {:ok, pid} = WebSocket.start(ws_url)
    pid
  end

  # The driver supervisor records the server-pool's name (if any)
  # via :persistent_term at boot — read it back here. Avoids the
  # tuple-key deprecation warning that Application.get_env emits
  # and skips an Application lookup on every start_session.
  defp server_pool_name(driver_mod) do
    :persistent_term.get({__MODULE__, :pool_name, driver_mod}, nil)
  end

  # Same /json/version discovery logic as ChromeCDP.SharedConnection.
  # Kept here verbatim to avoid coupling V2 to the BiDi-era module.
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
