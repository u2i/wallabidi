defmodule Wallabidi.Test.SlowTestGuardTest do
  # Not async: mutates the shared persistent_term holding the one-time
  # Chrome connect cost.
  use ExUnit.Case, async: false

  alias Wallabidi.Test.SlowTestGuard

  @connect_us_key {Wallabidi.Remote.Chrome.SharedConnection, :connect_us}

  setup do
    prev = :persistent_term.get(@connect_us_key, :unset)

    on_exit(fn ->
      case prev do
        :unset -> :persistent_term.erase(@connect_us_key)
        v -> :persistent_term.put(@connect_us_key, v)
      end
    end)

    :ok
  end

  defp init_state(opts \\ []) do
    {:ok, state} = SlowTestGuard.init(opts)
    state
  end

  defp finished(state, time_us, tags \\ %{}) do
    test = %ExUnit.Test{name: :t, module: __MODULE__, tags: tags, time: time_us}
    {:noreply, new_state} = SlowTestGuard.handle_cast({:test_finished, test}, state)
    new_state
  end

  test "a test within budget is not an offender" do
    state = finished(init_state(), 1_000_000)
    assert state.offenders == []
  end

  test "a test over budget with no Chrome startup is an offender" do
    :persistent_term.put(@connect_us_key, 0)
    # default threshold 4000ms; 6s test, no startup to discount
    state = finished(init_state(), 6_000_000)
    assert [{_test, 6_000_000, _budget}] = state.offenders
  end

  test "the one-time Chrome startup is discounted from the test that absorbed it" do
    # Chrome cold start took 24s; a test measured 26s (24s of which is boot).
    :persistent_term.put(@connect_us_key, 24_000_000)
    state = finished(init_state(), 26_000_000)

    # 26s - 24s = 2s, under the 4s default budget → not an offender, and
    # the discount is now spent.
    assert state.offenders == []
    assert state.startup_discount_spent?
  end

  test "the startup discount applies to at most one test" do
    :persistent_term.put(@connect_us_key, 24_000_000)

    state =
      init_state()
      # first over-budget test is rescued by the discount
      |> finished(26_000_000)
      # a SECOND over-budget test no longer gets the discount → offender
      |> finished(26_000_000)

    assert [{_t, 26_000_000, _b}] = state.offenders
  end

  test "a genuinely slow test still flags even with the discount available" do
    :persistent_term.put(@connect_us_key, 24_000_000)
    # 60s test: even minus 24s boot = 36s, well over budget.
    state = finished(init_state(), 60_000_000)

    assert [{_t, 60_000_000, _b}] = state.offenders
    refute state.startup_discount_spent?
  end
end
