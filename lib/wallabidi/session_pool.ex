defmodule Wallabidi.SessionPool do
  @moduledoc false

  # Generic session pool for browser drivers. Lazily creates sessions on first
  # checkout and reuses them across tests. The driver module must implement:
  #
  #   create_pooled_session(opts) :: {:ok, Session.t()} | {:error, term()}
  #   reset_session(Session.t()) :: :ok | {:error, term()}
  #   close_session_hard(Session.t()) :: :ok

  use GenServer

  require Logger

  @default_max_sessions 4
  @checkout_timeout 30_000

  defstruct [
    :driver,
    :max_sessions,
    available: [],
    checked_out: %{},
    waiters: :queue.new(),
    created: 0,
    driver_opts: []
  ]

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Check out a session from the pool. Blocks until one is available or
  a new one can be created. Returns `{:ok, session}` or `{:error, reason}`.
  """
  def checkout(pool, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @checkout_timeout)
    GenServer.call(pool, {:checkout, opts}, timeout)
  end

  @doc """
  Return a session to the pool for reuse.
  """
  def checkin(pool, session) do
    GenServer.cast(pool, {:checkin, session})
  end

  @doc """
  Drain the pool — close all sessions and reset state.
  """
  def drain(pool) do
    GenServer.call(pool, :drain, @checkout_timeout)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)

    max_sessions =
      Keyword.get(opts, :max_sessions, @default_max_sessions)

    state = %__MODULE__{
      driver: driver,
      max_sessions: max_sessions,
      driver_opts: Keyword.get(opts, :driver_opts, [])
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:checkout, _opts}, from, state) do
    case state.available do
      [session | rest] ->
        state = %{state | available: rest, checked_out: Map.put(state.checked_out, session.id, {session, from})}
        monitor_caller(from)
        {:reply, {:ok, session}, state}

      [] when state.created < state.max_sessions ->
        # Create a new session lazily
        case state.driver.create_pooled_session(state.driver_opts) do
          {:ok, session} ->
            state = %{state | created: state.created + 1, checked_out: Map.put(state.checked_out, session.id, {session, from})}
            monitor_caller(from)
            {:reply, {:ok, session}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      [] ->
        # Pool full — queue the waiter
        state = %{state | waiters: :queue.in(from, state.waiters)}
        {:noreply, state}
    end
  end

  def handle_call(:drain, _from, state) do
    # Close all available sessions
    Enum.each(state.available, fn session ->
      safe_close(state.driver, session)
    end)

    # Close all checked-out sessions
    Enum.each(state.checked_out, fn {_id, {session, _from}} ->
      safe_close(state.driver, session)
    end)

    # Reply to any waiters with error
    drain_waiters(state.waiters)

    {:reply, :ok, %__MODULE__{driver: state.driver, max_sessions: state.max_sessions, driver_opts: state.driver_opts}}
  end

  @impl true
  def handle_cast({:checkin, session}, state) do
    state = %{state | checked_out: Map.delete(state.checked_out, session.id)}

    # Reset session state for reuse
    case safe_reset(state.driver, session) do
      :ok ->
        serve_or_park(session, state)

      {:error, _reason} ->
        # Session is broken — close it and decrement count
        safe_close(state.driver, session)
        state = %{state | created: state.created - 1}
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Owner process died — find and reclaim their session
    case find_session_by_owner(state.checked_out, pid) do
      {id, session} ->
        state = %{state | checked_out: Map.delete(state.checked_out, id)}

        case safe_reset(state.driver, session) do
          :ok ->
            serve_or_park(session, state)

          {:error, _} ->
            safe_close(state.driver, session)
            {:noreply, %{state | created: state.created - 1}}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp serve_or_park(session, state) do
    case :queue.out(state.waiters) do
      {{:value, waiter}, rest} ->
        state = %{state | waiters: rest, checked_out: Map.put(state.checked_out, session.id, {session, waiter})}
        monitor_caller(waiter)
        GenServer.reply(waiter, {:ok, session})
        {:noreply, state}

      {:empty, _} ->
        {:noreply, %{state | available: [session | state.available]}}
    end
  end

  defp monitor_caller({pid, _tag}) when is_pid(pid) do
    Process.monitor(pid)
  end

  defp find_session_by_owner(checked_out, pid) do
    Enum.find_value(checked_out, fn
      {id, {session, {owner_pid, _tag}}} when owner_pid == pid -> {id, session}
      _ -> nil
    end)
  end

  defp safe_reset(driver, session) do
    driver.reset_session(session)
  rescue
    e ->
      Logger.warning("SessionPool: reset_session failed: #{inspect(e)}")
      {:error, e}
  end

  defp safe_close(driver, session) do
    driver.close_session_hard(session)
  rescue
    e ->
      Logger.warning("SessionPool: close_session_hard failed: #{inspect(e)}")
      :ok
  end

  defp drain_waiters(queue) do
    case :queue.out(queue) do
      {{:value, waiter}, rest} ->
        GenServer.reply(waiter, {:error, :pool_drained})
        drain_waiters(rest)

      {:empty, _} ->
        :ok
    end
  end
end
