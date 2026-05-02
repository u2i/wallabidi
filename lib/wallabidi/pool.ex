defmodule Wallabidi.Pool do
  @moduledoc """
  Generic resource pool for browser engines. Each driver supplies a
  `Wallabidi.Driver.Pool` callback module; the pool manages N slots
  using those callbacks.

  Test sessions check out a slot for the duration of their work and
  check it back in when done. The pool monitors checkout callers and
  auto-checks-in if a caller dies.

  ## Configuration

      config :wallabidi,
        chrome: [pool_size: 4]

  Or pass at start_link time:

      Wallabidi.Pool.start_link(
        name: MyPool,
        impl: Wallabidi.Chrome.Pool.Impl,
        size: 4,
        opts: [headless: true]
      )

  ## Slot reuse

  After a session ends, the slot is reset (`reset_slot/1`) and
  returned to the available queue. If reset returns `:must_recreate`,
  the pool tears down (`close_slot/1`) and reopens (`open_slot/1`)
  the slot before making it available again.
  """

  use GenServer
  require Logger

  defmodule Slot do
    @moduledoc false
    defstruct [:id, :handle, :owner, :owner_ref]
  end

  defmodule State do
    @moduledoc false
    defstruct [
      :impl,
      :size,
      :open_opts,
      :slots,
      :available,
      :waiting
    ]
  end

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Check out a slot. Blocks until one is available. Returns
  `{:ok, slot_id, slot_handle, session_state}`.

  The caller is monitored — if it dies before checking back in, the
  pool runs `finalize_session/2` and returns the slot to the pool.
  """
  @spec checkout(GenServer.server(), keyword(), timeout()) ::
          {:ok, non_neg_integer(), term(), term()} | {:error, term}
  def checkout(pool, session_opts \\ [], timeout \\ 60_000) do
    GenServer.call(pool, {:checkout, session_opts}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :checkout_timeout}
    :exit, {:noproc, _} -> {:error, :pool_not_started}
  end

  @doc """
  Return a slot to the pool. Runs `finalize_session/2` then makes
  the slot available to the next checkout.
  """
  @spec checkin(GenServer.server(), non_neg_integer(), term()) :: :ok
  def checkin(pool, slot_id, session_state) do
    GenServer.call(pool, {:checkin, slot_id, session_state}, 10_000)
  catch
    :exit, _ -> :ok
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    impl = Keyword.fetch!(opts, :impl)
    size = Keyword.fetch!(opts, :size)
    open_opts = Keyword.get(opts, :opts, [])

    state = %State{
      impl: impl,
      size: size,
      open_opts: open_opts,
      slots: %{},
      available: :queue.new(),
      waiting: :queue.new()
    }

    # Open slots eagerly and sequentially (not in parallel) — chromium-bidi
    # serializes Chrome spawning anyway and concurrent connects can race.
    state =
      Enum.reduce(0..(size - 1), state, fn id, acc ->
        open_slot(acc, id)
      end)

    {:ok, state}
  end

  @impl true
  def handle_call({:checkout, session_opts}, from, state) do
    do_checkout(from, session_opts, state, 0)
  end

  # Try slots until prepare_session succeeds or we've exhausted the
  # pool. A prepare failure recycles the failing slot and retries on
  # a different one — important when chromium-bidi's WebSocket dies
  # mid-run, since one bad slot shouldn't cascade into 50 test failures.
  @max_prepare_attempts 3

  defp do_checkout(_from, _session_opts, state, attempts)
       when attempts >= @max_prepare_attempts do
    {:reply, {:error, {:prepare_failed, :exhausted_pool}}, state}
  end

  defp do_checkout({pid, _} = from, session_opts, state, attempts) do
    case :queue.out(state.available) do
      {{:value, slot_id}, available} ->
        slot = Map.fetch!(state.slots, slot_id)
        ref = Process.monitor(pid)

        case state.impl.prepare_session(slot.handle, session_opts) do
          {:ok, session_state} ->
            slot = %{slot | owner: pid, owner_ref: ref}
            slots = Map.put(state.slots, slot_id, slot)
            state = %{state | slots: slots, available: available}
            {:reply, {:ok, slot_id, slot.handle, session_state}, state}

          {:error, _reason} ->
            Process.demonitor(ref, [:flush])
            # Slot is suspect — recycle it (close + reopen) and try again
            state = recycle_slot(%{state | available: available}, slot_id)
            do_checkout(from, session_opts, state, attempts + 1)
        end

      {:empty, _} ->
        # No slot free — queue the caller; reply when one frees up
        waiting = :queue.in({from, session_opts}, state.waiting)
        {:noreply, %{state | waiting: waiting}}
    end
  end

  def handle_call({:checkin, slot_id, session_state}, _from, state) do
    case Map.fetch(state.slots, slot_id) do
      {:ok, %Slot{owner_ref: ref} = slot} when not is_nil(ref) ->
        Process.demonitor(ref, [:flush])

        # finalize_session must be safe to call on partially-prepared
        # state (in case the caller died between prepare and a real
        # checkin). The driver is responsible for graceful handling.
        try do
          state.impl.finalize_session(slot.handle, session_state)
        rescue
          e -> Logger.warning("Pool finalize_session raised: #{inspect(e)}")
        catch
          :exit, reason ->
            Logger.warning("Pool finalize_session exited: #{inspect(reason)}")
        end

        slot = %{slot | owner: nil, owner_ref: nil}
        slots = Map.put(state.slots, slot_id, slot)
        state = %{state | slots: slots}

        state = release_slot(state, slot_id)
        {:reply, :ok, state}

      _ ->
        # Unknown slot or already checked in — be lenient
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case find_slot_by_ref(state.slots, ref) do
      {:ok, slot_id, slot} ->
        # Owner died mid-session. Clean up best-effort and recycle.
        try do
          state.impl.finalize_session(slot.handle, :crashed)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

        slot = %{slot | owner: nil, owner_ref: nil}
        slots = Map.put(state.slots, slot_id, slot)
        state = %{state | slots: slots}
        state = release_slot(state, slot_id)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {_id, %Slot{handle: handle}} <- state.slots do
      try do
        state.impl.close_slot(handle)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # --- Internal ---

  defp open_slot(state, id) do
    case state.impl.open_slot(state.open_opts) do
      {:ok, handle} ->
        slot = %Slot{id: id, handle: handle}
        slots = Map.put(state.slots, id, slot)
        available = :queue.in(id, state.available)
        %{state | slots: slots, available: available}

      {:error, reason} ->
        raise "Wallabidi.Pool failed to open slot #{id} (#{inspect(state.impl)}): #{inspect(reason)}"
    end
  end

  defp find_slot_by_ref(slots, ref) do
    Enum.find_value(slots, :error, fn
      {id, %Slot{owner_ref: ^ref} = slot} -> {:ok, id, slot}
      _ -> nil
    end)
  end

  # Slot is being returned to the available pool. Run reset_slot if
  # the impl provides it; recycle if it says so.
  defp release_slot(state, slot_id) do
    slot = Map.fetch!(state.slots, slot_id)

    reset_result =
      if function_exported?(state.impl, :reset_slot, 1) do
        try do
          state.impl.reset_slot(slot.handle)
        rescue
          _ -> :must_recreate
        catch
          :exit, _ -> :must_recreate
        end
      else
        :ok
      end

    case reset_result do
      :ok ->
        state = %{state | available: :queue.in(slot_id, state.available)}
        dispatch_waiting(state)

      :must_recreate ->
        recycle_slot(state, slot_id)
    end
  end

  # Tear down and reopen a slot in place.
  defp recycle_slot(state, slot_id) do
    slot = Map.fetch!(state.slots, slot_id)

    try do
      state.impl.close_slot(slot.handle)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    state = %{state | slots: Map.delete(state.slots, slot_id)}
    state = open_slot(state, slot_id)
    dispatch_waiting(state)
  end

  # If anyone is waiting for a slot, hand them the freshly available one.
  defp dispatch_waiting(state) do
    case :queue.out(state.waiting) do
      {{:value, {from, session_opts}}, waiting} ->
        # Promote the waiter to the head of the queue and run checkout
        # via do_checkout, which retries across slots on prepare failure.
        do_checkout_waiting(from, session_opts, %{state | waiting: waiting})

      {:empty, _} ->
        state
    end
  end

  # Same retry logic as do_checkout, but replies to a queued caller
  # rather than returning a {:reply, ...} tuple from handle_call.
  defp do_checkout_waiting(from, session_opts, state) do
    case do_checkout_attempt(from, session_opts, state, 0) do
      {:ok, reply, state} ->
        GenServer.reply(from, reply)
        state

      {:wait, state} ->
        # No slot free; re-queue caller at the head
        waiting = :queue.in_r({from, session_opts}, state.waiting)
        %{state | waiting: waiting}
    end
  end

  defp do_checkout_attempt(_from, _session_opts, state, attempts)
       when attempts >= @max_prepare_attempts do
    {:ok, {:error, {:prepare_failed, :exhausted_pool}}, state}
  end

  defp do_checkout_attempt({pid, _}, session_opts, state, attempts) do
    case :queue.out(state.available) do
      {{:value, slot_id}, available} ->
        slot = Map.fetch!(state.slots, slot_id)
        ref = Process.monitor(pid)

        case state.impl.prepare_session(slot.handle, session_opts) do
          {:ok, session_state} ->
            slot = %{slot | owner: pid, owner_ref: ref}
            slots = Map.put(state.slots, slot_id, slot)
            state = %{state | slots: slots, available: available}
            {:ok, {:ok, slot_id, slot.handle, session_state}, state}

          {:error, _reason} ->
            Process.demonitor(ref, [:flush])
            state = recycle_slot(%{state | available: available}, slot_id)
            do_checkout_attempt({pid, nil}, session_opts, state, attempts + 1)
        end

      {:empty, _} ->
        {:wait, state}
    end
  end
end
