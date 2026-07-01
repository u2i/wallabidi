defmodule Wallabidi.SessionStore do
  @moduledoc false

  # Lightweight registry mapping test-process pids to their active
  # Wallabidi sessions. The Transport actors register themselves on
  # init and unregister on terminate.
  #
  # Used by `Wallabidi.Feature.Utils.end_all_sessions/1` during sandbox
  # checkin to find and close all sessions owned by a test before the
  # sandbox is released.
  #
  # Pure lookup table — does not monitor or drive cleanup. The actors
  # handle their own lifecycle via Process.monitor on the owner.

  use GenServer
  use EventEmitter, :emitter

  def start_link(opts \\ []) do
    {opts, args} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, args, opts)
  end

  @doc """
  Registers a session as owned by a specific process. Called from
  the Transport actor's init/1.
  """
  def register(store \\ __MODULE__, session, owner_pid) do
    GenServer.call(store, {:register, session, owner_pid})
  end

  @doc """
  Unregisters a session. Called from the Transport actor's terminate/2.
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
