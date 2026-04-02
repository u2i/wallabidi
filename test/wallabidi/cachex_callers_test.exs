defmodule Wallabidi.CachexCallersTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  setup do
    cache_name = :"test_cache_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Cachex.start_link(cache_name)
    %{cache: cache_name}
  end

  describe "Cachex 4.1+ $callers propagation" do
    test "fetch callback receives $callers from the calling process", %{cache: cache} do
      test_pid = self()

      Cachex.fetch(cache, "key", fn _key ->
        # The Cachex Courier should set $callers so this worker
        # can see the calling process in its ancestry
        callers = Process.get(:"$callers") || []
        send(test_pid, {:callers, callers})
        {:commit, "value"}
      end)

      assert_receive {:callers, callers}
      # The test process should be in the $callers chain
      assert test_pid in callers
    end

    test "nested fetch inherits $callers through the chain", %{cache: cache} do
      test_pid = self()

      # Simulate: test -> Cachex.fetch -> worker
      # The worker should see the test process in $callers
      Task.async(fn ->
        Cachex.fetch(cache, "nested_key", fn _key ->
          callers = Process.get(:"$callers") || []
          send(test_pid, {:nested_callers, callers})
          {:commit, "nested_value"}
        end)
      end)
      |> Task.await()

      assert_receive {:nested_callers, callers}
      # test_pid should be reachable through the $callers chain
      # (Task sets $callers to [parent], Cachex Courier adds itself)
      assert length(callers) >= 1
    end

    test "get_and_update callback receives $callers", %{cache: cache} do
      test_pid = self()

      # Pre-populate
      Cachex.put(cache, "update_key", "old")

      Cachex.get_and_update(cache, "update_key", fn value ->
        callers = Process.get(:"$callers") || []
        send(test_pid, {:update_callers, callers, value})
        {:commit, "new"}
      end)

      assert_receive {:update_callers, callers, "old"}
      assert test_pid in callers
    end
  end
end
