defmodule Wallabidi.Bench.Timing do
  @moduledoc false

  # Opt-in CDP send/recv gap accumulator. Enabled when the
  # WALLABIDI_BENCH_TIMING env var is set. When disabled, every
  # function in this module is a no-op so there's zero overhead.
  #
  # Usage:
  #   1. Call `setup/0` once at app boot.
  #   2. PerSession.Actor calls `mark_now/0` on send and passes the
  #      timestamp to `record/1` once the matching response arrives.
  #   3. At end of run, call `report/0` to print totals.

  @table :wallabidi_bench_timing
  @outliers :wallabidi_bench_outliers
  @outlier_threshold_ns 1_000_000_000

  def enabled?, do: System.get_env("WALLABIDI_BENCH_TIMING") in ["1", "true"]

  def setup do
    if enabled?() and :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
      :ets.insert(@table, [{:total_ns, 0}, {:count, 0}, {:max_ns, 0}])
      :ets.new(@outliers, [:named_table, :public, :duplicate_bag, write_concurrency: true])
    end

    :ok
  end

  @compile {:inline, mark_now: 0}
  def mark_now, do: :erlang.monotonic_time(:nanosecond)

  def record(start_ns, method \\ nil)

  def record(start_ns, method) when is_integer(start_ns) do
    if enabled?() and :ets.info(@table) != :undefined do
      diff = :erlang.monotonic_time(:nanosecond) - start_ns
      :ets.update_counter(@table, :total_ns, diff)
      :ets.update_counter(@table, :count, 1)
      [{:max_ns, cur_max}] = :ets.lookup(@table, :max_ns)
      if diff > cur_max, do: :ets.insert(@table, {:max_ns, diff})

      if method && diff >= @outlier_threshold_ns do
        :ets.insert(@outliers, {method, diff})
      end

      if method do
        method_total_key = {:method_total_ns, method}
        method_count_key = {:method_count, method}
        :ets.update_counter(@table, method_total_key, diff, {method_total_key, 0})
        :ets.update_counter(@table, method_count_key, 1, {method_count_key, 0})
      end
    end

    :ok
  end

  def record(_, _), do: :ok

  def reset do
    if enabled?() and :ets.info(@table) != :undefined do
      :ets.insert(@table, [{:total_ns, 0}, {:count, 0}, {:max_ns, 0}])
    end

    :ok
  end

  def snapshot do
    if enabled?() and :ets.info(@table) != :undefined do
      [{:total_ns, total}] = :ets.lookup(@table, :total_ns)
      [{:count, count}] = :ets.lookup(@table, :count)
      [{:max_ns, max}] = :ets.lookup(@table, :max_ns)
      %{total_ns: total, count: count, max_ns: max}
    else
      %{total_ns: 0, count: 0, max_ns: 0}
    end
  end

  def report do
    if enabled?() do
      %{total_ns: total, count: count, max_ns: max} = snapshot()
      total_ms = div(total, 1_000_000)
      avg_us = if count > 0, do: div(total, count) |> div(1_000), else: 0
      max_ms = div(max, 1_000_000)

      IO.puts(
        :stderr,
        "[wallabidi-bench] CDP gap: #{count} calls, total=#{total_ms}ms, " <>
          "avg=#{avg_us}us, max=#{max_ms}ms"
      )

      # Per-method roll-up: top by total time spent.
      method_rows =
        :ets.tab2list(@table)
        |> Enum.flat_map(fn
          {{:method_total_ns, m}, t} -> [{m, t}]
          _ -> []
        end)

      counts =
        :ets.tab2list(@table)
        |> Enum.flat_map(fn
          {{:method_count, m}, c} -> [{m, c}]
          _ -> []
        end)
        |> Map.new()

      method_rows
      |> Enum.sort_by(fn {_, t} -> -t end)
      |> Enum.take(10)
      |> Enum.each(fn {m, t} ->
        c = Map.get(counts, m, 0)
        avg_ms = if c > 0, do: div(t, c) |> div(1_000_000), else: 0

        IO.puts(
          :stderr,
          "[wallabidi-bench]   #{String.pad_trailing(m, 42)} " <>
            "n=#{String.pad_leading(to_string(c), 5)} " <>
            "tot=#{String.pad_leading(to_string(div(t, 1_000_000)), 6)}ms " <>
            "avg=#{avg_ms}ms"
        )
      end)

      # Long-tail outliers (>1s).
      outliers =
        if :ets.info(@outliers) != :undefined,
          do: :ets.tab2list(@outliers) |> Enum.sort_by(fn {_, ns} -> -ns end),
          else: []

      if outliers != [] do
        IO.puts(:stderr, "[wallabidi-bench] long-tail (>1s) by method:")

        outliers
        |> Enum.group_by(fn {m, _} -> m end, fn {_, ns} -> ns end)
        |> Enum.sort_by(fn {_, l} -> -length(l) end)
        |> Enum.each(fn {m, durations} ->
          n = length(durations)
          avg = (Enum.sum(durations) / n) |> trunc()
          mx = Enum.max(durations)

          IO.puts(
            :stderr,
            "[wallabidi-bench]   #{String.pad_trailing(m, 42)} " <>
              "n=#{String.pad_leading(to_string(n), 4)} " <>
              "avg=#{div(avg, 1_000_000)}ms " <>
              "max=#{div(mx, 1_000_000)}ms"
          )
        end)
      end
    end

    :ok
  end
end
