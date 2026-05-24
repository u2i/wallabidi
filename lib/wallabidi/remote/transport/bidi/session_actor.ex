defmodule Wallabidi.Remote.Transport.BiDi.SessionActor do
  @moduledoc false

  # One actor per BiDi session. Owns a Wallabidi.Remote.BiDi.WebSocketClient
  # (which in turn owns the Mint WebSocket) and translates
  # Transport.Protocol calls into BiDi commands & event waits.
  #
  # The actor's lifetime IS the session's lifetime: it monitors the
  # WSC and its owner, and tears down both when either dies.

  use GenServer

  require Logger

  alias Wallabidi.Remote.BiDi.WebSocketClient
  alias Wallabidi.Remote.Transport.Common
  alias Wallabidi.Remote.Wire

  defstruct [
    :ws_pid,
    :ws_ref,
    :owner,
    :owner_ref,
    :session,
    :teardown_fun,
    frame_stack: [],
    frame_contexts: %{},
    # `%{navigation_id => %{milestone_name => true}}` for load events
    # that arrived before any caller asked, plus a waiter list of
    # `{from, navigation_id_or_:any, milestone_name, timer_ref}`.
    loads: %{},
    load_waiters: [],
    # Each find_waiter is keyed by query_id, valued by
    # `{:pending, timer_ref, from_or_nil}` or `{:resolved, result}`.
    find_waiters: %{},
    last_page_id: nil,
    # `{from, pre_page_id, timer_ref}` when someone's awaiting a
    # page_ready transition; `nil` otherwise.
    page_ready_waiter: nil,
    # Set true when bootstrap sees an LV `live_redirect`/`redirect` —
    # used by Common.await_page_ready_after to extend the timeout.
    nav_pending: false
  ]

  # ----- Public API -----

  @spec start_link(keyword) ::
          {:ok, Wallabidi.Session.t()} | {:error, term}
  def start_link(opts) do
    # Use `start` rather than `start_link` so the caller (typically a
    # test process) isn't taken down by an EXIT signal if init/1 fails
    # (e.g. session.subscribe timeout). The actor still tracks its
    # owner via Process.monitor and terminates cleanly when the owner
    # exits.
    case GenServer.start(__MODULE__, opts) do
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
         :ok <- subscribe_load_events(ws_pid),
         {:ok, session_struct} <- init_fun.() do
      ws_ref = Process.monitor(ws_pid)
      owner_ref = Process.monitor(owner)

      # Patch the session's `pid` to point at this actor — that's
      # what Transport.Protocol callers will dispatch through.
      session = %{session_struct | pid: self(), bidi_pid: ws_pid}

      # Register with SessionStore so Wallabidi.Feature can discover
      # this session for failure-screenshot / sandbox cleanup. Same
      # contract Session honors for the two-actor model.
      try do
        Wallabidi.SessionStore.register(session, owner)
      catch
        :exit, _ -> :ok
      end

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

  # Subscribe to load milestones + bootstrap channel + log entries
  # in a single server-side session.subscribe call. WSC-side
  # forward-to-this-pid is set up for the events the actor needs to
  # consume (loads + script.message); log.entryAdded is forwarded
  # to other subscribers (e.g. the test process for LogChecker).
  defp subscribe_load_events(ws_pid) do
    events = [
      "browsingContext.load",
      "browsingContext.domContentLoaded",
      "script.message",
      "log.entryAdded"
    ]

    Enum.each(events, fn ev ->
      WebSocketClient.subscribe(ws_pid, ev, self(), :global)
    end)

    # The first session.subscribe after browser launch can take a
    # while on slow runners (GHA Linux) because chromium-bidi's Mapper
    # is still settling. 12s lets us retry up to 4× (SessionCase) and
    # still fit inside ExUnit's default 60s test timeout. Subsequent
    # subscribes are fast (<200ms) so the actual cap rarely fires.
    timeout = Application.get_env(:wallabidi, :bidi_subscribe_timeout_ms, 12_000)

    case WebSocketClient.send_command(
           ws_pid,
           "session.subscribe",
           %{"events" => events},
           timeout
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:subscribe_failed, reason}}
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

  def handle_call(:current_context_id, _from, state) do
    {:reply, Common.current_context_id(state), state}
  end

  def handle_call({:push_frame, context_id}, _from, state) do
    {:reply, :ok, Common.push_frame(state, context_id)}
  end

  def handle_call(:pop_frame, _from, state) do
    {:reply, :ok, Common.pop_frame(state)}
  end

  # Pop and return the head value, so the driver can switch the
  # browsing_context back to the parent in one round-trip.
  def handle_call(:pop_frame_value, _from, state) do
    case state.frame_stack do
      [] -> {:reply, :empty, state}
      [head | rest] -> {:reply, {:ok, head}, %{state | frame_stack: rest}}
    end
  end

  def handle_call(:reset_frame_stack, _from, state),
    do: {:reply, :ok, %{state | frame_stack: []}}

  def handle_call({:record_frame_context, frame_id, context_id}, _from, state) do
    {:reply, :ok, Common.record_frame_context(state, frame_id, context_id)}
  end

  def handle_call({:lookup_frame_context, frame_id}, _from, state) do
    {:reply, Common.lookup_frame_context(state, frame_id), state}
  end

  def handle_call({:update_browsing_context, _session_id, target_id}, _from, state) do
    session = %{state.session | browsing_context: target_id}
    {:reply, :ok, %{state | session: session}}
  end

  # ----- Page-load awaits (Phase B) -----

  def handle_call({:await_page_load, loader_id, name, timeout_ms}, from, state) do
    case get_in(state.loads, [loader_id, name]) do
      true ->
        {:reply, :ok, drop_load(state, loader_id, name)}

      _ ->
        timer_ref = Process.send_after(self(), {:page_load_timeout, from}, timeout_ms)
        waiters = [{from, loader_id, name, timer_ref} | state.load_waiters]
        {:noreply, %{state | load_waiters: waiters}}
    end
  end

  def handle_call({:await_next_page_load, name, timeout_ms}, from, state) do
    already =
      Enum.any?(state.loads, fn {_nav, milestones} ->
        Map.get(milestones, name, false)
      end)

    if already do
      {:reply, :ok, %{state | loads: %{}}}
    else
      timer_ref = Process.send_after(self(), {:page_load_timeout, from}, timeout_ms)
      waiters = [{from, :any, name, timer_ref} | state.load_waiters]
      {:noreply, %{state | loads: %{}, load_waiters: waiters}}
    end
  end

  # ----- Bootstrap channel (Phase C) -----

  def handle_call({:await_page_ready_after, pre_page_id, timeout_ms}, from, state) do
    Common.await_page_ready_after(state, pre_page_id, timeout_ms, from)
  end

  def handle_call({:register_find, query_id, timeout_ms}, _from, state) do
    {:reply, :ok, Common.register_find(state, query_id, timeout_ms)}
  end

  def handle_call({:await_find_result, query_id}, from, state) do
    Common.await_find_result(state, query_id, from)
  end

  # ----- Cast -----

  @impl true
  def handle_cast({:cdp_cast, method, params, _opts}, state) do
    WebSocketClient.cast_command(state.ws_pid, method, normalize_params(params))
    {:noreply, state}
  end

  # ----- Inbound -----

  @impl true
  def handle_info({:bidi_event, method, event}, state) do
    {:noreply, Wire.BiDi.handle_event(state, method, event)}
  end

  def handle_info({:find_timeout, query_id}, state) do
    {:noreply, Common.handle_find_timeout(state, query_id)}
  end

  def handle_info({:page_ready_timeout, from}, state) do
    {:noreply, Common.handle_page_ready_timeout(state, from)}
  end

  def handle_info({:page_load_timeout, from}, state) do
    case Enum.split_with(state.load_waiters, fn {f, _, _, _} -> f == from end) do
      {[{from, _, _, _}], rest} ->
        GenServer.reply(from, :timeout)
        {:noreply, %{state | load_waiters: rest}}

      _ ->
        # Already resolved — the timeout was racing the reply.
        {:noreply, state}
    end
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
    try do
      Wallabidi.SessionStore.unregister(state.session)
    catch
      :exit, _ -> :ok
    end

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
          Logger.warning("Transport.BiDi teardown failed: #{inspect({kind, err})}")
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

  # After consuming a buffered (nav, milestone), drop it so a future
  # caller for the same pair has to wait for a fresh event.
  defp drop_load(state, nav, name) do
    case Map.get(state.loads, nav) do
      nil ->
        state

      inner ->
        case Map.delete(inner, name) do
          empty when map_size(empty) == 0 ->
            %{state | loads: Map.delete(state.loads, nav)}

          remaining ->
            %{state | loads: Map.put(state.loads, nav, remaining)}
        end
    end
  end
end
