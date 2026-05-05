defmodule Wallabidi.V2.Transport.BiDi.SessionActor do
  @moduledoc false

  # One actor per BiDi session. Owns a Wallabidi.BiDi.WebSocketClient
  # (which in turn owns the Mint WebSocket) and translates V2
  # Transport.Protocol calls into BiDi commands & event waits.
  #
  # The actor's lifetime IS the session's lifetime: it monitors the
  # WSC and its owner, and tears down both when either dies.
  #
  # ## Phase A scope
  #
  # This is the minimal first pass — it implements the synchronous
  # passthrough surface (get_session, cdp_send/cast, subscribe,
  # sync_barrier, frame stack, page id/state) so the V2BiDiDriver can
  # be wired up end-to-end. Page-load awaits and bootstrap channel
  # routing (find/page_ready) are stubbed and will be filled in by
  # Phases B and C.

  use GenServer

  require Logger

  alias Wallabidi.BiDi.WebSocketClient

  defstruct [
    :ws_pid,
    :ws_ref,
    :owner,
    :owner_ref,
    :session,
    :teardown_fun,
    page_id: nil,
    frame_stack: [],
    frame_contexts: %{}
  ]

  # ----- Public API -----

  @spec start_link(keyword) ::
          {:ok, Wallabidi.Session.t()} | {:error, term}
  def start_link(opts) do
    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} ->
        # Pull the session struct now that the actor's running, with
        # its `pid` field correctly set to the actor.
        session = GenServer.call(pid, :get_session)
        {:ok, session}

      {:error, _} = err ->
        err
    end
  end

  # ----- GenServer callbacks -----

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    ws_url = Keyword.fetch!(opts, :ws_url)
    init_fun = Keyword.fetch!(opts, :init_fun)
    teardown_fun = Keyword.get(opts, :teardown_fun, fn _ -> :ok end)
    owner = Keyword.get(opts, :owner, self())

    with {:ok, ws_pid} <- WebSocketClient.start_link(ws_url),
         {:ok, session_struct} <- init_fun.() do
      ws_ref = Process.monitor(ws_pid)
      owner_ref = Process.monitor(owner)

      # Patch the session's `pid` to point at this actor — that's
      # what V2.Transport.Protocol callers will dispatch through.
      session = %{session_struct | pid: self(), bidi_pid: ws_pid}

      {:ok,
       %__MODULE__{
         ws_pid: ws_pid,
         ws_ref: ws_ref,
         owner: owner,
         owner_ref: owner_ref,
         session: session,
         teardown_fun: teardown_fun
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # ----- Transport.Protocol contract -----

  @impl true
  def handle_call(:get_session, _from, state),
    do: {:reply, state.session, state}

  def handle_call({:cdp_send, method, params, _opts}, from, state) do
    # Forward to the WSC. Don't block this actor — spawn a tiny
    # waiter that does the call and replies on our behalf, so other
    # mailbox traffic (events from the same WS) can interleave.
    parent = self()

    spawn_link(fn ->
      result =
        WebSocketClient.send_command(state.ws_pid, method, normalize_params(params), 30_000)

      GenServer.reply(from, result)
      send(parent, {:done_send, self()})
    end)

    {:noreply, state}
  end

  def handle_call({:subscribe, event_method, _routing_key}, _from, state) do
    # Two-step BiDi subscribe: ask the server to send us this event
    # (session.subscribe) AND tell the WSC to forward matching frames
    # to this actor's mailbox. session.subscribe is idempotent on the
    # server side — duplicate subscribes are no-ops.
    WebSocketClient.subscribe(state.ws_pid, event_method, self(), :global)

    _ =
      WebSocketClient.send_command(
        state.ws_pid,
        "session.subscribe",
        %{"events" => [event_method]},
        10_000
      )

    {:reply, :ok, state}
  end

  def handle_call(:sync_barrier, _from, state), do: {:reply, :ok, state}

  def handle_call(:get_page_id, _from, state),
    do: {:reply, state.page_id, state}

  def handle_call(:get_page_state, _from, state),
    do: {:reply, {:lv_ready, []}, state}

  def handle_call(:current_context_id, _from, state) do
    case state.frame_stack do
      [] -> {:reply, nil, state}
      [top | _] -> {:reply, top, state}
    end
  end

  def handle_call({:push_frame, context_id}, _from, state) do
    {:reply, :ok, %{state | frame_stack: [context_id | state.frame_stack]}}
  end

  def handle_call(:pop_frame, _from, state) do
    stack =
      case state.frame_stack do
        [] -> []
        [_ | rest] -> rest
      end

    {:reply, :ok, %{state | frame_stack: stack}}
  end

  def handle_call(:reset_frame_stack, _from, state),
    do: {:reply, :ok, %{state | frame_stack: []}}

  def handle_call({:record_frame_context, frame_id, context_id}, _from, state) do
    {:reply, :ok, %{state | frame_contexts: Map.put(state.frame_contexts, frame_id, context_id)}}
  end

  def handle_call({:lookup_frame_context, frame_id}, _from, state) do
    {:reply, Map.get(state.frame_contexts, frame_id), state}
  end

  def handle_call({:update_browsing_context, _session_id, target_id}, _from, state) do
    session = %{state.session | browsing_context: target_id}
    {:reply, :ok, %{state | session: session}}
  end

  # ----- Phase B/C stubs (to be implemented) -----

  def handle_call({:await_page_load, _loader_id, _name, _timeout_ms}, _from, state),
    do: {:reply, :ok, state}

  def handle_call({:await_next_page_load, _name, _timeout_ms}, _from, state),
    do: {:reply, :ok, state}

  def handle_call({:await_page_ready_after, _pre_page_id, _timeout_ms}, _from, state),
    do: {:reply, :ok, state}

  def handle_call({:register_find, _query_id, _timeout_ms}, _from, state),
    do: {:reply, :ok, state}

  def handle_call({:await_find_result, _query_id}, _from, state),
    do: {:reply, {:timeout, 0}, state}

  # ----- Cast -----

  @impl true
  def handle_cast({:cdp_cast, method, params, _opts}, state) do
    WebSocketClient.cast_command(state.ws_pid, method, normalize_params(params))
    {:noreply, state}
  end

  # ----- Inbound -----

  @impl true
  def handle_info({:bidi_event, _method, _event}, state) do
    # Phase A: ignore. Phase B/C will route loads + script.message.
    {:noreply, state}
  end

  def handle_info({:done_send, _pid}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ws_ref: ref} = state) do
    {:stop, {:ws_down, reason}, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, %{ws_pid: pid} = state) do
    {:stop, {:ws_exit, reason}, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # ----- Termination -----

  @impl true
  def terminate(_reason, state) do
    if state.ws_pid && Process.alive?(state.ws_pid) do
      try do
        WebSocketClient.close(state.ws_pid)
      catch
        :exit, _ -> :ok
      end
    end

    if is_function(state.teardown_fun, 1) do
      try do
        state.teardown_fun.(state.session)
      catch
        kind, err ->
          Logger.warning("V2.Transport.BiDi teardown failed: #{inspect({kind, err})}")
      end
    end

    :ok
  end

  # ----- Helpers -----

  # WebSocketClient expects string-keyed params (BiDi is JSON over the wire).
  # CDPClient often passes atom-keyed maps. Normalize either way.
  defp normalize_params(params) when is_map(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_params(other), do: other
end
