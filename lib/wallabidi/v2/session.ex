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
    pending_calls: %{},
    # State migrated from SessionProcess (will be added incrementally
    # as drivers move over). For now we carry the minimum needed for
    # the CDP send path:
    pending_responses: %{}
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

  def handle_info({:v2_event, _method, _event}, state) do
    # TODO: route to handlers as drivers migrate. For now: drop.
    # Will become the new home for everything `SessionProcess` does
    # with `:bidi_event` messages.
    {:noreply, state}
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
end
