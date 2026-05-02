defmodule Wallabidi.BiDi.WebSocketClient do
  @moduledoc false
  # GenServer managing a single WebSocket connection per session using Mint.WebSocket.

  use GenServer
  require Logger

  @default_timeout 10_000

  defstruct [
    :conn,
    :websocket,
    :ref,
    :subscribers_table,
    next_id: 1,
    pending: %{},
    buffer: "",
    status: nil,
    queued_commands: []
  ]

  # Public API

  def start_link(ws_url) do
    GenServer.start_link(__MODULE__, ws_url)
  end

  def send_command(pid, method, params, timeout \\ @default_timeout) do
    GenServer.call(pid, {:send_command, method, params}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :session_closed}
    :exit, {:normal, _} -> {:error, :session_closed}
    :exit, {:shutdown, _} -> {:error, :session_closed}
    :exit, :shutdown -> {:error, :session_closed}
  end

  @doc """
  Like send_command but places sessionId at the top level of the JSON-RPC
  message (required by Chrome's CDP). The sessionId is NOT included in params.
  """
  def send_command_flat(pid, method, params, session_id, timeout \\ @default_timeout) do
    GenServer.call(pid, {:send_command_flat, method, params, session_id}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :session_closed}
    :exit, {:normal, _} -> {:error, :session_closed}
    :exit, {:shutdown, _} -> {:error, :session_closed}
    :exit, :shutdown -> {:error, :session_closed}
  end

  @doc "Fire-and-forget: send a BiDi command without waiting for the response."
  def cast_command(pid, method, params) do
    GenServer.cast(pid, {:cast_command, method, params})
  end

  def cast_command_flat(pid, method, params, session_id) do
    GenServer.cast(pid, {:cast_command_flat, method, params, session_id})
  end

  @doc """
  Subscribe `subscriber` (default: caller) to events matching `event_method`.

  When a shared WebSocket carries events for multiple CDP sessions, pass
  `session_id` to scope delivery: only events whose top-level `"sessionId"`
  matches will be forwarded. Omit `session_id` (or pass `:global`) to
  receive events regardless of session — this is the default for BiDi and
  for per-connection CDP setups.
  """
  def subscribe(pid, event_method, subscriber \\ nil, session_id \\ :global) do
    GenServer.call(pid, {:subscribe, event_method, subscriber, session_id})
  catch
    :exit, _ -> :ok
  end

  @doc "Remove a subscriber registered via `subscribe/4`."
  def unsubscribe(pid, event_method, subscriber, session_id \\ :global) do
    GenServer.call(pid, {:unsubscribe, event_method, subscriber, session_id})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Remove every subscription whose key has the given session_id (any method).
  Cheap O(N) sweep — used at session-end to keep the dispatch table small
  when many ephemeral sessions share one connection.
  """
  def unsubscribe_session(pid, session_id) do
    GenServer.call(pid, {:unsubscribe_session, session_id})
  catch
    :exit, _ -> :ok
  end

  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  # GenServer callbacks

  @impl true
  def init(ws_url) do
    uri = URI.parse(ws_url)
    http_scheme = if uri.scheme in ["wss", "https"], do: :https, else: :http
    ws_scheme = if uri.scheme in ["wss", "https"], do: :wss, else: :ws
    port = uri.port || if(http_scheme == :https, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?#{uri.query}", else: "")

    # Subscribers live in a public ETS table so the receive loop can
    # dispatch events with a single :ets.lookup + send/2, no GenServer
    # round-trip. Each WebSocketClient owns its own table; when the
    # process dies, the table dies with it.
    table =
      :ets.new(:wallabidi_bidi_subscribers, [
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
  def handle_call({:send_command, method, params}, from, %{websocket: nil} = state) do
    # WebSocket handshake not complete yet — queue the command
    queued = state.queued_commands ++ [{from, method, params}]
    {:noreply, %{state | queued_commands: queued}}
  end

  def handle_call({:send_command, method, params}, from, state) do
    if System.get_env("WALLABIDI_TRACE_QUEUE") == "1" do
      {:message_queue_len, qlen} = Process.info(self(), :message_queue_len)

      if qlen > 5,
        do:
          IO.puts(
            ">>> SEND #{method} qlen=#{qlen} pending=#{map_size(state.pending)}"
          )
    end

    state = do_send_command(state, from, method, params)
    {:noreply, state}
  end

  def handle_call(
        {:send_command_flat, method, params, session_id},
        from,
        %{websocket: nil} = state
      ) do
    queued = state.queued_commands ++ [{:flat, from, method, params, session_id}]
    {:noreply, %{state | queued_commands: queued}}
  end

  def handle_call({:send_command_flat, method, params, session_id}, from, state) do
    state = do_send_command_flat(state, from, method, params, session_id)
    {:noreply, state}
  end

  def handle_call({:subscribe, event_method, subscriber, session_id}, {caller, _}, state) do
    target = subscriber || caller
    key = {event_method, session_id}
    existing = lookup_subs(state.subscribers_table, key)
    :ets.insert(state.subscribers_table, {key, [target | List.delete(existing, target)]})
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, event_method, subscriber, session_id}, _from, state) do
    key = {event_method, session_id}
    existing = lookup_subs(state.subscribers_table, key)

    case List.delete(existing, subscriber) do
      [] -> :ets.delete(state.subscribers_table, key)
      list -> :ets.insert(state.subscribers_table, {key, list})
    end

    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe_session, session_id}, _from, state) do
    :ets.match_delete(state.subscribers_table, {{:_, session_id}, :_})
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
  def handle_cast({:cast_command, method, params}, state) do
    state = do_cast_command(state, method, params)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:cast_command_flat, method, params, session_id}, state) do
    state = do_cast_command_flat(state, method, params, session_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        state = process_responses(responses, state)
        {:noreply, state}

      {:error, conn, reason, _responses} ->
        # The transport is broken. Reply :session_closed to any pending
        # callers and terminate so the supervisor / pool can recycle us.
        Logger.debug("BiDi WebSocket error: #{inspect(reason)}")
        reply_all_pending(state, {:error, :session_closed})
        {:stop, {:transport_error, reason}, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn do
      Mint.HTTP.close(state.conn)
    end
  end

  # Private helpers

  defp process_responses(responses, state) do
    Enum.reduce(responses, state, &process_response/2)
  end

  defp process_response({:status, ref, status}, %{ref: ref} = state) do
    if status != 101 do
      Logger.error("BiDi WebSocket upgrade failed with status #{status}")
    end

    %{state | status: status}
  end

  defp process_response({:headers, ref, headers}, %{ref: ref, status: 101} = state) do
    case Mint.WebSocket.new(state.conn, ref, 101, headers) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}
        flush_queued_commands(state)

      {:error, conn, reason} ->
        Logger.error("BiDi WebSocket handshake failed: #{inspect(reason)}")
        %{state | conn: conn}
    end
  end

  defp process_response({:headers, _ref, _headers}, state) do
    state
  end

  defp process_response({:data, ref, data}, %{ref: ref} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        Enum.reduce(frames, state, &process_frame/2)

      {:error, websocket, reason} ->
        Logger.error("BiDi WebSocket decode error: #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  defp process_response(_response, state), do: state

  defp process_frame({:text, text}, state) do
    trace? = System.get_env("WALLABIDI_TRACE_FRAME") == "1"
    t0 = if trace?, do: System.monotonic_time(:microsecond), else: 0

    new_state =
      case Jason.decode(text) do
        {:ok, %{"id" => id} = response} ->
          handle_command_response(state, id, response)

        {:ok, %{"method" => method} = event} ->
          broadcast_event(state, method, event)
          state

        {:error, _} ->
          Logger.warning("BiDi WebSocket received invalid JSON: #{text}")
          state
      end

    if trace? do
      dt = System.monotonic_time(:microsecond) - t0
      if dt > 1000, do: IO.puts(">>> FRAME #{div(dt, 1000)}ms #{String.slice(text, 0, 100)}")
    end

    new_state
  end

  defp process_frame({:close, _code, _reason}, state) do
    reply_all_pending(state, {:error, :websocket_closed})
    state
  end

  defp process_frame(_frame, state), do: state

  defp broadcast_event(state, method, event) do
    # Session-scoped subscribers receive only events for their session.
    # Global subscribers (:global) receive all events regardless of session.
    #
    # CDP carries a flat sessionId at the top level. BiDi events vary —
    # most browsing-context-scoped events carry their context id under
    # `params.context` (or `params.source.context` for log entries). We
    # accept any of those as a session key.
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
      keys
      |> Enum.flat_map(fn k -> lookup_subs(table, {method, k}) end)

    global_pids = lookup_subs(table, {method, :global})

    Enum.each(session_pids ++ global_pids, fn pid ->
      send(pid, {:bidi_event, method, event})
    end)
  end

  defp lookup_subs(table, key) do
    case :ets.lookup(table, key) do
      [{^key, list}] -> list
      [] -> []
    end
  end

  defp reply_all_pending(state, reply) do
    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, reply)
    end)
  end

  defp do_send_command(state, from, method, params) do
    id = state.next_id

    message =
      Jason.encode!(%{
        id: id,
        method: method,
        params: params
      })

    case send_frame(state, {:text, message}) do
      {:ok, state} ->
        pending = Map.put(state.pending, id, from)
        %{state | next_id: id + 1, pending: pending}

      {:error, state, reason} ->
        GenServer.reply(from, {:error, reason})
        state
    end
  end

  defp do_send_command_flat(state, from, method, params, session_id) do
    id = state.next_id

    message =
      %{id: id, method: method, params: params, sessionId: session_id}
      |> Jason.encode!()

    case send_frame(state, {:text, message}) do
      {:ok, state} ->
        pending = Map.put(state.pending, id, from)
        %{state | next_id: id + 1, pending: pending}

      {:error, state, reason} ->
        GenServer.reply(from, {:error, reason})
        state
    end
  end

  defp do_cast_command(state, method, params) do
    id = state.next_id
    message = Jason.encode!(%{id: id, method: method, params: params})

    case send_frame(state, {:text, message}) do
      {:ok, state} ->
        %{state | next_id: id + 1}

      {:error, state, _reason} ->
        state
    end
  end

  defp do_cast_command_flat(state, method, params, session_id) do
    id = state.next_id

    message =
      %{id: id, method: method, params: params, sessionId: session_id}
      |> Jason.encode!()

    case send_frame(state, {:text, message}) do
      {:ok, state} ->
        # No pending entry — response will arrive in handle_command_response
        # and be silently dropped (id not in pending map).
        %{state | next_id: id + 1}

      {:error, state, _reason} ->
        state
    end
  end

  defp flush_queued_commands(%{queued_commands: []} = state), do: state

  defp flush_queued_commands(state) do
    Enum.reduce(state.queued_commands, %{state | queued_commands: []}, fn
      {:flat, from, method, params, session_id}, acc ->
        do_send_command_flat(acc, from, method, params, session_id)

      {from, method, params}, acc ->
        do_send_command(acc, from, method, params)
    end)
  end

  defp handle_command_response(state, id, response) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {from, pending} ->
        result = parse_bidi_response(response)
        GenServer.reply(from, result)
        %{state | pending: pending}
    end
  end

  # BiDi error format: %{"error" => "invalid argument", "message" => "..."}
  defp parse_bidi_response(%{"error" => error, "message" => message}) when is_binary(error),
    do: {:error, {error, message}}

  # CDP error format: %{"error" => %{"code" => -32000, "message" => "..."}}
  defp parse_bidi_response(%{"error" => %{"message" => message} = error}),
    do: {:error, {Map.get(error, "code", "unknown"), message}}

  defp parse_bidi_response(%{"result" => result}), do: {:ok, result}
  defp parse_bidi_response(other), do: {:ok, other}

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
end
