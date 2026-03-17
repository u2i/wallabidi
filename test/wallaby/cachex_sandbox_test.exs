defmodule Wallabidi.CachexSandboxTest do
  use ExUnit.Case, async: false

  setup do
    pool_name = :"test_cache_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = Wallabidi.CachexSandbox.start([pool_name], pool_size: 2)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{cache_name: pool_name}
  end

  test "checkout returns a map of cache instances", %{cache_name: name} do
    caches = Wallabidi.CachexSandbox.checkout()
    assert is_map(caches)
    assert Map.has_key?(caches, name)
    assert is_atom(caches[name])
    Wallabidi.CachexSandbox.checkin(caches)
  end

  test "checked out caches are empty", %{cache_name: name} do
    caches = Wallabidi.CachexSandbox.checkout()

    # Put something, checkin, checkout again — should be clean
    Cachex.put(caches[name], "key", "value")
    Wallabidi.CachexSandbox.checkin(caches)

    caches2 = Wallabidi.CachexSandbox.checkout()
    assert {:ok, nil} = Cachex.get(caches2[name], "key")
    Wallabidi.CachexSandbox.checkin(caches2)
  end

  test "concurrent checkouts get separate instances", %{cache_name: name} do
    caches1 = Wallabidi.CachexSandbox.checkout()
    caches2 = Wallabidi.CachexSandbox.checkout()

    # Different instance names
    refute caches1[name] == caches2[name]

    # Writes don't cross
    Cachex.put(caches1[name], "key", "from_test_1")
    Cachex.put(caches2[name], "key", "from_test_2")

    assert {:ok, "from_test_1"} = Cachex.get(caches1[name], "key")
    assert {:ok, "from_test_2"} = Cachex.get(caches2[name], "key")

    Wallabidi.CachexSandbox.checkin(caches1)
    Wallabidi.CachexSandbox.checkin(caches2)
  end

  test "checkin makes instance available for next checkout", %{cache_name: _name} do
    # Pool size is 2
    c1 = Wallabidi.CachexSandbox.checkout()
    c2 = Wallabidi.CachexSandbox.checkout()

    # Return one
    Wallabidi.CachexSandbox.checkin(c1)

    # Can checkout again
    c3 = Wallabidi.CachexSandbox.checkout()
    assert is_map(c3)

    Wallabidi.CachexSandbox.checkin(c2)
    Wallabidi.CachexSandbox.checkin(c3)
  end
end
