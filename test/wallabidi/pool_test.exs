defmodule Wallabidi.PoolTest do
  use ExUnit.Case, async: false

  alias Wallabidi.Pool

  defmodule TestImpl do
    @moduledoc false
    @behaviour Wallabidi.Driver.Pool

    # Records all callbacks into an Agent so tests can inspect them.

    def start_recorder do
      {:ok, _} = Agent.start_link(fn -> %{events: [], next_id: 0, fail_prepare: false} end, name: __MODULE__)
    end

    def events, do: Agent.get(__MODULE__, & &1.events) |> Enum.reverse()
    def reset, do: Agent.update(__MODULE__, fn s -> %{s | events: []} end)
    def fail_prepare(b), do: Agent.update(__MODULE__, fn s -> %{s | fail_prepare: b} end)

    @impl true
    def open_slot(_opts) do
      id =
        Agent.get_and_update(__MODULE__, fn s ->
          {s.next_id, %{s | next_id: s.next_id + 1, events: [{:open, s.next_id} | s.events]}}
        end)

      {:ok, {:slot, id}}
    end

    @impl true
    def close_slot({:slot, id}) do
      Agent.update(__MODULE__, fn s -> %{s | events: [{:close, id} | s.events]} end)
      :ok
    end

    @impl true
    def prepare_session({:slot, id}, opts) do
      Agent.get_and_update(__MODULE__, fn s ->
        new_events = [{:prepare, id, opts} | s.events]

        if s.fail_prepare do
          {{:error, :nope}, %{s | events: new_events}}
        else
          {{:ok, {:session, id}}, %{s | events: new_events}}
        end
      end)
    end

    @impl true
    def finalize_session({:slot, id}, session_state) do
      Agent.update(__MODULE__, fn s ->
        %{s | events: [{:finalize, id, session_state} | s.events]}
      end)

      :ok
    end

    @impl true
    def reset_slot({:slot, _id}), do: :ok
  end

  setup do
    TestImpl.start_recorder()

    on_exit(fn ->
      pid = Process.whereis(TestImpl)
      if pid, do: Process.exit(pid, :kill)
    end)

    :ok
  end

  test "checkout returns slot, finalize on checkin" do
    {:ok, pool} = start_supervised({Pool, name: :test_pool_1, impl: TestImpl, size: 2})

    assert {:ok, slot_id, _handle, session} = Pool.checkout(pool)
    assert is_integer(slot_id)
    assert :ok = Pool.checkin(pool, slot_id, session)

    events = TestImpl.events()
    assert {:open, 0} in events
    assert {:open, 1} in events
    assert Enum.any?(events, &match?({:prepare, _, _}, &1))
    assert Enum.any?(events, &match?({:finalize, _, _}, &1))
  end

  test "blocks when pool is full, unblocks on checkin" do
    {:ok, pool} = start_supervised({Pool, name: :test_pool_2, impl: TestImpl, size: 1})

    {:ok, slot_id, _, session} = Pool.checkout(pool)

    # Second checkout blocks
    parent = self()

    task =
      Task.async(fn ->
        result = Pool.checkout(pool, [], 5_000)
        send(parent, {:got, result})
      end)

    refute_receive {:got, _}, 200

    # Free the slot — task should complete
    Pool.checkin(pool, slot_id, session)
    assert_receive {:got, {:ok, _, _, _}}, 1_000

    Task.await(task)
  end

  test "auto-finalizes when caller dies" do
    {:ok, pool} = start_supervised({Pool, name: :test_pool_3, impl: TestImpl, size: 1})

    parent = self()

    pid =
      spawn(fn ->
        {:ok, slot_id, _, session} = Pool.checkout(pool)
        send(parent, {:checked_out, slot_id, session})
        # Don't checkin — die instead
        exit(:abnormal)
      end)

    assert_receive {:checked_out, _slot_id, _session}, 1_000
    Process.sleep(100)
    refute Process.alive?(pid)

    # Pool should auto-finalize and the slot should be available again
    assert {:ok, _, _, _} = Pool.checkout(pool, [], 1_000)

    events = TestImpl.events()
    # finalize was called for the dying caller's session
    assert Enum.any?(events, &match?({:finalize, _, _}, &1))
  end

  test "prepare failure recycles the slot" do
    {:ok, pool} = start_supervised({Pool, name: :test_pool_4, impl: TestImpl, size: 1})

    TestImpl.fail_prepare(true)
    assert {:error, {:prepare_failed, :nope}} = Pool.checkout(pool, [])

    TestImpl.fail_prepare(false)
    # After recycle, pool is usable again
    assert {:ok, _, _, _} = Pool.checkout(pool, [], 2_000)
  end

  test "close_slot called on shutdown" do
    {:ok, pool} = start_supervised({Pool, name: :test_pool_5, impl: TestImpl, size: 2})
    stop_supervised(:test_pool_5)
    Process.sleep(50)
    refute Process.alive?(pool)

    events = TestImpl.events()
    closes = Enum.count(events, &match?({:close, _}, &1))
    assert closes == 2
  end
end
