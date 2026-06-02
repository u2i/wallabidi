defmodule Wallabidi.Remote.Chrome.SharedConnection do
  @moduledoc false

  # Single shared `WebSocket` connection to Chrome's browser-level
  # debugging endpoint. All `V2ChromeDriver` sessions multiplex over
  # this one WS via CDP flat-session protocol.
  #
  # Lazy-connect on first `get/1` call — by then the driver supervisor
  # has already started either a local Chrome (`Chrome.Server`) or we
  # have a remote URL to connect to.

  use Agent

  alias Wallabidi.Remote.WebSocket

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
    # Fast path: return the live shared pid. This is a cheap read under the
    # Agent lock (just `Process.alive?`), so concurrent acquirers don't
    # block each other once connected.
    case live_pid() do
      pid when is_pid(pid) ->
        pid

      nil ->
        # Slow path: connect WITHOUT holding the Agent lock — the connect
        # does a GenServer.call to the Chrome server (cold start can be
        # seconds) plus a WS handshake, and doing that inside the Agent's
        # update fn serialized all concurrent first-acquirers behind one
        # lock, timing the rest out (the cause of the CI flake). Instead we
        # connect outside the lock, then commit under it with a
        # double-check so only one connection wins; redundant ones (from a
        # concurrent connect race) are closed.
        commit(connect(driver_mod))
    end
  end

  # Returns the stored pid if alive, else nil — and clears a dead pid so
  # the next caller reconnects. Cheap; safe to call under contention.
  defp live_pid do
    Agent.get_and_update(__MODULE__, fn
      pid when is_pid(pid) -> if Process.alive?(pid), do: {pid, pid}, else: {nil, nil}
      nil -> {nil, nil}
    end)
  end

  # Store the freshly-connected pid, unless another concurrent acquirer
  # already stored a live one — in which case keep theirs and close ours.
  #
  # The Agent update fn returns `{return_value, new_state}`. We encode the
  # decision in the return_value (a tagged tuple) and set new_state to the
  # pid we keep.
  defp commit(new_pid) do
    decision =
      Agent.get_and_update(__MODULE__, fn
        existing when is_pid(existing) ->
          if Process.alive?(existing) do
            {{:keep_existing, existing}, existing}
          else
            {{:took_new, new_pid}, new_pid}
          end

        nil ->
          {{:took_new, new_pid}, new_pid}
      end)

    case decision do
      {:keep_existing, existing} ->
        # Lost the race — discard the duplicate WS so it doesn't leak.
        WebSocket.close(new_pid)
        existing

      {:took_new, pid} ->
        pid
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
