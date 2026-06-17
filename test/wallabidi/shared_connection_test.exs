defmodule Wallabidi.Remote.Chrome.SharedConnectionTest do
  # Not async: starts the named SharedConnection Agent and mutates the
  # shared :persistent_term holding the ws pid.
  use ExUnit.Case, async: false

  alias Wallabidi.Remote.Chrome.SharedConnection

  @pid_key {SharedConnection, :ws_pid}

  setup do
    prev = :persistent_term.get(@pid_key, :unset)

    # A long-lived dummy process to stand in for the WebSocket pid — get/1
    # only checks Process.alive?, it doesn't talk to it on the read path.
    {:ok, fake_ws} = Agent.start_link(fn -> :ok end)

    {:ok, agent} =
      case Process.whereis(SharedConnection) do
        nil -> SharedConnection.start_link([])
        pid -> {:ok, pid}
      end

    on_exit(fn ->
      if Process.alive?(fake_ws), do: Agent.stop(fake_ws)

      case prev do
        :unset -> :persistent_term.erase(@pid_key)
        v -> :persistent_term.put(@pid_key, v)
      end

      if is_pid(agent) and Process.alive?(agent), do: Agent.stop(agent)
    end)

    %{fake_ws: fake_ws}
  end

  test "get/1 returns the live pid from persistent_term without reconnecting",
       %{fake_ws: fake_ws} do
    :persistent_term.put(@pid_key, fake_ws)
    # No Chrome/driver needed — the live-pid branch short-circuits before
    # any connect. A reconnect attempt would crash (no driver server), so a
    # clean return proves the read path didn't reconnect.
    assert SharedConnection.get(:no_driver) == fake_ws
  end

  test "concurrent get/1 with a live pid all return the same pid, lock-free",
       %{fake_ws: fake_ws} do
    :persistent_term.put(@pid_key, fake_ws)

    results =
      1..50
      |> Task.async_stream(fn _ -> SharedConnection.get(:no_driver) end,
        max_concurrency: 50,
        ordered: false
      )
      |> Enum.map(fn {:ok, pid} -> pid end)

    assert Enum.all?(results, &(&1 == fake_ws))
  end

  test "a dead stored pid triggers the (serialized) reconnect path", %{fake_ws: fake_ws} do
    # Ensure the Agent is running (it may have been crashed by a prior test).
    case Process.whereis(SharedConnection) do
      nil -> SharedConnection.start_link([])
      _ -> :ok
    end

    # Store a dead pid; get/1 should NOT return it — it should fall to the
    # connect path. We don't have a real driver, so the connect fails; the
    # point is that the dead pid is rejected (not returned as-is).
    Agent.stop(fake_ws)
    refute Process.alive?(fake_ws)
    :persistent_term.put(@pid_key, fake_ws)

    # The error surfaces as an exit from the Agent process (not the caller),
    # because the failure happens inside the Agent's handle_call.  Catch
    # the exit and assert that's what happens — proving the dead pid was
    # rejected and a reconnect was attempted.
    assert catch_exit(SharedConnection.get(:no_driver)) != nil
  end
end
