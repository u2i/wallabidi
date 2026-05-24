defmodule Wallabidi.Remote.Transport.PerSession.Actor do
  @moduledoc false

  # Single GenServer per session. Owns:
  #
  #   * the raw Mint WebSocket (conn + ref + websocket)
  #   * per-session state (pending_calls, find_waiters, load_waiters,
  #     page_ready_waiter, frame_stack, frame_contexts, last_page_id)
  #
  # All inbound WS frames AND all outbound caller calls land in ONE
  # mailbox in arrival order. Causal ordering between events and
  # responses is preserved without a barrier.
  #
  # Compared to today's WebSocket + Session pair, this actor
  # eliminates the inter-process hop on every cdp_send: caller →
  # actor.cdp_send is one GenServer.call instead of two.
  #
  # Implements the Wallabidi.Remote.Transport.Protocol message contract
  # so CDPClient can drive it the same way it drives Session.

  use GenServer
  require Logger

  alias Wallabidi.Remote.Transport.Common
  alias Wallabidi.Remote.Wire

  defstruct [
    # ----- Connection state (was WebSocket) -----
    :conn,
    :ref,
    :websocket,
    :status,
    # ----- Per-session state (was Session) -----
    :session,
    :owner_ref,
    :teardown_fun,
    :page_ready_waiter,
    :last_page_id,
    next_id: 1,
    queued: [],
    pending_calls: %{},
    loads: %{},
    load_waiters: [],
    find_waiters: %{},
    frame_stack: [],
    frame_contexts: %{},
    # Bootstrap-reported "transition in flight" flag — extends the
    # page_ready timeout while LV finishes the destination mount.
    nav_pending: false
  ]

  # ----- Lifecycle -----

  @doc """
  Starts the actor. The session struct will have its `pid` field
  filled in to point at this process — that's how the rest of the
  system finds the transport actor.

  Opts:
    * `:ws_url` (required) — websocket URL to connect to
    * `:init_fun` — 0-arity returning `{:ok, %Wallabidi.Session{}}`
    * `:teardown_fun` — 1-arity called from `terminate/2`
    * `:owner` — process to monitor; when it dies we self-stop
  """
  @spec start_link(keyword) :: {:ok, Wallabidi.Session.t()} | {:error, term}
  def start_link(opts) do
    ws_url = Keyword.fetch!(opts, :ws_url)
    init_fun = Keyword.fetch!(opts, :init_fun)
    teardown_fun = Keyword.fetch!(opts, :teardown_fun)
    owner = Keyword.get(opts, :owner, self())

    case GenServer.start(__MODULE__, {ws_url, init_fun, teardown_fun, owner}) do
      {:ok, pid} ->
        session = GenServer.call(pid, :get_session)
        {:ok, %{session | pid: pid}}

      {:error, {:init_failed, reason}} ->
        {:error, reason}

      other ->
        other
    end
  end

  # ----- GenServer init -----

  @impl true
  def init({ws_url, init_fun, teardown_fun, owner}) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(owner)

    uri = URI.parse(ws_url)
    http_scheme = if uri.scheme in ["wss", "https"], do: :https, else: :http
    ws_scheme = if uri.scheme in ["wss", "https"], do: :wss, else: :ws
    port = uri.port || if(http_scheme == :https, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?#{uri.query}", else: "")

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, port),
         {:ok, conn, mint_ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, []),
         {:ok, %Wallabidi.Session{} = session} <- init_fun.() do
      session = %{session | pid: self()}

      try do
        Wallabidi.SessionStore.register(session, owner)
      catch
        :exit, _ -> :ok
      end

      state = %__MODULE__{
        conn: conn,
        ref: mint_ref,
        session: session,
        owner_ref: ref,
        teardown_fun: teardown_fun
      }

      {:ok, state}
    else
      {:error, reason} ->
        {:stop, {:init_failed, reason}}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:stop, {:init_failed, {:upgrade_failed, reason}}}
    end
  end

  # ----- Outbound: the Protocol message contract -----

  @impl true
  def handle_call(:get_session, _from, state) do
    {:reply, state.session, state}
  end

  def handle_call({:update_browsing_context, session_id, target_id}, _from, state) do
    new_session = %{
      state.session
      | browsing_context: session_id,
        capabilities: Map.put(state.session.capabilities, :target_id, target_id)
    }

    {:reply, :ok, %{state | session: new_session}}
  end

  def handle_call(:reset_frame_stack, _from, state) do
    {:reply, :ok, %{state | frame_stack: []}}
  end

  def handle_call({:cdp_send, method, params, opts}, from, state) do
    # Override session_id with our LIVE browsing_context (caller's
    # struct may be stale after focus_window/2).
    opts = override_session_id(opts, state)

    {wire_id, state} = assign_wire_id(state)

    case do_send(state, wire_id, method, params, opts) do
      {:ok, state} ->
        t0 = Wallabidi.Bench.Timing.mark_now()
        pending = Map.put(state.pending_calls, wire_id, {from, t0, method})
        {:noreply, %{state | pending_calls: pending}}

      {:error, state, reason} ->
        # Send failed at the WS layer (e.g. socket closed). Reply now;
        # don't register a pending entry that will never resolve.
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, _event_method, _routing_key}, _from, state) do
    # No-op: this actor owns the WS and processes every event itself.
    # The "subscribe" concept exists to feed the Multiplexed transport's
    # routing table; PerSession doesn't need it.
    {:reply, :ok, state}
  end

  def handle_call({:await_page_load, loader_id, name, timeout_ms}, from, state) do
    if get_in(state.loads, [loader_id, name]) do
      {:reply, :ok, state}
    else
      timer_ref = Process.send_after(self(), {:load_timeout, from}, timeout_ms)
      waiter = {from, loader_id, name, timer_ref}
      {:noreply, %{state | load_waiters: [waiter | state.load_waiters]}}
    end
  end

  def handle_call({:await_next_page_load, name, timeout_ms}, from, state) do
    already_loaded =
      Enum.any?(state.loads, fn {_loader_id, milestones} ->
        Map.get(milestones, name, false)
      end)

    if already_loaded do
      {:reply, :ok, %{state | loads: %{}}}
    else
      timer_ref = Process.send_after(self(), {:load_timeout, from}, timeout_ms)
      waiter = {from, :any, name, timer_ref}
      {:noreply, %{state | loads: %{}, load_waiters: [waiter | state.load_waiters]}}
    end
  end

  def handle_call(:sync_barrier, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:register_find, query_id, timeout_ms}, _from, state) do
    {:reply, :ok, Common.register_find(state, query_id, timeout_ms)}
  end

  def handle_call({:await_find_result, query_id}, from, state) do
    Common.await_find_result(state, query_id, from)
  end

  def handle_call({:await_page_ready_after, pre_page_id, timeout_ms}, from, state) do
    Common.await_page_ready_after(state, pre_page_id, timeout_ms, from)
  end

  def handle_call(:current_context_id, _from, state) do
    {:reply, Common.current_context_id(state), state}
  end

  def handle_call({:push_frame, context_id}, _from, state) do
    {:reply, :ok, Common.push_frame(state, context_id)}
  end

  def handle_call(:pop_frame, _from, state) do
    {:reply, :ok, Common.pop_frame(state)}
  end

  def handle_call({:record_frame_context, frame_id, context_id}, _from, state) do
    {:reply, :ok, Common.record_frame_context(state, frame_id, context_id)}
  end

  def handle_call({:lookup_frame_context, frame_id}, _from, state) do
    {:reply, Common.lookup_frame_context(state, frame_id), state}
  end

  @impl true
  def handle_cast({:cdp_cast, method, params, opts}, state) do
    opts = override_session_id(opts, state)
    {wire_id, state} = assign_wire_id(state)

    case do_send(state, wire_id, method, params, opts) do
      {:ok, state} ->
        # No pending entry — response will be dropped when it arrives.
        {:noreply, state}

      {:error, state, _reason} ->
        # Best-effort; nothing to report to.
        {:noreply, state}
    end
  end

  # ----- Inbound: WS frames + timer messages -----

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        state = Enum.reduce(responses, state, &process_response/2)
        {:noreply, state}

      {:error, conn, reason, _responses} ->
        Logger.warning(
          "PerSession.Actor transport error pid=#{inspect(self())} reason=#{inspect(reason)}"
        )

        notify_all_pending(state, {:error, :session_closed})
        {:stop, {:transport_error, reason}, %{state | conn: conn}}

      :unknown ->
        # Not a Mint message — handle our own kinds.
        handle_internal_message(message, state)
    end
  end

  # ----- Internal (non-Mint) messages -----

  defp handle_internal_message({:load_timeout, from}, state) do
    case Enum.split_with(state.load_waiters, fn {f, _, _, _} -> f == from end) do
      {[], _} ->
        {:noreply, state}

      {[{^from, _l, _n, _ref} | _], rest} ->
        GenServer.reply(from, :timeout)
        {:noreply, %{state | load_waiters: rest}}
    end
  end

  defp handle_internal_message({:page_ready_timeout, from}, state) do
    {:noreply, Common.handle_page_ready_timeout(state, from)}
  end

  defp handle_internal_message({:find_timeout, query_id}, state) do
    {:noreply, Common.handle_find_timeout(state, query_id)}
  end

  defp handle_internal_message({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  defp handle_internal_message(_msg, state), do: {:noreply, state}

  # ----- Termination -----

  @impl true
  def terminate(_reason, %{teardown_fun: fun, session: session, conn: conn})
      when is_function(fun, 1) do
    try do
      Wallabidi.SessionStore.unregister(session)
    catch
      :exit, _ -> :ok
    end

    if conn, do: Mint.HTTP.close(conn)

    try do
      fun.(session)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, %{conn: conn}) do
    if conn, do: Mint.HTTP.close(conn)
    :ok
  end

  # ----- WS frame processing (was WebSocket.process_response/_frame) -----

  defp process_response({:status, ref, status}, %{ref: ref} = state) do
    if status != 101 do
      Logger.error("PerSession.Actor upgrade failed with status #{status}")
    end

    %{state | status: status}
  end

  defp process_response({:headers, ref, headers}, %{ref: ref, status: 101} = state) do
    case Mint.WebSocket.new(state.conn, ref, 101, headers) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}
        flush_queued(state)

      {:error, conn, reason} ->
        Logger.error("PerSession.Actor handshake failed: #{inspect(reason)}")
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
        Logger.error("PerSession.Actor decode error: #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  defp process_response(_response, state), do: state

  defp process_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"id" => id} = response} ->
        deliver_response(state, id, response)

      {:ok, %{"method" => method} = event} ->
        Wire.CDP.handle_event(state, method, event)

      {:error, _} ->
        Logger.warning("PerSession.Actor invalid JSON: #{inspect(String.slice(text, 0, 200))}")

        state
    end
  end

  defp process_frame({:close, _code, _reason}, state) do
    notify_all_pending(state, {:error, :websocket_closed})
    state
  end

  defp process_frame(_frame, state), do: state

  # ----- Response delivery -----

  defp deliver_response(state, id, response) do
    case Map.pop(state.pending_calls, id) do
      {nil, _} ->
        # Fire-and-forget cast or stale id. Drop.
        state

      {{from, t0, method}, pending} ->
        Wallabidi.Bench.Timing.record(t0, method)
        GenServer.reply(from, parse_response(response))
        %{state | pending_calls: pending}
    end
  end

  # ----- Wire frame send -----

  defp assign_wire_id(state) do
    {state.next_id, %{state | next_id: state.next_id + 1}}
  end

  defp do_send(%{websocket: nil} = state, id, method, params, opts) do
    # Connection still upgrading. Queue the frame; flushed when 101
    # arrives.
    queued = state.queued ++ [{id, method, params, opts}]
    {:ok, %{state | queued: queued}}
  end

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
        %{base | params: Map.put(params, :sessionId, session_id)}

      true ->
        base
    end
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

  defp flush_queued(%{queued: []} = state), do: state

  defp flush_queued(state) do
    Enum.reduce(state.queued, %{state | queued: []}, fn {id, method, params, opts}, acc ->
      case do_send(acc, id, method, params, opts) do
        {:ok, acc} ->
          acc

        {:error, acc, reason} ->
          # Reply to any caller waiting on this id.
          case Map.pop(acc.pending_calls, id) do
            {nil, _} ->
              acc

            {{from, _t0, _method}, rest} ->
              GenServer.reply(from, {:error, reason})
              %{acc | pending_calls: rest}
          end
      end
    end)
  end

  defp override_session_id(opts, state) do
    case Keyword.fetch(opts, :session_id) do
      {:ok, _} when is_binary(state.session.browsing_context) ->
        Keyword.put(opts, :session_id, state.session.browsing_context)

      _ ->
        opts
    end
  end

  defp notify_all_pending(state, reply) do
    Enum.each(state.pending_calls, fn {_id, {from, _t0, _method}} ->
      try do
        GenServer.reply(from, reply)
      catch
        _, _ -> :ok
      end
    end)
  end

  defp parse_response(%{"error" => error, "message" => message}) when is_binary(error),
    do: {:error, {error, message}}

  defp parse_response(%{"error" => %{"message" => message} = error}),
    do: {:error, {Map.get(error, "code", "unknown"), message}}

  defp parse_response(%{"result" => result}), do: {:ok, result}
  defp parse_response(other), do: {:ok, other}
end
