defmodule Wallabidi.SessionProcess do
  @moduledoc false

  # A SessionProcess owns a single browser session's resources: the
  # WebSocket connection, any spawned subprocesses, and per-session
  # state that used to live in the test process dictionary.
  #
  # ## Why a process per session?
  #
  # Previously a session was a passive struct, and cleanup was handled
  # by SessionStore on behalf of dead test processes — a single GenServer
  # coordinating cleanup for all sessions, which serialized cleanup and
  # blocked `demonitor` calls from other tests under load.
  #
  # With a process per session:
  #
  # - Cleanup is natural: `terminate/2` runs whether the session ends
  #   gracefully (end_session → :stop message) or the owner dies
  #   (Process.monitor → DOWN → self-terminate).
  # - Sessions are independent: one session's cleanup doesn't block
  #   another session's operations.
  # - State is localised: frame stacks, mouse position, WebSocket pid,
  #   etc. all live in one GenServer instead of scattered across process
  #   dictionaries.
  # - Lifecycle is a simple FSM with one exit path.
  #
  # ## How it's used
  #
  # Drivers call `SessionProcess.start_link/1` with session init data and
  # an `init_fun` that actually creates the underlying browser session.
  # The session handle (`%Wallabidi.Session{}`) is returned with its
  # `:pid` field set to the SessionProcess pid. Tests pass this handle
  # to driver functions as before.
  #
  # When the test process (caller) dies, Process.monitor fires a DOWN,
  # and SessionProcess stops itself — `terminate/2` runs the driver's
  # end_session for proper cleanup.

  use GenServer

  alias Wallabidi.Session

  defstruct [
    :session,
    :owner_ref,
    :teardown_fun,
    # Page-load event router state. Lifecycle events (CDP Page.lifecycleEvent
    # / BiDi browsingContext.load + domContentLoaded) are routed here instead
    # of to the test process mailbox. We keep two things:
    #
    # - `loads`: a map `%{loader_id => %{"load" => true, "DOMContentLoaded" => true}}`
    #   of (navigation, milestone) pairs that have already fired. Callers
    #   arriving *after* the event get an immediate reply.
    #
    # - `load_waiters`: a list of `{from, loader_id, name, timeout_ref}` for
    #   callers waiting for a (loader_id, name) pair that hasn't fired yet.
    #   When the matching event lands we reply and cancel the timeout.
    #
    # Noise events (`firstPaint`, `networkIdle`, etc.) are dropped in-place
    # in handle_info and never reach any mailbox.
    loads: %{},
    load_waiters: [],
    # Push-based element finding. When JS calls __wallabidi(payload),
    # Chrome fires Runtime.bindingCalled which arrives here. We match
    # the query id against pending find waiters and reply.
    find_waiters: %{}
  ]

  # --- Public API ---

  @doc """
  Starts a SessionProcess, runs the driver-specific init function inside
  it, and returns the session handle with `:pid` set to the process.

  `init_fun` is a 0-arity function that performs the driver-specific
  setup (connect to the browser, create the browsing context, etc.)
  and returns `{:ok, %Session{}}` or `{:error, reason}`. It runs in
  the SessionProcess itself, so any resources it spawns are linked
  to the correct lifetime.

  `teardown_fun` is a 1-arity function that receives the session and
  releases its resources. It runs in `terminate/2`.

  The caller process is monitored — if it dies, this SessionProcess
  terminates and runs `teardown_fun`.
  """
  @spec start_link(keyword()) :: {:ok, Session.t()} | {:error, term()}
  def start_link(opts) do
    init_fun = Keyword.fetch!(opts, :init_fun)
    teardown_fun = Keyword.fetch!(opts, :teardown_fun)
    owner = Keyword.get(opts, :owner, self())

    case GenServer.start(__MODULE__, {init_fun, teardown_fun, owner}) do
      {:ok, pid} ->
        # Retrieve the session built during init and attach this pid.
        session = GenServer.call(pid, :get_session)
        {:ok, %{session | pid: pid}}

      {:error, {:init_failed, reason}} ->
        {:error, reason}

      other ->
        other
    end
  end

  @doc "Stops the session process, triggering cleanup in terminate/2."
  @spec stop(Session.t()) :: :ok
  def stop(%Session{pid: pid}) when is_pid(pid) do
    try do
      GenServer.stop(pid, :normal, 10_000)
    catch
      :exit, _ -> :ok
    end
  end

  def stop(%Session{}), do: :ok

  @doc """
  Read per-session state stored in the SessionProcess. Used in place of
  Process.get in drivers that need per-session scratch state (frame
  stack, mouse position, etc.).
  """
  @spec get(Session.t(), term(), term()) :: term()
  def get(%Session{pid: pid}, key, default \\ nil) when is_pid(pid) do
    GenServer.call(pid, {:get_state, key, default})
  catch
    :exit, _ -> default
  end

  @spec put(Session.t(), term(), term()) :: :ok
  def put(%Session{pid: pid}, key, value) when is_pid(pid) do
    GenServer.call(pid, {:put_state, key, value})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Blocks until a page-load milestone (`"load"` or `"DOMContentLoaded"`) has
  been reported for `loader_id`, or returns `:timeout` after `timeout_ms`.

  `loader_id` is the navigation correlation ID returned synchronously from
  the protocol's navigate command (`Page.navigate.loaderId` on CDP,
  `browsingContext.navigate.navigation` on BiDi). Passing the exact ID
  returned by navigate means we only resolve on events for *our* navigation
  — events for the initial about:blank load, previous visits, and any
  in-flight trailing events from earlier navigations are filtered out.

  If the matching event has already arrived and been buffered, the call
  returns immediately.
  """
  @spec await_page_load(Session.t(), String.t(), String.t(), timeout()) ::
          :ok | :timeout
  def await_page_load(%Session{pid: pid}, loader_id, name, timeout_ms \\ 10_000)
      when is_pid(pid) and is_binary(loader_id) and is_binary(name) do
    GenServer.call(pid, {:await_page_load, loader_id, name, timeout_ms}, timeout_ms + 2_000)
  catch
    :exit, _ -> :timeout
  end

  @doc """
  Register a pending find query. When the JS binding calls back with
  a matching query id, this call resolves with `{:ok, count}`.
  Returns `{:timeout, count}` if the timeout elapses (count from the
  last check, may be 0).
  """
  @spec await_find(Session.t(), String.t(), timeout()) :: {:ok, non_neg_integer()} | {:timeout, non_neg_integer()}
  def await_find(%Session{pid: pid}, query_id, timeout_ms \\ 5_000)
      when is_pid(pid) and is_binary(query_id) do
    GenServer.call(pid, {:await_find, query_id, timeout_ms}, timeout_ms + 2_000)
  catch
    :exit, _ -> {:timeout, 0}
  end

  @doc """
  Like `await_page_load/4` but waits for the *next* load event from any
  navigation — no loaderId required. Used for click-triggered navigations
  (form submits, link clicks) where the caller doesn't have a loaderId
  from `Page.navigate`.

  Events that were buffered *before* this call are consumed (they're from
  previous navigations). Only a load event that arrives *after* the call
  resolves it.
  """
  @spec await_next_page_load(Session.t(), String.t(), timeout()) :: :ok | :timeout
  def await_next_page_load(%Session{pid: pid}, name \\ "load", timeout_ms \\ 10_000)
      when is_pid(pid) and is_binary(name) do
    GenServer.call(pid, {:await_next_page_load, name, timeout_ms}, timeout_ms + 2_000)
  catch
    :exit, _ -> :timeout
  end

  @doc """
  Non-blocking check: was a "load" event buffered since the last consume?
  Returns `:ok` if yes (and consumes it), `:none` if no load event is pending.
  Used for reactive post-action navigation detection — "did the click
  cause a page load?"
  """
  @spec await_page_load_nowait(Session.t()) :: :ok | :none
  def await_page_load_nowait(%Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :await_page_load_nowait)
  catch
    :exit, _ -> :none
  end

  # --- GenServer callbacks ---

  @impl true
  def init({init_fun, teardown_fun, owner}) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(owner)

    # Expose the owner pid to the init function so drivers can register
    # event subscriptions to the correct process (the one that will
    # consume the events, not the SessionProcess itself).
    Process.put(:wallabidi_session_owner, owner)

    # Also expose self() so protocol adapters can route session-scoped
    # events (page_load lifecycle, eventually others) to this router
    # instead of to the owner's mailbox.
    Process.put(:wallabidi_session_process, self())

    case safe_invoke(init_fun) do
      {:ok, %Session{} = session} ->
        # Tag the session with this process's pid so callers can stop it.
        session = %{session | pid: self()}

        # Register with SessionStore so `Feature.end_all_sessions/1` can
        # find it during sandbox cleanup.
        try do
          Wallabidi.SessionStore.register(session, owner)
        catch
          :exit, _ -> :ok
        end

        {:ok,
         %__MODULE__{
           session: session,
           owner_ref: ref,
           teardown_fun: teardown_fun
         }}

      {:error, reason} ->
        {:stop, {:init_failed, reason}}

      other ->
        {:stop, {:init_failed, {:unexpected_return, other}}}
    end
  end

  @impl true
  def handle_call(:get_session, _from, state) do
    {:reply, state.session, state}
  end

  def handle_call({:get_state, key, default}, _from, state) do
    value = Map.get(state, :kv, %{}) |> Map.get(key, default)
    {:reply, value, state}
  end

  def handle_call({:put_state, key, value}, _from, state) do
    kv = Map.get(state, :kv, %{}) |> Map.put(key, value)
    {:reply, :ok, Map.put(state, :kv, kv)}
  end

  def handle_call({:await_page_load, loader_id, name, timeout_ms}, from, state) do
    case get_in(state.loads, [loader_id, name]) do
      true ->
        # Already fired and buffered — pop it and reply immediately.
        {:reply, :ok, drop_load(state, loader_id, name)}

      _ ->
        # Not yet seen — register a waiter with its own timeout.
        timeout_ref = Process.send_after(self(), {:page_load_timeout, from}, timeout_ms)
        waiters = [{from, loader_id, name, timeout_ref} | state.load_waiters]
        {:noreply, %{state | load_waiters: waiters}}
    end
  end

  def handle_call(:await_page_load_nowait, _from, state) do
    # Check if any "load" event is buffered. If so, consume it and reply :ok.
    has_load =
      Enum.any?(state.loads, fn {_loader_id, milestones} ->
        Map.get(milestones, "load", false)
      end)

    if has_load do
      {:reply, :ok, %{state | loads: %{}}}
    else
      {:reply, :none, state}
    end
  end

  def handle_call({:await_next_page_load, name, timeout_ms}, from, state) do
    # Flush all buffered loads — they're from prior navigations. Only a
    # fresh event that arrives *after* this call will resolve the waiter.
    # Use loader_id = :any as a wildcard sentinel that record_load matches.
    timeout_ref = Process.send_after(self(), {:page_load_timeout, from}, timeout_ms)
    waiters = [{from, :any, name, timeout_ref} | state.load_waiters]
    {:noreply, %{state | loads: %{}, load_waiters: waiters}}
  end

  def handle_call({:await_find, query_id, timeout_ms}, from, state) do
    timeout_ref = Process.send_after(self(), {:find_timeout, query_id}, timeout_ms)
    waiters = Map.put(state.find_waiters, query_id, {from, timeout_ref})
    {:noreply, %{state | find_waiters: waiters}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    # Owner died — terminate ourselves so `terminate/2` runs cleanup.
    {:stop, :normal, state}
  end

  # CDP: Page.lifecycleEvent carries params.loaderId and params.name. We only
  # care about "load" and "DOMContentLoaded" — everything else (init, commit,
  # firstPaint, firstContentfulPaint, networkAlmostIdle, networkIdle, ...)
  # gets dropped here and never accumulates in anyone's mailbox.
  def handle_info({:bidi_event, "Page.lifecycleEvent", event}, state) do
    params = Map.get(event, "params", %{})
    loader_id = params["loaderId"]
    name = params["name"]

    if is_binary(loader_id) and name in ["load", "DOMContentLoaded"] do
      {:noreply, record_load(state, loader_id, name)}
    else
      {:noreply, state}
    end
  end

  # BiDi: browsingContext.load and browsingContext.domContentLoaded. The
  # correlation ID lives at params.navigation. Normalise the name to match
  # CDP so callers can use a single vocabulary.
  def handle_info({:bidi_event, "browsingContext.load", event}, state) do
    params = Map.get(event, "params", %{})
    loader_id = params["navigation"]

    if is_binary(loader_id) do
      {:noreply, record_load(state, loader_id, "load")}
    else
      {:noreply, state}
    end
  end

  def handle_info({:bidi_event, "browsingContext.domContentLoaded", event}, state) do
    params = Map.get(event, "params", %{})
    loader_id = params["navigation"]

    if is_binary(loader_id) do
      {:noreply, record_load(state, loader_id, "DOMContentLoaded")}
    else
      {:noreply, state}
    end
  end

  def handle_info({:page_load_timeout, from}, state) do
    case Enum.split_with(state.load_waiters, fn {f, _, _, _} -> f == from end) do
      {[{from, _, _, _}], rest} ->
        GenServer.reply(from, :timeout)
        {:noreply, %{state | load_waiters: rest}}

      _ ->
        # Already resolved — the timeout message was racing with the reply.
        {:noreply, state}
    end
  end

  # Runtime.bindingCalled: JS called __wallabidi(payload).
  # payload is JSON: {"id": "query_id", "count": N}
  def handle_info({:bidi_event, "Runtime.bindingCalled", event}, state) do
    params = Map.get(event, "params", %{})

    if params["name"] == "__wallabidi" do
      case Jason.decode(params["payload"] || "") do
        {:ok, %{"id" => query_id, "count" => count}} ->
          case Map.pop(state.find_waiters, query_id) do
            {{from, timeout_ref}, waiters} ->
              Process.cancel_timer(timeout_ref)
              GenServer.reply(from, {:ok, count})
              {:noreply, %{state | find_waiters: waiters}}

            {nil, _} ->
              {:noreply, state}
          end

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:find_timeout, query_id}, state) do
    case Map.pop(state.find_waiters, query_id) do
      {{from, _timeout_ref}, waiters} ->
        GenServer.reply(from, {:timeout, 0})
        {:noreply, %{state | find_waiters: waiters}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Page-load router helpers ---

  # An event arrived. If anyone was waiting for exactly this (loader_id,
  # name) pair — or for *any* loader_id (`:any` sentinel from
  # await_next_page_load) — reply to them. Otherwise, buffer it so a
  # later caller sees it immediately.
  defp record_load(state, loader_id, name) do
    case Enum.split_with(state.load_waiters, fn {_from, lid, n, _ref} ->
           (lid == loader_id or lid == :any) and n == name
         end) do
      {[], _} ->
        # No waiters — buffer the fact that this milestone happened.
        inner = Map.put(Map.get(state.loads, loader_id, %{}), name, true)
        %{state | loads: Map.put(state.loads, loader_id, inner)}

      {matching, rest} ->
        Enum.each(matching, fn {from, _, _, ref} ->
          Process.cancel_timer(ref)
          GenServer.reply(from, :ok)
        end)

        %{state | load_waiters: rest}
    end
  end

  # Remove a buffered (loader_id, name) after a caller has consumed it.
  defp drop_load(state, loader_id, name) do
    case Map.get(state.loads, loader_id) do
      nil ->
        state

      inner ->
        case Map.delete(inner, name) do
          empty when map_size(empty) == 0 ->
            %{state | loads: Map.delete(state.loads, loader_id)}

          remaining ->
            %{state | loads: Map.put(state.loads, loader_id, remaining)}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    safe_invoke(fn -> state.teardown_fun.(state.session) end)
    safe_invoke(fn -> Wallabidi.SessionStore.unregister(state.session) end)
    :ok
  end

  # --- Internal ---

  defp safe_invoke(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
