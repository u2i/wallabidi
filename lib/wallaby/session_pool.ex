defmodule Wallabidi.SessionPool do
  @moduledoc """
  Optional pool of pre-created browser sessions.

  Eliminates the per-test cost of session creation (~500ms).
  Sessions are reset to `about:blank` on checkin and reused.

  ## Usage

      # test/test_helper.exs
      {:ok, _} = Wallabidi.SessionPool.start_link(pool_size: 4)

      # In tests
      {:ok, session} = Wallabidi.start_session(pool: Wallabidi.SessionPool)

  ## Configuration

      pool_size: 4                   # number of sessions (default: System.schedulers_online())
      session_opts: [headless: true] # options passed to Chrome.start_session
  """
  use GenServer

  @default_pool_size System.schedulers_online()

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Check out a session from the pool. Blocks if none available."
  def checkout(pool \\ __MODULE__, timeout \\ 10_000) do
    GenServer.call(pool, :checkout, timeout)
  end

  @doc "Return a session to the pool. Navigates to about:blank."
  def checkin(pool \\ __MODULE__, session) do
    GenServer.call(pool, {:checkin, session})
  end

  @impl true
  def init(opts) do
    pool_size = Keyword.get(opts, :pool_size, @default_pool_size)
    session_opts = Keyword.get(opts, :session_opts, [])

    sessions =
      for _i <- 1..pool_size do
        {:ok, session} = Wallabidi.Chrome.start_session(session_opts)
        session
      end

    {:ok, %{available: sessions, waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:checkout, from, %{available: [], waiting: waiting} = state) do
    {:noreply, %{state | waiting: :queue.in(from, waiting)}}
  end

  def handle_call(:checkout, _from, %{available: [session | rest]} = state) do
    {:reply, session, %{state | available: rest}}
  end

  def handle_call({:checkin, session}, _from, %{available: available, waiting: waiting} = state) do
    # Reset session to clean state
    reset_session(session)

    case :queue.out(waiting) do
      {{:value, next}, new_waiting} ->
        GenServer.reply(next, session)
        {:reply, :ok, %{state | waiting: new_waiting}}

      {:empty, _} ->
        {:reply, :ok, %{state | available: [session | available]}}
    end
  end

  @impl true
  def terminate(_reason, %{available: sessions}) do
    for session <- sessions do
      try do
        Wallabidi.Chrome.end_session(session)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp reset_session(session) do
    try do
      Wallabidi.BiDiClient.visit(session, "about:blank")
    rescue
      _ -> :ok
    end
  end
end
