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
    :teardown_fun
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

  # --- GenServer callbacks ---

  @impl true
  def init({init_fun, teardown_fun, owner}) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(owner)

    # Expose the owner pid to the init function so drivers can register
    # event subscriptions to the correct process (the one that will
    # consume the events, not the SessionProcess itself).
    Process.put(:wallabidi_session_owner, owner)

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

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    # Owner died — terminate ourselves so `terminate/2` runs cleanup.
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
    e ->
      require Logger
      Logger.error("SessionProcess init failed: #{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
      {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
