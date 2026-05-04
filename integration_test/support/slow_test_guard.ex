defmodule Wallabidi.Integration.SlowTestGuard do
  @moduledoc false

  # Custom ExUnit formatter that flags tests running longer than a
  # threshold without an explicit `@tag :polling`.
  #
  # Wallabidi has tests that intentionally wait the full
  # `max_wait_time` (3000ms) — they assert absence (refute_has,
  # find/not-found, has_value? with the wrong value, etc.). Those
  # are tagged `:polling` so we can:
  #
  #   1. Exclude them from benchmarks (perf signal isn't meaningful
  #      when tests are pinned to a 3-second deadline anyway).
  #
  #   2. Catch new tests that accidentally hit polling paths — those
  #      indicate either a real perf regression in the driver
  #      (e.g. Browser.click falling through to a polling find
  #      fallback) or a missing tag.
  #
  # The default threshold (1500ms) is keyed off Wallabidi's
  # `max_wait_time` (3000ms) — anything over half that is suspicious
  # for a non-polling test. Tag legitimately-slow tests with
  # `@tag :polling` (the guard skips them).
  #
  # Override the threshold via `WALLABIDI_SLOW_TEST_MS=N` and switch
  # mode via `WALLABIDI_SLOW_TEST_MODE=raise|warn` (default `warn`).

  use GenServer

  @default_threshold_ms 1500

  # ----- Formatter callbacks -----

  @impl true
  def init(opts) do
    threshold_ms =
      case System.get_env("WALLABIDI_SLOW_TEST_MS") do
        nil -> Keyword.get(opts, :slow_test_threshold_ms, @default_threshold_ms)
        s -> String.to_integer(s)
      end

    mode =
      case System.get_env("WALLABIDI_SLOW_TEST_MODE") do
        "raise" -> :raise
        _ -> :warn
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

      time when time >= state.threshold_us ->
        if has_polling_tag?(test) do
          {:noreply, state}
        else
          {:noreply, %{state | offenders: [{test, time} | state.offenders]}}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:suite_finished, _times_us}, %{offenders: []} = state) do
    {:noreply, state}
  end

  def handle_cast({:suite_finished, _times_us}, %{offenders: offenders, mode: mode} = state) do
    msg = format_offenders(offenders, state.threshold_us)

    case mode do
      :raise ->
        IO.puts(:stderr, msg)
        # Use System.at_exit so the message is the LAST thing the user sees
        # AND the suite exits non-zero so CI catches it.
        System.at_exit(fn _ -> exit({:shutdown, 1}) end)

      _ ->
        IO.puts(:stderr, msg)
    end

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  # ----- Helpers -----

  defp has_polling_tag?(%ExUnit.Test{tags: tags}) do
    Map.get(tags, :polling) == true
  end

  defp format_offenders(offenders, threshold_us) do
    threshold_ms = div(threshold_us, 1000)
    count = length(offenders)

    header =
      "\n\n#{count} test(s) ran longer than #{threshold_ms}ms without `@tag :polling`:\n" <>
        "(Either tag them or investigate — they may be hitting unwanted polling paths.)\n"

    rows =
      offenders
      |> Enum.sort_by(fn {_t, time} -> -time end)
      |> Enum.map_join("\n", fn {test, time} ->
        "  #{div(time, 1000)}ms  #{test.module}.#{test.name}"
      end)

    header <> rows <> "\n"
  end
end
