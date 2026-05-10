defmodule Wallabidi.Remote.WebSocket do
  @moduledoc false

  # New transport layer (the "plexer/demuxer") for CDP and BiDi
  # WebSocket protocols. Replaces `Wallabidi.BiDi.WebSocketClient`
  # by being deliberately dumber:
  #
  #   * outbound = encode JSON, write bytes, register correlation
  #   * inbound  = parse bytes, route to the right SessionProcess
  #
  # No find waiters, no page-ready logic, no per-session state — those
  # all live in `Wallabidi.Remote.Transport.Session`. The split exists so the
  # request/response correlation flows through ONE actor (the owning
  # Session) and async events arrive at that same actor's mailbox in
  # FIFO order, eliminating the cross-process ordering races that the
  # old design papered over with a sync barrier.
  #
  # Routing:
  #
  #   * Responses (frames carrying `"id"`) go back to the SessionProcess
  #     that issued the call — looked up by wire id.
  #   * Events (frames carrying `"method"`) are routed by the routing
  #     key (`sessionId` for CDP, `params.context` /
  #     `params.source.context` for BiDi) to subscribed SessionProcesses.
  #
  # The Session that issued a call is identified by passing its `pid`
  # in `cast_send/5`. We stash `wire_id → owner_pid` and reply via
  # `send(owner_pid, {:v2_response, wire_id, result})`.

  use GenServer
  require Logger

  defstruct [
    :conn,
    :ref,
    :websocket,
    :status,
    :subscribers_table,
    next_id: 1,
    pending: %{},
    queued: []
  ]

  @type routing_key :: String.t() | :global

  # ----- Public API -----

  @doc """
  Starts a WebSocket connection to `ws_url`. Returns `{:ok, pid}` on
  successful upgrade.
  """
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(ws_url) when is_binary(ws_url) do
    GenServer.start_link(__MODULE__, ws_url)
  end

  @doc """
  Like `start_link/1` but starts the GenServer unlinked. Used by the
  shared-connection Agent so the WS isn't tied to the caller's
  lifetime.
  """
  @spec start(String.t()) :: GenServer.on_start()
  def start(ws_url) when is_binary(ws_url) do
    GenServer.start(__MODULE__, ws_url)
  end

  @doc """
  Asynchronously send a CDP/BiDi command. The response (or transport
  failure) will be delivered to `owner_pid` as
  `{:v2_response, wire_id, result}`.

  Returns the wire id assigned to this call so the caller can stash
  it in its pending-calls map.

  `opts`:
    * `:flat_session_id` (boolean) — if true, places `sessionId` at the
      JSON-RPC top level (CDP flat-session protocol). If false (default),
      `sessionId` rides inside `params` if present.
    * `:session_id` (string) — required when `:flat_session_id` is true.
  """
  @spec cast_send(pid, pid, String.t(), map, keyword) :: non_neg_integer()
  def cast_send(ws_pid, owner_pid, method, params, opts \\ []) do
    GenServer.call(ws_pid, {:assign_id_and_send, owner_pid, method, params, opts})
  end

  @doc """
  Synchronously send a CDP/BiDi command and wait for the response.

  Convenience wrapper around `cast_send/5` for callers without a
  Session GenServer (e.g. session bootstrap that runs before the
  Session exists). The caller's mailbox receives the `:v2_response`
  message; this function pulls it out and returns the result.

  Caveat: this consumes the next `:v2_response` matching `wire_id`
  from the calling process's mailbox. Don't use it from a process
  that has other in-flight V2 calls.
  """
  @spec send_sync(pid, String.t(), map, keyword) :: {:ok, map} | {:error, term}
  def send_sync(ws_pid, method, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    wire_id = cast_send(ws_pid, self(), method, params, Keyword.delete(opts, :timeout))

    receive do
      {:v2_response, ^wire_id, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Subscribe `subscriber` to events matching `event_method`, scoped by
  `routing_key` (a session/context id) or `:global` for all sessions.
  """
  @spec subscribe(pid, String.t(), routing_key, pid | nil) :: :ok
  def subscribe(ws_pid, event_method, routing_key \\ :global, subscriber \\ nil)
      when is_binary(event_method) do
    GenServer.call(ws_pid, {:subscribe, event_method, routing_key, subscriber || self()})
  end

  @doc "Remove a subscription."
  @spec unsubscribe(pid, String.t(), routing_key, pid) :: :ok
  def unsubscribe(ws_pid, event_method, routing_key, subscriber)
      when is_binary(event_method) and is_pid(subscriber) do
    GenServer.call(ws_pid, {:unsubscribe, event_method, routing_key, subscriber})
  end

  @doc "Drop all subscriptions for a routing key. Used at session teardown."
  @spec unsubscribe_all(pid, routing_key) :: :ok
  def unsubscribe_all(ws_pid, routing_key) do
    GenServer.call(ws_pid, {:unsubscribe_all, routing_key})
  end

  @doc "Close the WebSocket and stop the GenServer."
  @spec close(pid) :: :ok
  def close(ws_pid) do
    GenServer.call(ws_pid, :close)
  end

  # ----- GenServer callbacks -----

  @impl true
  def init(ws_url) do
    uri = URI.parse(ws_url)
    http_scheme = if uri.scheme in ["wss", "https"], do: :https, else: :http
    ws_scheme = if uri.scheme in ["wss", "https"], do: :wss, else: :ws
    port = uri.port || if(http_scheme == :https, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?#{uri.query}", else: "")

    table =
      :ets.new(:wallabidi_v2_subscribers, [
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, port),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, []) do
      {:ok, %__MODULE__{conn: conn, ref: ref, subscribers_table: table}}
    else
      {:error, reason} ->
        {:stop, {:connection_failed, reason}}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:stop, {:upgrade_failed, reason}}
    end
  end

  @impl true
  def handle_call(
        {:assign_id_and_send, owner_pid, method, params, opts},
        _from,
        %{websocket: nil} = state
      ) do
    # Connection still upgrading. Assign the id now and queue the send.
    id = state.next_id
    t0 = Wallabidi.Bench.Timing.mark_now()
    queued = state.queued ++ [{id, owner_pid, method, params, opts}]
    pending = Map.put(state.pending, id, {owner_pid, t0})
    {:reply, id, %{state | next_id: id + 1, queued: queued, pending: pending}}
  end

  def handle_call({:assign_id_and_send, owner_pid, method, params, opts}, _from, state) do
    id = state.next_id

    case do_send(state, id, method, params, opts) do
      {:ok, state} ->
        t0 = Wallabidi.Bench.Timing.mark_now()
        pending = Map.put(state.pending, id, {owner_pid, t0})
        {:reply, id, %{state | next_id: id + 1, pending: pending}}

      {:error, state, reason} ->
        # Surface the failure to the owner immediately.
        send(owner_pid, {:v2_response, id, {:error, reason}})
        {:reply, id, %{state | next_id: id + 1}}
    end
  end

  def handle_call({:subscribe, event_method, routing_key, subscriber}, _from, state) do
    key = {event_method, routing_key}
    existing = lookup_subs(state.subscribers_table, key)
    :ets.insert(state.subscribers_table, {key, [subscriber | List.delete(existing, subscriber)]})
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, event_method, routing_key, subscriber}, _from, state) do
    key = {event_method, routing_key}
    existing = lookup_subs(state.subscribers_table, key)

    case List.delete(existing, subscriber) do
      [] -> :ets.delete(state.subscribers_table, key)
      list -> :ets.insert(state.subscribers_table, {key, list})
    end

    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe_all, routing_key}, _from, state) do
    :ets.match_delete(state.subscribers_table, {{:_, routing_key}, :_})
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    case send_frame(state, :close) do
      {:ok, state} ->
        Mint.HTTP.close(state.conn)
        {:stop, :normal, :ok, state}

      {:error, state, _reason} ->
        Mint.HTTP.close(state.conn)
        {:stop, :normal, :ok, state}
    end
  end

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        state = Enum.reduce(responses, state, &process_response/2)
        {:noreply, state}

      {:error, conn, reason, _responses} ->
        Logger.warning(
          "V2.WebSocket transport error pid=#{inspect(self())} msg=#{inspect(message)} reason=#{inspect(reason)}"
        )

        notify_all_pending(state, {:error, :session_closed})
        {:stop, {:transport_error, reason}, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    :ok
  end

  # ----- Frame processing -----

  defp process_response({:status, ref, status}, %{ref: ref} = state) do
    if status != 101 do
      Logger.error("V2.WebSocket upgrade failed with status #{status}")
    end

    %{state | status: status}
  end

  defp process_response({:headers, ref, headers}, %{ref: ref, status: 101} = state) do
    case Mint.WebSocket.new(state.conn, ref, 101, headers) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}
        flush_queued(state)

      {:error, conn, reason} ->
        Logger.error("V2.WebSocket handshake failed: #{inspect(reason)}")
        %{state | conn: conn}
    end
  end

  defp process_response({:headers, _ref, _headers}, state), do: state

  defp process_response({:data, ref, data}, %{ref: ref} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        Enum.reduce(frames, state, &process_frame/2)

      {:error, websocket, reason} ->
        Logger.error("V2.WebSocket decode error: #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  defp process_response(_response, state), do: state

  defp process_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"id" => id} = response} ->
        deliver_response(state, id, response)

      {:ok, %{"method" => method} = event} ->
        broadcast_event(state, method, event)
        state

      {:error, _} ->
        Logger.warning(
          "V2.WebSocket received invalid JSON: #{inspect(String.slice(text, 0, 200))}"
        )

        state
    end
  end

  defp process_frame({:close, _code, _reason}, state) do
    notify_all_pending(state, {:error, :websocket_closed})
    state
  end

  defp process_frame(_frame, state), do: state

  # ----- Routing -----

  defp deliver_response(state, id, response) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        # No registered owner — fire-and-forget cast or stale id. Ignore.
        state

      {{owner_pid, t0}, pending} ->
        Wallabidi.Bench.Timing.record(t0)
        send(owner_pid, {:v2_response, id, parse_response(response)})
        %{state | pending: pending}
    end
  end

  defp broadcast_event(state, method, event) do
    keys =
      [
        event["sessionId"],
        get_in(event, ["params", "context"]),
        get_in(event, ["params", "source", "context"])
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    table = state.subscribers_table

    session_pids =
      keys |> Enum.flat_map(fn k -> lookup_subs(table, {method, k}) end)

    global_pids = lookup_subs(table, {method, :global})

    Enum.each(session_pids ++ global_pids, fn pid ->
      send(pid, {:v2_event, method, event})
    end)
  end

  defp lookup_subs(table, key) do
    case :ets.lookup(table, key) do
      [{^key, list}] -> list
      [] -> []
    end
  end

  defp notify_all_pending(state, reply) do
    Enum.each(state.pending, fn {id, {owner_pid, _t0}} ->
      send(owner_pid, {:v2_response, id, reply})
    end)
  end

  # ----- Send helpers -----

  defp do_send(state, id, method, params, opts) do
    message = build_message(id, method, params, opts) |> Jason.encode!()
    send_frame(state, {:text, message})
  end

  defp build_message(id, method, params, opts) do
    base = %{id: id, method: method, params: params}

    cond do
      Keyword.get(opts, :flat_session_id) ->
        Map.put(base, :sessionId, Keyword.fetch!(opts, :session_id))

      session_id = Keyword.get(opts, :session_id) ->
        # Non-flat: place sessionId inside params (legacy CDP form).
        %{base | params: Map.put(params, :sessionId, session_id)}

      true ->
        base
    end
  end

  defp flush_queued(%{queued: []} = state), do: state

  defp flush_queued(state) do
    Enum.reduce(state.queued, %{state | queued: []}, fn {id, owner_pid, method, params, opts},
                                                        acc ->
      case do_send(acc, id, method, params, opts) do
        {:ok, acc} ->
          acc

        {:error, acc, reason} ->
          send(owner_pid, {:v2_response, id, {:error, reason}})
          %{acc | pending: Map.delete(acc.pending, id)}
      end
    end)
  end


  defp send_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            {:error, %{state | conn: conn, websocket: websocket}, reason}
        end

      {:error, websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}
    end
  end

  # ----- Response parsing -----

  # BiDi error: {"error": "string", "message": "..."}
  defp parse_response(%{"error" => error, "message" => message}) when is_binary(error),
    do: {:error, {error, message}}

  # CDP error: {"error": {"code": -32000, "message": "..."}}
  defp parse_response(%{"error" => %{"message" => message} = error}),
    do: {:error, {Map.get(error, "code", "unknown"), message}}

  defp parse_response(%{"result" => result}), do: {:ok, result}
  defp parse_response(other), do: {:ok, other}
end
