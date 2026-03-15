defmodule Wallaby.BiDi.WebSocketClient do
  @moduledoc false
  # GenServer managing a single WebSocket connection per session using Mint.WebSocket.

  use GenServer
  require Logger

  @default_timeout 10_000

  defstruct [
    :conn,
    :websocket,
    :ref,
    next_id: 1,
    pending: %{},
    subscribers: %{},
    buffer: ""
  ]

  # Public API

  def start_link(ws_url) do
    GenServer.start_link(__MODULE__, ws_url)
  end

  def send_command(pid, method, params, timeout \\ @default_timeout) do
    GenServer.call(pid, {:send_command, method, params}, timeout)
  end

  def subscribe(pid, event_method) do
    GenServer.call(pid, {:subscribe, event_method})
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
    scheme = if uri.scheme in ["wss", "https"], do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?#{uri.query}", else: "")

    with {:ok, conn} <- Mint.HTTP.connect(scheme, uri.host, port),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(scheme, conn, path, []) do
      {:ok, %__MODULE__{conn: conn, ref: ref}}
    else
      {:error, reason} ->
        {:stop, {:connection_failed, reason}}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:stop, {:upgrade_failed, reason}}
    end
  end

  @impl true
  def handle_call({:send_command, method, params}, from, state) do
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
        {:noreply, %{state | next_id: id + 1, pending: pending}}

      {:error, state, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, event_method}, {pid, _}, state) do
    subs = Map.update(state.subscribers, event_method, [pid], &[pid | &1])
    {:reply, :ok, %{state | subscribers: subs}}
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
        state = process_responses(responses, state)
        {:noreply, state}

      {:error, conn, reason, _responses} ->
        Logger.error("BiDi WebSocket error: #{inspect(reason)}")
        {:noreply, %{state | conn: conn}}

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

  defp process_response({:status, ref, status}, %{ref: ref} = state) when status == 101 do
    state
  end

  defp process_response({:status, ref, status}, %{ref: ref} = state) do
    Logger.error("BiDi WebSocket upgrade failed with status #{status}")
    state
  end

  defp process_response({:headers, ref, headers}, %{ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, status(state), headers) do
      {:ok, conn, websocket} ->
        %{state | conn: conn, websocket: websocket}

      {:error, conn, reason} ->
        Logger.error("BiDi WebSocket handshake failed: #{inspect(reason)}")
        %{state | conn: conn}
    end
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
    case Jason.decode(text) do
      {:ok, %{"id" => id} = response} ->
        case Map.pop(state.pending, id) do
          {nil, _pending} ->
            state

          {from, pending} ->
            result =
              case response do
                %{"error" => error, "message" => message} ->
                  {:error, {error, message}}

                %{"result" => result} ->
                  {:ok, result}

                other ->
                  {:ok, other}
              end

            GenServer.reply(from, result)
            %{state | pending: pending}
        end

      {:ok, %{"method" => method} = event} ->
        broadcast_event(state, method, event)
        state

      {:error, _} ->
        Logger.warning("BiDi WebSocket received invalid JSON: #{text}")
        state
    end
  end

  defp process_frame({:close, _code, _reason}, state) do
    reply_all_pending(state, {:error, :websocket_closed})
    state
  end

  defp process_frame(_frame, state), do: state

  defp broadcast_event(state, method, event) do
    pids = Map.get(state.subscribers, method, [])

    Enum.each(pids, fn pid ->
      send(pid, {:bidi_event, method, event})
    end)
  end

  defp reply_all_pending(state, reply) do
    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, reply)
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

  # We need to track the status for the handshake
  defp status(_state), do: 101
end
