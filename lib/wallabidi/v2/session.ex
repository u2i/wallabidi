defmodule Wallabidi.V2.Session do
  @moduledoc false

  # Per-session coordinator. Owns:
  #
  #   * the session struct (`%Wallabidi.Session{}` with caps/url/etc.)
  #   * a pending-CDP-calls map (wire id → caller `from`) so RPCs
  #     issued via `cdp_send/3` can return synchronously
  #   * page-load buffering, find waiters, page-ready waiters,
  #     page-state machine — all the per-session state today's
  #     `SessionProcess` carries
  #
  # Key property: events from the V2.WebSocket and synchronous calls
  # from the test process arrive in ONE mailbox. FIFO ordering means
  # the test process can never observe state earlier than what was
  # implied by events the WebSocket already delivered. No barrier.
  #
  # This is built alongside the existing `SessionProcess` — nothing
  # in the live code path uses it yet. We migrate one driver at a
  # time.

  use GenServer
  require Logger

  alias Wallabidi.V2.WebSocket

  defstruct [
    :session,
    :ws_pid,
    :owner_ref,
    :teardown_fun,
    # wire_id → GenServer.from for in-flight cdp_send calls
    pending_calls: %{},
    # Page-load buffering: events that have already fired, keyed by
    # `{loader_id, milestone}` (e.g. {"abc123", "load"}). Callers
    # arriving AFTER the event get an immediate reply. Callers arriving
    # BEFORE join `load_waiters` and get woken when the matching event
    # lands.
    loads: %{},
    load_waiters: [],
    # Push-based find waiters. The find flow:
    #   1. Caller calls register_find(query_id, timeout) — stashes
    #      a {:pending, timeout_ref, nil} entry.
    #   2. Caller fires JS that injects a query into window.__w.queries
    #      and arranges for __wallabidi(...) to be called when matched.
    #   3. The Runtime.bindingCalled event arrives here as a v2_event;
    #      we transition to {:resolved, result}.
    #   4. Caller calls await_find_result(query_id) — either gets the
    #      already-resolved result, or registers `from` and we reply
    #      when the binding fires.
    find_waiters: %{},
    # Page-ready tracking. The bootstrap fires
    # __wallabidi(JSON.stringify({type: "page_ready", pageId: ...}))
    # whenever a new document parses or LiveView applies a patch (the
    # patch hook bumps pageId). Captures the most-recent pageId so the
    # click flow can capture pre_page_id BEFORE issuing the click and
    # await_page_ready_after BLOCKs until a different pageId arrives.
    last_page_id: nil,
    page_ready_waiter: nil,
    # Frame stack. Empty list = root frame (`document`); nested entries
    # represent each `focus_frame` push. Each entry is the frame's
    # `executionContextId` (CDP-assigned int) so subsequent JS evals
    # can target it via Runtime.evaluate's `contextId` parameter.
    frame_stack: [],
    # Map of `frameId` → `executionContextId`, populated as
    # Runtime.executionContextCreated events arrive. We need this
    # because Page.frameNavigated gives us a `frameId` but
    # Runtime.evaluate wants an `executionContextId`.
    frame_contexts: %{}
  ]

  @type t :: %__MODULE__{}

  # ----- Public API -----

  @doc """
  Starts a Session GenServer linked to the V2.WebSocket given by `ws_pid`.

  Opts:
    * `:ws_pid` (required)
    * `:init_fun` — 0-arity function returning `{:ok, %Wallabidi.Session{}}`
      run inside the GenServer; whatever it returns is held as the
      session struct (with `:pid` backfilled to this process).
    * `:teardown_fun` — 1-arity, receives the session in `terminate/2`.
    * `:owner` — process to monitor (defaults to the caller); when it
      dies we self-stop and run teardown_fun.
  """
  @spec start_link(keyword) :: {:ok, Wallabidi.Session.t()} | {:error, term}
  def start_link(opts) do
    ws_pid = Keyword.fetch!(opts, :ws_pid)
    init_fun = Keyword.fetch!(opts, :init_fun)
    teardown_fun = Keyword.fetch!(opts, :teardown_fun)
    owner = Keyword.get(opts, :owner, self())

    case GenServer.start(__MODULE__, {ws_pid, init_fun, teardown_fun, owner}) do
      {:ok, pid} ->
        session = GenServer.call(pid, :get_session)
        {:ok, %{session | pid: pid}}

      {:error, {:init_failed, reason}} ->
        {:error, reason}

      other ->
        other
    end
  end

  @doc """
  Send a CDP/BiDi RPC and block until the response arrives.

  Internally: dispatches to the V2.WebSocket via `cast_send/5`,
  registers the caller's `from` keyed by the wire id, and returns
  `:noreply`. When the matching `:v2_response` lands in the Session's
  mailbox, we look up `from` and reply.

  This means concurrent calls to the SAME session queue (each
  `handle_call` runs sequentially), but since each one returns
  `:noreply` quickly, the queue drains fast — only the actual
  network round-trip is on the critical path. Calls to DIFFERENT
  sessions don't contend with each other at all.

  `opts` is forwarded to V2.WebSocket.cast_send/5; see its docs for
  `:flat_session_id` / `:session_id`.
  """
  @spec cdp_send(Wallabidi.Session.t(), String.t(), map, keyword) ::
          {:ok, term} | {:error, term}
  def cdp_send(%Wallabidi.Session{pid: pid}, method, params, opts \\ [])
      when is_pid(pid) do
    GenServer.call(pid, {:cdp_send, method, params, opts}, default_timeout())
  catch
    :exit, {:noproc, _} -> {:error, :session_closed}
    :exit, {:normal, _} -> {:error, :session_closed}
  end

  @doc """
  Subscribes the Session to a wire-level event method.

  Combines:
    1. Telling the V2.WebSocket to route events with this method to us
       (so they arrive in our mailbox as `{:v2_event, method, event}`).
    2. Tagging the routing entry with the session's `browsing_context`
       (CDP `sessionId` / BiDi context id) so events for OTHER sessions
       on the same WebSocket don't fan in here.

  `routing_key` defaults to the session's browsing_context. Pass
  `:global` to receive events regardless of session (e.g. browser-level
  Target.attachedToTarget).
  """
  @spec subscribe(Wallabidi.Session.t(), String.t(), :global | nil) :: :ok
  def subscribe(%Wallabidi.Session{} = session, event_method, routing_key \\ nil)
      when is_binary(event_method) do
    GenServer.call(session.pid, {:subscribe, event_method, routing_key})
  end

  @doc """
  Block until a `Page.lifecycleEvent` fires for `loader_id` with
  milestone `name` (typically `"load"` or `"DOMContentLoaded"`).

  If the matching event has already arrived and been buffered, returns
  immediately. Otherwise registers a waiter and replies when the event
  lands or the timeout elapses.
  """
  @spec await_page_load(Wallabidi.Session.t(), String.t(), String.t(), timeout) ::
          :ok | :timeout
  def await_page_load(%Wallabidi.Session{pid: pid}, loader_id, name, timeout_ms \\ 10_000)
      when is_pid(pid) and is_binary(loader_id) and is_binary(name) do
    GenServer.call(pid, {:await_page_load, loader_id, name, timeout_ms}, timeout_ms + 2_000)
  catch
    :exit, _ -> :timeout
  end

  @doc """
  Block until ANY `Page.lifecycleEvent` of milestone `name` fires.
  Used by the navigation-classification path where the loader_id
  isn't known up-front (e.g. plain HTML form submits, server-driven
  redirects).

  Consumes any already-buffered load events as a side effect.
  """
  @spec await_next_page_load(Wallabidi.Session.t(), String.t(), timeout) :: :ok | :timeout
  def await_next_page_load(%Wallabidi.Session{pid: pid}, name \\ "load", timeout_ms \\ 10_000)
      when is_pid(pid) and is_binary(name) do
    GenServer.call(pid, {:await_next_page_load, name, timeout_ms}, timeout_ms + 2_000)
  catch
    :exit, _ -> :timeout
  end

  @doc """
  Synchronisation barrier — blocks until the SessionProcess has
  processed every message that was already in its mailbox at the
  moment of this call. V2.Session technically doesn't need this
  (its FIFO mailbox already provides ordering), but the existing
  `Wallabidi.SessionProcess.sync_barrier/1` is hard-coded across
  Browser and CDPClient. We expose it here for API parity so V2
  sessions can stand in for SessionProcess pids.
  """
  @spec sync_barrier(Wallabidi.Session.t()) :: :ok
  def sync_barrier(%Wallabidi.Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :sync_barrier)
  catch
    :exit, _ -> :ok
  end

  def sync_barrier(%Wallabidi.Session{}), do: :ok

  @doc """
  Returns `{state, history}` for diagnostic compatibility with
  `Wallabidi.SessionProcess.get_page_state/1`. V2 doesn't yet
  implement the bootstrap state machine — returns a minimal
  `{:lv_ready, []}` so callers (like `NavigationTimeoutError`) can
  pattern-match on the shape without crashing.
  """
  @spec get_page_state(Wallabidi.Session.t()) :: {atom, list}
  def get_page_state(%Wallabidi.Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :get_page_state)
  catch
    :exit, _ -> {:lv_ready, []}
  end

  @doc """
  Register a find waiter (non-blocking). Must be called BEFORE the JS
  that triggers the binding, to avoid the race where the binding event
  arrives before the waiter is registered.

  After this returns, fire whatever JS injects the query and calls
  `__wallabidi(...)` — when the matching `Runtime.bindingCalled` event
  arrives the waiter transitions to `{:resolved, payload}`.
  """
  @spec register_find(Wallabidi.Session.t(), String.t(), timeout) :: :ok
  def register_find(%Wallabidi.Session{pid: pid}, query_id, timeout_ms)
      when is_pid(pid) and is_binary(query_id) do
    GenServer.call(pid, {:register_find, query_id, timeout_ms})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Block until the find waiter registered by `register_find/3` resolves.

  Returns the binding payload (the parsed JSON the JS passed to
  `__wallabidi(...)`) on success, or `{:timeout, 0}` on timeout.
  """
  @spec await_find_result(Wallabidi.Session.t(), String.t(), timeout) ::
          {:ok, term} | {:timeout, 0} | {:error, term}
  def await_find_result(%Wallabidi.Session{pid: pid}, query_id, timeout_ms)
      when is_pid(pid) and is_binary(query_id) do
    GenServer.call(pid, {:await_find_result, query_id}, timeout_ms + 2_000)
  catch
    :exit, _ -> {:timeout, 0}
  end

  @doc """
  Returns the most-recent pageId reported by the bootstrap's
  `page_ready` notification, or `nil` if the bootstrap hasn't yet
  fired one. Capture this BEFORE a click that may navigate, then
  pass it to `await_page_ready_after/3`.
  """
  @spec get_page_id(Wallabidi.Session.t()) :: String.t() | nil
  def get_page_id(%Wallabidi.Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :get_page_id)
  catch
    :exit, _ -> nil
  end

  @doc """
  Block until a `page_ready` notification arrives with a pageId
  different from `pre_page_id`. The bootstrap fires this notification
  when a new document is ready (DOMContentLoaded + LV connected, or
  non-LV detected) AND on every LV patch.

  Returns `:ok` when a different pageId has been observed, or
  `:timeout` after `timeout_ms`.

  Special case: if `pre_page_id` is `nil`, we register a waiter for
  ANY first notification (no comparison) — without this guard a
  pre_page_id captured before the very first notification would
  spuriously match against any non-nil last_page_id.
  """
  @spec await_page_ready_after(Wallabidi.Session.t(), String.t() | nil, timeout) ::
          :ok | :timeout
  def await_page_ready_after(%Wallabidi.Session{pid: pid}, pre_page_id, timeout_ms \\ 5_000)
      when is_pid(pid) do
    GenServer.call(pid, {:await_page_ready_after, pre_page_id, timeout_ms}, timeout_ms + 2_000)
  catch
    :exit, _ -> :timeout
  end

  @doc """
  Returns the currently-focused frame's `executionContextId` (or
  `nil` for the root frame).

  Used internally by V2.CDPClient to target Runtime.evaluate /
  callFunctionOn at the right frame after `focus_frame/2`.
  """
  @spec current_context_id(Wallabidi.Session.t()) :: integer | nil
  def current_context_id(%Wallabidi.Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :current_context_id)
  catch
    :exit, _ -> nil
  end

  @doc """
  Pushes a frame onto the focus stack. Subsequent JS evaluations run
  inside that frame's realm.

  `context_id` is the frame's `executionContextId` (an integer
  assigned by Chrome's `Runtime.executionContextCreated` event).
  V2.CDPClient resolves the right context_id from a frame element
  before calling this.
  """
  @spec push_frame(Wallabidi.Session.t(), integer) :: :ok
  def push_frame(%Wallabidi.Session{pid: pid}, context_id)
      when is_pid(pid) and is_integer(context_id) do
    GenServer.call(pid, {:push_frame, context_id})
  catch
    :exit, _ -> :ok
  end

  @doc "Pops the top frame off the focus stack (no-op at root)."
  @spec pop_frame(Wallabidi.Session.t()) :: :ok
  def pop_frame(%Wallabidi.Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :pop_frame)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Records the `frameId → executionContextId` mapping for a frame.
  V2.CDPClient calls this when handling `Runtime.executionContextCreated`
  events so future `focus_frame` calls can resolve a frame element to
  its execution context.
  """
  @spec record_frame_context(Wallabidi.Session.t(), String.t(), integer) :: :ok
  def record_frame_context(%Wallabidi.Session{pid: pid}, frame_id, context_id)
      when is_pid(pid) and is_binary(frame_id) and is_integer(context_id) do
    GenServer.call(pid, {:record_frame_context, frame_id, context_id})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Looks up the `executionContextId` for a given frameId. Returns
  `nil` if not yet recorded.
  """
  @spec lookup_frame_context(Wallabidi.Session.t(), String.t()) :: integer | nil
  def lookup_frame_context(%Wallabidi.Session{pid: pid}, frame_id)
      when is_pid(pid) and is_binary(frame_id) do
    GenServer.call(pid, {:lookup_frame_context, frame_id})
  catch
    :exit, _ -> nil
  end

  @doc """
  Stops the Session GenServer. `terminate/2` runs the teardown_fun.
  """
  def stop(%Wallabidi.Session{pid: pid}) when is_pid(pid) do
    GenServer.stop(pid, :normal, 10_000)
  catch
    :exit, _ -> :ok
  end

  def stop(_), do: :ok

  defp default_timeout, do: 15_000

  # ----- GenServer callbacks -----

  @impl true
  def init({ws_pid, init_fun, teardown_fun, owner}) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(owner)

    case init_fun.() do
      {:ok, %Wallabidi.Session{} = session} ->
        state = %__MODULE__{
          session: session,
          ws_pid: ws_pid,
          owner_ref: ref,
          teardown_fun: teardown_fun
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:init_failed, reason}}
    end
  end

  @impl true
  def handle_call(:get_session, _from, state) do
    {:reply, state.session, state}
  end

  def handle_call({:cdp_send, method, params, opts}, from, state) do
    wire_id = WebSocket.cast_send(state.ws_pid, self(), method, params, opts)
    pending = Map.put(state.pending_calls, wire_id, from)
    {:noreply, %{state | pending_calls: pending}}
  end

  def handle_call({:subscribe, event_method, routing_key}, _from, state) do
    key = routing_key || state.session.browsing_context || :global
    :ok = WebSocket.subscribe(state.ws_pid, event_method, key, self())
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
    # `:any` wildcard loader_id — wake on the first matching milestone
    # regardless of which navigation produced it. Consume any buffered
    # loads first.
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
    # Reaching this clause means every prior message in the mailbox
    # has been processed. Reply is purely the synchronization signal.
    {:reply, :ok, state}
  end

  def handle_call(:get_page_state, _from, state) do
    {:reply, {:lv_ready, []}, state}
  end

  def handle_call({:register_find, query_id, timeout_ms}, _from, state) do
    timeout_ref = Process.send_after(self(), {:find_timeout, query_id}, timeout_ms)
    waiters = Map.put(state.find_waiters, query_id, {:pending, timeout_ref, nil})
    {:reply, :ok, %{state | find_waiters: waiters}}
  end

  def handle_call({:await_find_result, query_id}, from, state) do
    case Map.get(state.find_waiters, query_id) do
      {:resolved, result} ->
        waiters = Map.delete(state.find_waiters, query_id)
        {:reply, result, %{state | find_waiters: waiters}}

      {:pending, timeout_ref, nil} ->
        waiters = Map.put(state.find_waiters, query_id, {:pending, timeout_ref, from})
        {:noreply, %{state | find_waiters: waiters}}

      nil ->
        {:reply, {:timeout, 0}, state}
    end
  end

  def handle_call(:get_page_id, _from, state) do
    {:reply, state.last_page_id, state}
  end

  def handle_call({:await_page_ready_after, pre_page_id, timeout_ms}, from, state) do
    cond do
      # If we already have a different pageId, return :ok immediately.
      pre_page_id != nil and state.last_page_id != nil and
          state.last_page_id != pre_page_id ->
        {:reply, :ok, state}

      true ->
        timer_ref = Process.send_after(self(), {:page_ready_timeout, from}, timeout_ms)
        {:noreply, %{state | page_ready_waiter: {from, pre_page_id, timer_ref}}}
    end
  end

  def handle_call(:current_context_id, _from, state) do
    {:reply, List.first(state.frame_stack), state}
  end

  def handle_call({:push_frame, context_id}, _from, state) do
    {:reply, :ok, %{state | frame_stack: [context_id | state.frame_stack]}}
  end

  def handle_call(:pop_frame, _from, state) do
    new_stack =
      case state.frame_stack do
        [] -> []
        [_ | rest] -> rest
      end

    {:reply, :ok, %{state | frame_stack: new_stack}}
  end

  def handle_call({:record_frame_context, frame_id, context_id}, _from, state) do
    {:reply, :ok, %{state | frame_contexts: Map.put(state.frame_contexts, frame_id, context_id)}}
  end

  def handle_call({:lookup_frame_context, frame_id}, _from, state) do
    {:reply, Map.get(state.frame_contexts, frame_id), state}
  end

  @impl true
  def handle_info({:v2_response, wire_id, result}, state) do
    case Map.pop(state.pending_calls, wire_id) do
      {nil, _} ->
        # Either fire-and-forget that we shouldn't have stashed, or a
        # response that arrived after the caller gave up. Ignore.
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, result)
        {:noreply, %{state | pending_calls: pending}}
    end
  end

  def handle_info({:v2_event, "Page.lifecycleEvent", event}, state) do
    params = Map.get(event, "params", %{})
    loader_id = params["loaderId"]
    name = params["name"]

    if is_binary(loader_id) and name in ["load", "DOMContentLoaded"] do
      state = buffer_load(state, loader_id, name)
      state = wake_load_waiters(state, loader_id, name)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:v2_event, "Runtime.bindingCalled", event}, state) do
    params = Map.get(event, "params", %{})

    if params["name"] == "__wallabidi" and is_binary(params["payload"]) do
      {:noreply, route_binding_payload(state, params["payload"])}
    else
      {:noreply, state}
    end
  end

  def handle_info({:v2_event, "Runtime.executionContextCreated", event}, state) do
    # Chrome assigns a fresh executionContextId for each frame's main
    # JS realm. Record `auxData.frameId → contextId` so focus_frame
    # can resolve a frame element to its execution context.
    ctx = get_in(event, ["params", "context"]) || %{}
    aux = Map.get(ctx, "auxData", %{})
    context_id = ctx["id"]
    frame_id = aux["frameId"]

    state =
      if is_integer(context_id) and is_binary(frame_id) do
        %{state | frame_contexts: Map.put(state.frame_contexts, frame_id, context_id)}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:v2_event, "Runtime.executionContextDestroyed", event}, state) do
    # Drop the destroyed contextId from frame_contexts. This prevents
    # focus_frame from handing out stale contexts after a navigation.
    destroyed = get_in(event, ["params", "executionContextId"])

    state =
      if is_integer(destroyed) do
        contexts =
          state.frame_contexts
          |> Enum.reject(fn {_frame_id, ctx_id} -> ctx_id == destroyed end)
          |> Map.new()

        %{state | frame_contexts: contexts}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:v2_event, _method, _event}, state) do
    # Routes for other event types land here as we migrate them.
    {:noreply, state}
  end

  def handle_info({:load_timeout, from}, state) do
    case Enum.split_with(state.load_waiters, fn {f, _, _, _} -> f == from end) do
      {[], _} ->
        {:noreply, state}

      {[{^from, _l, _n, _ref} | _], rest} ->
        GenServer.reply(from, :timeout)
        {:noreply, %{state | load_waiters: rest}}
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

  def handle_info({:find_timeout, query_id}, state) do
    case Map.pop(state.find_waiters, query_id) do
      {nil, _} ->
        {:noreply, state}

      {{:resolved, _}, rest} ->
        # Already resolved; let await_find_result harvest it.
        {:noreply,
         %{state | find_waiters: Map.put(rest, query_id, get_in(state.find_waiters, [query_id]))}}

      {{:pending, _ref, nil}, rest} ->
        {:noreply, %{state | find_waiters: rest}}

      {{:pending, _ref, from}, rest} ->
        GenServer.reply(from, {:timeout, 0})
        {:noreply, %{state | find_waiters: rest}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{teardown_fun: fun, session: session}) when is_function(fun, 1) do
    try do
      fun.(session)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ----- Helpers -----

  defp buffer_load(state, loader_id, name) do
    loads =
      Map.update(state.loads, loader_id, %{name => true}, &Map.put(&1, name, true))

    %{state | loads: loads}
  end

  # The bootstrap calls `__wallabidi(JSON.stringify(...))` with payloads
  # like `%{"id" => query_id, "count" => N}` (find result) or
  # `%{"type" => "page_ready", "pageId" => ...}` (page-ready signal).
  # Find waiters key on the JSON `id` field; other shapes will get
  # routed to their own handlers as we add them.
  defp route_binding_payload(state, payload) do
    case Jason.decode(payload) do
      {:ok, %{"id" => query_id, "error" => err}} when is_binary(err) ->
        resolve_find(state, query_id, {:error, :invalid_selector})

      {:ok, %{"id" => query_id, "count" => count} = msg} ->
        resolve_find(state, query_id, {:ok, count, msg["meta"]})

      {:ok, %{"type" => "page_ready", "pageId" => page_id}} ->
        update_last_page_id(state, page_id)

      _ ->
        # Other payload shapes get added here as features migrate over.
        state
    end
  end

  defp update_last_page_id(state, page_id) do
    state = %{state | last_page_id: page_id}
    wake_page_ready_waiter(state, page_id)
  end

  defp wake_page_ready_waiter(state, page_id) do
    case state.page_ready_waiter do
      {from, pre_page_id, timer_ref} when pre_page_id != page_id ->
        # Either we have a real change or pre_page_id was nil and any
        # first notification counts as ready.
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, :ok)
        %{state | page_ready_waiter: nil}

      _ ->
        state
    end
  end

  defp resolve_find(state, query_id, result) do
    case Map.get(state.find_waiters, query_id) do
      nil ->
        # Late or unknown query id — drop.
        state

      {:pending, timeout_ref, nil} ->
        # Resolve into stored state; await_find_result will harvest.
        Process.cancel_timer(timeout_ref)
        %{state | find_waiters: Map.put(state.find_waiters, query_id, {:resolved, result})}

      {:pending, timeout_ref, from} ->
        # Caller is already blocking — reply directly and clean up.
        Process.cancel_timer(timeout_ref)
        GenServer.reply(from, result)
        %{state | find_waiters: Map.delete(state.find_waiters, query_id)}

      {:resolved, _} ->
        # Idempotent — keep the first result.
        state
    end
  end

  defp wake_load_waiters(state, loader_id, name) do
    {ready, pending} =
      Enum.split_with(state.load_waiters, fn
        # Specific loader_id match.
        {_from, ^loader_id, ^name, _ref} -> true
        # Wildcard waiter from await_next_page_load — woken by any
        # matching milestone regardless of loader_id.
        {_from, :any, ^name, _ref} -> true
        _ -> false
      end)

    Enum.each(ready, fn {from, _l, _n, ref} ->
      Process.cancel_timer(ref)
      GenServer.reply(from, :ok)
    end)

    %{state | load_waiters: pending}
  end
end
