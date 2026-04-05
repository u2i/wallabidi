defmodule Wallabidi.SessionStore do
  @moduledoc false

  # Lightweight registry mapping test-process pids to their active
  # Wallabidi sessions. Populated by SessionProcess on startup and
  # cleaned up in SessionProcess.terminate/2.
  #
  # Used by `Wallabidi.Feature.Utils.end_all_sessions/1` during sandbox
  # checkin to find and close all sessions owned by a test before the
  # sandbox is released.
  #
  # Unlike the old SessionStore, this one does NOT monitor or drive
  # cleanup — SessionProcess handles its own lifecycle via Process.monitor
  # on the owner. This module is purely a lookup table.

  use GenServer
  use EventEmitter, :emitter

  def start_link(opts \\ []) do
    {opts, args} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, args, opts)
  end

  @doc """
  Registers a session as owned by a specific process. Called by
  SessionProcess.init/1.
  """
  def register(store \\ __MODULE__, session, owner_pid) do
    GenServer.call(store, {:register, session, owner_pid})
  end

  @doc """
  Unregisters a session. Called by SessionProcess.terminate/2.
  """
  def unregister(store \\ __MODULE__, session) do
    GenServer.call(store, {:unregister, session})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Returns sessions owned by a specific pid (defaults to self()).
  """
  def list_sessions_for(opts \\ []) do
    name = Keyword.get(opts, :name, :session_store)
    owner_pid = Keyword.get(opts, :owner_pid, self())

    :ets.select(name, [{{{:_, :"$1"}, :"$2"}, [{:==, :"$1", owner_pid}], [:"$2"]}])
  end

  # Kept for backward compat with existing call sites; now a no-op
  # since SessionProcess handles lifecycle itself.
  def monitor(_store \\ __MODULE__, _session), do: :ok
  def demonitor(_store \\ __MODULE__, _session), do: :ok

  def init(args) do
    name = Keyword.get(args, :ets_name, :session_store)

    opts =
      if(name == :session_store, do: [:named_table], else: []) ++
        [:set, :public, read_concurrency: true]

    tid = :ets.new(name, opts)
    {:ok, %{ets_table: tid}}
  end

  def handle_call({:register, session, owner_pid}, _from, state) do
    :ets.insert(state.ets_table, {{session.id, owner_pid}, session})
    emit(%{module: __MODULE__, name: :monitor, metadata: %{monitored_session: session}})
    {:reply, :ok, state}
  end

  def handle_call({:unregister, session}, _from, state) do
    :ets.select_delete(state.ets_table, [
      {{{:"$1", :_}, :_}, [{:==, :"$1", session.id}], [true]}
    ])

    emit(%{module: __MODULE__, name: :DOWN, metadata: %{monitored_session: session}})
    {:reply, :ok, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
