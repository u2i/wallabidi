defmodule Wallabidi.FwfSandboxTest do
  use ExUnit.Case, async: true

  describe "FunWithFlags.Sandbox" do
    test "checkout/checkin isolates flags" do
      {:ok, _} = FunWithFlags.Sandbox.start()

      table = FunWithFlags.Sandbox.checkout()
      assert is_reference(table)

      # Flag starts disabled (empty)
      assert FunWithFlags.enabled?(:test_feature) == false

      # Enable it in sandbox
      assert {:ok, true} = FunWithFlags.enable(:test_feature)
      assert FunWithFlags.enabled?(:test_feature) == true

      # Checkin returns the table
      FunWithFlags.Sandbox.checkin(table)

      # After checkin, process dictionary is cleared
      assert Process.get(:fwf_sandbox) == nil

      # Clean up
      GenServer.stop(FunWithFlags.Sandbox)
    end

    test "separate checkouts are isolated from each other" do
      {:ok, _} = FunWithFlags.Sandbox.start(pool_size: 2)

      # First checkout — enable a flag
      table1 = FunWithFlags.Sandbox.checkout()
      FunWithFlags.enable(:isolated_flag)
      assert FunWithFlags.enabled?(:isolated_flag) == true
      FunWithFlags.Sandbox.checkin(table1)

      # Second checkout — flag should be clean
      table2 = FunWithFlags.Sandbox.checkout()
      assert FunWithFlags.enabled?(:isolated_flag) == false
      FunWithFlags.Sandbox.checkin(table2)

      GenServer.stop(FunWithFlags.Sandbox)
    end

    test "checkout with flags option pre-seeds flags" do
      {:ok, _} = FunWithFlags.Sandbox.start()

      table = FunWithFlags.Sandbox.checkout(flags: [my_flag: true, other_flag: false])
      assert FunWithFlags.enabled?(:my_flag) == true
      assert FunWithFlags.enabled?(:other_flag) == false
      FunWithFlags.Sandbox.checkin(table)

      GenServer.stop(FunWithFlags.Sandbox)
    end

    test "all_flag_names and all_flags work in sandbox" do
      {:ok, _} = FunWithFlags.Sandbox.start()

      table = FunWithFlags.Sandbox.checkout()
      FunWithFlags.enable(:flag_a)
      FunWithFlags.enable(:flag_b)

      {:ok, names} = FunWithFlags.all_flag_names()
      assert :flag_a in names
      assert :flag_b in names

      {:ok, flags} = FunWithFlags.all_flags()
      assert length(flags) == 2

      FunWithFlags.Sandbox.checkin(table)
      GenServer.stop(FunWithFlags.Sandbox)
    end

    test "clear works in sandbox" do
      {:ok, _} = FunWithFlags.Sandbox.start()

      table = FunWithFlags.Sandbox.checkout()
      FunWithFlags.enable(:clearable)
      assert FunWithFlags.enabled?(:clearable) == true

      FunWithFlags.clear(:clearable)
      assert FunWithFlags.enabled?(:clearable) == false

      FunWithFlags.Sandbox.checkin(table)
      GenServer.stop(FunWithFlags.Sandbox)
    end

    test "get_flag works in sandbox" do
      {:ok, _} = FunWithFlags.Sandbox.start()

      table = FunWithFlags.Sandbox.checkout()
      FunWithFlags.enable(:gettable)

      flag = FunWithFlags.get_flag(:gettable)
      assert %FunWithFlags.Flag{name: :gettable} = flag

      assert FunWithFlags.get_flag(:nonexistent) == nil

      FunWithFlags.Sandbox.checkin(table)
      GenServer.stop(FunWithFlags.Sandbox)
    end
  end

  describe "Feature.Utils flag helpers" do
    test "maybe_checkout_flags returns nil when sandbox not started" do
      assert Wallabidi.Feature.Utils.maybe_checkout_flags() == nil
    end

    test "maybe_checkin_flags with nil is a no-op" do
      assert Wallabidi.Feature.Utils.maybe_checkin_flags(nil) == :ok
    end

    test "maybe_checkout_flags/checkin_flags round trip" do
      {:ok, _} = FunWithFlags.Sandbox.start()

      table = Wallabidi.Feature.Utils.maybe_checkout_flags()
      assert is_reference(table)
      assert Process.get(:fwf_sandbox) == table

      Wallabidi.Feature.Utils.maybe_checkin_flags(table)
      assert Process.get(:fwf_sandbox) == nil

      GenServer.stop(FunWithFlags.Sandbox)
    end
  end

  describe "sandbox propagation" do
    test "propagate_fwf_sandbox copies table ref from owner process" do
      {:ok, _} = FunWithFlags.Sandbox.start()
      table = FunWithFlags.Sandbox.checkout()

      owner = self()

      # Spawn a child that propagates the sandbox from the owner
      task =
        Task.async(fn ->
          # Simulate what the Plug/Hook does
          case :erlang.process_info(owner, :dictionary) do
            {:dictionary, dict} ->
              case List.keyfind(dict, :fwf_sandbox, 0) do
                {:fwf_sandbox, t} -> Process.put(:fwf_sandbox, t)
                _ -> :ok
              end

            _ ->
              :ok
          end

          # Now the child should see the same sandbox
          FunWithFlags.enabled?(:propagated_flag)
        end)

      # Enable flag in owner's sandbox
      FunWithFlags.enable(:propagated_flag)

      # Child should see it
      assert Task.await(task) == true

      FunWithFlags.Sandbox.checkin(table)
      GenServer.stop(FunWithFlags.Sandbox)
    end
  end
end
