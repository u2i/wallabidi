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
    load_waiters: []
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

  defp wake_load_waiters(state, loader_id, name) do
    {ready, pending} =
      Enum.split_with(state.load_waiters, fn
        {_from, ^loader_id, ^name, _ref} -> true
        _ -> false
      end)

    Enum.each(ready, fn {from, _l, _n, ref} ->
      Process.cancel_timer(ref)
      GenServer.reply(from, :ok)
    end)

    %{state | load_waiters: pending}
  end
end
