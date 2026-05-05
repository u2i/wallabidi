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
    frame_contexts: %{},
    # Page-load bookkeeping (Phase B). `loads` buffers
    # `%{navigation_id => %{milestone_name => true}}` for events that
    # arrived before any caller asked. `load_waiters` is a list of
    # `{from, navigation_id_or_:any, milestone_name, timer_ref}`.
    loads: %{},
    load_waiters: [],
    # Bootstrap channel bookkeeping (Phase C). Each find_waiter is
    # keyed by query_id, valued by `{:pending, timer_ref, from_or_nil}`
    # or `{:resolved, result}` once the bootstrap channel has fired.
    find_waiters: %{},
    # The most recent pageId reported by the bootstrap.
    last_page_id: nil,
    # `{from, pre_page_id, timer_ref}` when someone's awaiting a
    # page_ready transition; `nil` otherwise.
    page_ready_waiter: nil
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
         :ok <- subscribe_load_events(ws_pid),
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

  # Subscribe to load milestones + bootstrap channel at session start.
  # Server-side `session.subscribe` plus WSC-side forward-to-this-pid.
  # Idempotent on the BiDi server side — calling it twice is harmless.
  defp subscribe_load_events(ws_pid) do
    events = [
      "browsingContext.load",
      "browsingContext.domContentLoaded",
      "script.message"
    ]

    Enum.each(events, fn ev ->
      WebSocketClient.subscribe(ws_pid, ev, self(), :global)
    end)

    case WebSocketClient.send_command(
           ws_pid,
           "session.subscribe",
           %{"events" => events},
           10_000
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
    cond do
      pre_page_id != nil and state.last_page_id != nil and
          state.last_page_id != pre_page_id ->
        {:reply, :ok, state}

      true ->
        timer_ref = Process.send_after(self(), {:page_ready_timeout, from}, timeout_ms)
        {:noreply, %{state | page_ready_waiter: {from, pre_page_id, timer_ref}}}
    end
  end

  def handle_call({:register_find, query_id, timeout_ms}, _from, state) do
    timer_ref = Process.send_after(self(), {:find_timeout, query_id}, timeout_ms)
    waiters = Map.put(state.find_waiters, query_id, {:pending, timer_ref, nil})
    {:reply, :ok, %{state | find_waiters: waiters}}
  end

  def handle_call({:await_find_result, query_id}, from, state) do
    case Map.get(state.find_waiters, query_id) do
      {:resolved, result} ->
        waiters = Map.delete(state.find_waiters, query_id)
        {:reply, result, %{state | find_waiters: waiters}}

      {:pending, timer_ref, nil} ->
        waiters = Map.put(state.find_waiters, query_id, {:pending, timer_ref, from})
        {:noreply, %{state | find_waiters: waiters}}

      nil ->
        {:reply, {:timeout, 0}, state}
    end
  end

  # ----- Cast -----

  @impl true
  def handle_cast({:cdp_cast, method, params, _opts}, state) do
    WebSocketClient.cast_command(state.ws_pid, method, normalize_params(params))
    {:noreply, state}
  end

  # ----- Inbound -----

  @impl true
  def handle_info({:bidi_event, "browsingContext.load", event}, state) do
    nav = get_in(event, ["params", "navigation"])

    if is_binary(nav) do
      {:noreply, record_load(state, nav, "load")}
    else
      {:noreply, state}
    end
  end

  def handle_info({:bidi_event, "browsingContext.domContentLoaded", event}, state) do
    nav = get_in(event, ["params", "navigation"])

    if is_binary(nav) do
      {:noreply, record_load(state, nav, "DOMContentLoaded")}
    else
      {:noreply, state}
    end
  end

  def handle_info({:bidi_event, "script.message", event}, state) do
    params = Map.get(event, "params", %{})

    if params["channel"] == "__wallabidi" do
      payload = get_in(params, ["data", "value"]) || ""
      {:noreply, route_channel_payload(state, payload)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:bidi_event, _method, _event}, state) do
    # log.entryAdded, browsingContext.userPromptOpened, etc. — not
    # handled at the transport level; consumers can subscribe directly.
    {:noreply, state}
  end

  def handle_info({:find_timeout, query_id}, state) do
    case Map.pop(state.find_waiters, query_id) do
      {nil, _} ->
        {:noreply, state}

      {{:resolved, _}, _rest} ->
        # Already resolved — keep the entry; the awaiter will pop it.
        {:noreply, state}

      {{:pending, _ref, nil}, rest} ->
        {:noreply, %{state | find_waiters: rest}}

      {{:pending, _ref, from}, rest} ->
        GenServer.reply(from, {:timeout, 0})
        {:noreply, %{state | find_waiters: rest}}
    end
  end

  def handle_info({:page_ready_timeout, from}, state) do
    case state.page_ready_waiter do
      {^from, _pre, _ref} ->
        GenServer.reply(from, :timeout)
        {:noreply, %{state | page_ready_waiter: nil}}

      _ ->
        {:noreply, state}
    end
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

  # Decode a __wallabidi channel payload (JSON-stringified by the
  # bootstrap) and dispatch to find_waiters or page_ready_waiter.
  # Format mirrors the legacy SessionProcess decoder so the bootstrap
  # JS doesn't need a BiDi-specific variant.
  defp route_channel_payload(state, payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"id" => query_id, "error" => err}} when is_binary(err) ->
        resolve_find(state, query_id, {:error, :invalid_selector})

      {:ok, %{"id" => query_id, "count" => count} = msg} ->
        resolve_find(state, query_id, {:ok, count, msg["meta"]})

      {:ok, %{"type" => "page_ready", "pageId" => page_id}} ->
        state = %{state | last_page_id: page_id}
        wake_page_ready_waiter(state, page_id)

      _ ->
        state
    end
  end

  defp route_channel_payload(state, _), do: state

  defp resolve_find(state, query_id, result) do
    case Map.get(state.find_waiters, query_id) do
      nil ->
        state

      {:pending, timer_ref, nil} ->
        Process.cancel_timer(timer_ref)
        %{state | find_waiters: Map.put(state.find_waiters, query_id, {:resolved, result})}

      {:pending, timer_ref, from} ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, result)
        %{state | find_waiters: Map.delete(state.find_waiters, query_id)}

      {:resolved, _} ->
        state
    end
  end

  defp wake_page_ready_waiter(state, page_id) do
    case state.page_ready_waiter do
      {from, pre_page_id, timer_ref} when pre_page_id != page_id ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, :ok)
        %{state | page_ready_waiter: nil}

      _ ->
        state
    end
  end

  # Wake any waiter whose (navigation_id, milestone) matches — or
  # whose loader is the `:any` wildcard (await_next_page_load).
  # If no waiter is registered, buffer the milestone so a later
  # caller sees it immediately.
  defp record_load(state, nav, name) do
    {matching, rest} =
      Enum.split_with(state.load_waiters, fn {_from, lid, n, _ref} ->
        (lid == nav or lid == :any) and n == name
      end)

    case matching do
      [] ->
        inner = Map.put(Map.get(state.loads, nav, %{}), name, true)
        %{state | loads: Map.put(state.loads, nav, inner)}

      _ ->
        Enum.each(matching, fn {from, _, _, ref} ->
          Process.cancel_timer(ref)
          GenServer.reply(from, :ok)
        end)

        %{state | load_waiters: rest}
    end
  end

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
