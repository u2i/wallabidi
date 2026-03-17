defmodule Wallabidi.CachexSandbox do
  @moduledoc """
  Pool of Cachex instances for test isolation.

  Each test checks out a dedicated Cachex instance that is cleared
  on checkout, ensuring no stale data leaks between tests.

  ## Setup

      # test/test_helper.exs
      Wallabidi.CachexSandbox.start([:my_cache, :other_cache])

  ## Usage in tests

      setup do
        caches = Wallabidi.CachexSandbox.checkout()
        Application.put_env(:my_app, :cache, caches[:my_cache])
        on_exit(fn -> Wallabidi.CachexSandbox.checkin(caches) end)
        :ok
      end

  ## How it works

  `start/1` creates a pool of Cachex instances for each cache name.
  Pool size matches `System.schedulers_online()` so concurrent tests
  each get their own instance.

  `checkout/0` picks an available instance set, clears all caches,
  and returns `%{name => instance_name}`.

  ## App integration

  Your app should read the cache name from config:

      defmodule MyApp.Cache do
        def name, do: Application.get_env(:my_app, :cache, :my_cache)
      end

      Cachex.fetch(MyApp.Cache.name(), key, fallback)
  """

  use GenServer

  def start(cache_names, opts \\ []) do
    pool_size = Keyword.get(opts, :pool_size, System.schedulers_online())
    GenServer.start_link(__MODULE__, {cache_names, pool_size}, name: __MODULE__)
  end

  @doc """
  Checks out a set of Cachex instances (one per cache name).
  Clears each cache before returning. Blocks if none available.
  """
  def checkout(timeout \\ 5_000) do
    GenServer.call(__MODULE__, :checkout, timeout)
  end

  @doc """
  Returns instances to the pool.
  """
  def checkin(caches) do
    GenServer.call(__MODULE__, {:checkin, caches})
  end

  @impl true
  def init({cache_names, pool_size}) do
    instances =
      for i <- 1..pool_size do
        for name <- cache_names, into: %{} do
          instance_name = :"#{name}_pool_#{i}"
          {:ok, _} = cachex().start_link(instance_name)
          {name, instance_name}
        end
      end

    {:ok, %{available: instances, waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:checkout, _from, %{available: [instance | rest]} = state) do
    clear_all(instance)
    {:reply, instance, %{state | available: rest}}
  end

  def handle_call(:checkout, from, %{available: []} = state) do
    waiting = :queue.in(from, state.waiting)
    {:noreply, %{state | waiting: waiting}}
  end

  def handle_call({:checkin, caches}, _from, state) do
    case :queue.out(state.waiting) do
      {{:value, waiter}, waiting} ->
        clear_all(caches)
        GenServer.reply(waiter, caches)
        {:reply, :ok, %{state | waiting: waiting}}

      {:empty, _} ->
        {:reply, :ok, %{state | available: [caches | state.available]}}
    end
  end

  defp clear_all(instance_map) do
    for {_name, instance} <- instance_map, do: cachex().clear(instance)
  end

  defp cachex, do: Module.concat([Cachex])
end
