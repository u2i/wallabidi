defmodule Wallabidi.Test.SlowTestGuard do
  @moduledoc """
  Custom ExUnit formatter that flags tests exceeding a runtime budget.

  Tests come in two budgets:

    * **Default** — `WALLABIDI_SLOW_TEST_MS` (1500ms by default). Untagged
      tests must finish within this. Anything slower indicates a real perf
      regression in the driver, an unwanted polling fallback, or a
      test that's now legitimately slow and needs a tag.

    * **Per-test slow budget** — opt-in via `@tag :slow` (4000ms default)
      or `@tag slow: N_ms` for an explicit budget. For tests that
      legitimately wait — refute_has, slow handle_event scenarios, multi-
      session lifecycle checks. Tests still fail if they exceed *their*
      declared budget.

  Defaults to `:raise` mode (the suite exits non-zero if any offender is
  found). Override with `WALLABIDI_SLOW_TEST_MODE=warn` for a softer
  signal during local development.

  Attach in your `test_helper.exs`:

      ExUnit.start(formatters: [ExUnit.CLIFormatter, Wallabidi.Test.SlowTestGuard])
  """

  use GenServer

  @default_threshold_ms 1500
  @default_slow_budget_ms 5000

  @impl true
  def init(_opts) do
    threshold_ms =
      case System.get_env("WALLABIDI_SLOW_TEST_MS") do
        nil -> @default_threshold_ms
        s -> String.to_integer(s)
      end

    mode =
      case System.get_env("WALLABIDI_SLOW_TEST_MODE") do
        "warn" -> :warn
        _ -> :raise
      end

    {:ok,
     %{
       threshold_us: threshold_ms * 1000,
       mode: mode,
       offenders: []
     }}
  end

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    case test.time do
      nil ->
        {:noreply, state}

      time when is_integer(time) ->
        budget_us = budget_for(test, state.threshold_us)

        if time > budget_us do
          {:noreply, %{state | offenders: [{test, time, budget_us} | state.offenders]}}
        else
          {:noreply, state}
        end
    end
  end

  def handle_cast({:suite_finished, _times_us}, %{offenders: []} = state) do
    {:noreply, state}
  end

  def handle_cast({:suite_finished, _times_us}, %{offenders: offenders, mode: mode} = state) do
    msg = format_offenders(offenders)

    case mode do
      :raise ->
        IO.puts(:stderr, msg)
        # System.at_exit so the message is the LAST thing the user sees
        # AND the suite exits non-zero so CI catches it.
        System.at_exit(fn _ -> exit({:shutdown, 1}) end)

      :warn ->
        IO.puts(:stderr, msg)
    end

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  # Tag handling:
  #   * `slow: N` (integer ms) — explicit budget
  #   * `slow: true` or `:slow` tag without value — default slow budget
  #   * `:polling` tag (legacy) — synonym for `:slow`, default slow budget
  #   * untagged — default threshold
  defp budget_for(%ExUnit.Test{tags: tags}, default_threshold_us) do
    cond do
      is_integer(slow = Map.get(tags, :slow)) -> slow * 1000
      Map.get(tags, :slow) == true -> @default_slow_budget_ms * 1000
      Map.get(tags, :polling) == true -> @default_slow_budget_ms * 1000
      true -> default_threshold_us
    end
  end

  defp format_offenders(offenders) do
    count = length(offenders)

    header =
      "\n\n#{count} test(s) exceeded their runtime budget:\n" <>
        "(Either tag with @tag slow: N (ms) — or investigate; this likely indicates\n" <>
        " a perf regression or an unwanted polling fallback.)\n"

    rows =
      offenders
      |> Enum.sort_by(fn {_t, time, _b} -> -time end)
      |> Enum.map_join("\n", fn {test, time, budget_us} ->
        time_ms = div(time, 1000)
        budget_ms = div(budget_us, 1000)
        "  #{time_ms}ms  (budget #{budget_ms}ms)  #{test.module}.#{test.name}"
      end)

    header <> rows <> "\n"
  end
end
