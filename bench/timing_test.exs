defmodule Wallabidi.Integration.Chrome.TraceTimingTest do
  @moduledoc """
  Per-operation timing breakdown across drivers.

  Run individual drivers:

      WALLABIDI_DRIVER=chrome_cdp mix test integration_test/chrome/trace_timing_test.exs --include trace
      WALLABIDI_DRIVER=chrome     mix test integration_test/chrome/trace_timing_test.exs --include trace
      WALLABIDI_DRIVER=live_view  mix test integration_test/chrome/trace_timing_test.exs --include trace

  Compare all three:

      mix test integration_test/chrome/trace_timing_test.exs --include trace_all
  """

  use ExUnit.Case, async: false
  use Wallabidi.DSL


  @warmup_rounds 2
  @bench_rounds 5

  setup do
    {:ok, session} = Wallabidi.start_session()
    on_exit(fn -> Wallabidi.end_session(session) end)
    {:ok, session: session}
  end

  test "counter scenario — per-operation breakdown", %{session: session} do
    driver = Wallabidi.resolve_driver()
    IO.puts("\n  Driver: #{driver}")
    IO.puts("  Warmup: #{@warmup_rounds} rounds, Bench: #{@bench_rounds} rounds")
    run_counter_benchmark(session, driver)
  end

  test "raw RPC eval latency", %{session: session} do
    driver = Wallabidi.resolve_driver()

    if driver == :live_view do
      IO.puts("\n  Raw eval RPC: N/A (LiveView driver has no JS eval)")
    else
      session = visit(session, counter_url(driver))

      times =
        for _ <- 1..20 do
          t0 = System.monotonic_time(:microsecond)
          {:ok, _} = Wallabidi.Protocol.eval(session, "1+1")
          System.monotonic_time(:microsecond) - t0
        end

      sorted = Enum.sort(times)
      IO.puts("\n  Raw eval RPC (#{driver}) — 20 calls")

      IO.puts(
        "  min=#{us(Enum.min(sorted))}  median=#{us(Enum.at(sorted, 10))}  p95=#{us(Enum.at(sorted, 18))}  max=#{us(Enum.max(sorted))}"
      )
    end
  end

  test "compare all drivers" do
    drivers = [
      :lightpanda,
      :lightpanda_v2,
      :chrome_cdp,
      :chrome_cdp_v2,
      :chrome,
      :chrome_bidi_v2,
      :live_view
    ]

    results =
      for driver <- drivers, reduce: [] do
        acc ->
          opts =
            if driver == :live_view,
              do: [driver: driver, endpoint: Wallabidi.Integration.LiveApp.Endpoint],
              else: [driver: driver]

          case Wallabidi.start_session(opts) do
            {:ok, session} ->
              # Capture-and-continue so one driver's scenario failure
              # doesn't kill the rest of the comparison run.
              result =
                try do
                  {:ok, run_counter_benchmark(session, driver, quiet: true)}
                rescue
                  e -> {:error, Exception.message(e)}
                catch
                  kind, value -> {:error, Exception.format(kind, value)}
                end

              try do
                Wallabidi.end_session(session)
              catch
                _, _ -> :ok
              end

              case result do
                {:ok, timings} ->
                  [{driver, timings} | acc]

                {:error, msg} ->
                  IO.puts("  #{driver}: failed (#{String.slice(msg, 0, 120)})")
                  acc
              end

            {:error, reason} ->
              IO.puts("  #{driver}: skipped (#{inspect(reason)})")
              acc
          end
      end

    print_comparison(Enum.reverse(results))
  end

  # --- Helpers ---

  defp counter_url(:live_view), do: "/counter"

  defp counter_url(_browser_driver) do
    Application.get_env(:wallabidi, :live_app_url, "http://localhost:4321") <> "/counter"
  end

  defp run_counter_benchmark(session, driver, opts \\ []) do
    quiet = Keyword.get(opts, :quiet, false)
    url = counter_url(driver)

    for _ <- 1..@warmup_rounds, do: run_counter_scenario(session, url)

    all_timings = for _ <- 1..@bench_rounds, do: run_counter_scenario(session, url)

    ops = [:visit, :find, :click_1, :click_2, :click_3, :assert_count, :assert_done]
    aggregated = aggregate(all_timings, ops)

    unless quiet, do: print_single_report(driver, aggregated)
    aggregated
  end

  defp run_counter_scenario(session, url) do
    ops = []

    {session, ops} = timed(ops, :visit, fn -> visit(session, url) end)
    {_el, ops} = timed(ops, :find, fn -> find(session, Query.css("#count")) end)
    {session, ops} = timed(ops, :click_1, fn -> click(session, Query.css("#inc")) end)
    {session, ops} = timed(ops, :click_2, fn -> click(session, Query.css("#inc")) end)
    {session, ops} = timed(ops, :click_3, fn -> click(session, Query.css("#inc")) end)

    {session, ops} =
      timed(ops, :assert_count, fn -> assert_has(session, Query.css("#count", text: "3")) end)

    {_session, ops} =
      timed(ops, :assert_done, fn -> assert_has(session, Query.css("#count", text: "3")) end)

    ops
  end

  defp timed(ops, label, fun) do
    t0 = System.monotonic_time(:microsecond)
    result = fun.()
    elapsed = System.monotonic_time(:microsecond) - t0
    {result, [{label, elapsed} | ops]}
  end

  defp aggregate(all_timings, ops) do
    for op <- ops do
      values =
        all_timings
        |> Enum.flat_map(fn timings ->
          case List.keyfind(timings, op, 0) do
            {^op, us} -> [us]
            nil -> []
          end
        end)
        |> Enum.sort()

      n = length(values)

      if n > 0 do
        {op,
         %{
           min: Enum.min(values),
           median: Enum.at(values, div(n, 2)),
           max: Enum.max(values)
         }}
      else
        {op, %{min: 0, median: 0, max: 0}}
      end
    end
  end

  defp print_single_report(driver, aggregated) do
    total = Enum.reduce(aggregated, 0, fn {_, %{median: m}}, acc -> acc + m end)

    IO.puts("")
    IO.puts("  ┌──────────────────────────────────────────────────────┐")
    IO.puts("  │  #{pad("#{driver}", 52)}│")
    IO.puts("  ├──────────────────┬──────────┬──────────┬────────────┤")
    IO.puts("  │ Operation        │ Median   │ Min      │ Max        │")
    IO.puts("  ├──────────────────┼──────────┼──────────┼────────────┤")

    for {op, stats} <- aggregated do
      IO.puts(
        "  │ #{pad(op, 16)} │ #{pad(us(stats.median), 8)} │ #{pad(us(stats.min), 8)} │ #{pad(us(stats.max), 10)} │"
      )
    end

    IO.puts("  ├──────────────────┼──────────┼──────────┼────────────┤")
    IO.puts("  │ #{pad("TOTAL", 16)} │ #{pad(us(total), 8)} │          │            │")
    IO.puts("  └──────────────────┴──────────┴──────────┴────────────┘")
  end

  defp print_comparison(results) do
    ops = [:visit, :find, :click_1, :click_2, :click_3, :assert_count, :assert_done]

    drivers = Enum.map(results, &elem(&1, 0))
    col_w = 14

    IO.puts("")
    IO.puts("  Operation       " <> Enum.map_join(drivers, "", &pad("│ #{&1}", col_w + 1)) <> "│")

    IO.puts(
      "  " <>
        String.duplicate("─", 16) <>
        Enum.map_join(drivers, "", fn _ -> "┼" <> String.duplicate("─", col_w) end) <> "┼"
    )

    totals = Map.new(drivers, fn d -> {d, 0} end)

    totals =
      Enum.reduce(ops, totals, fn op, totals ->
        cells =
          for driver <- drivers do
            case List.keyfind(results, driver, 0) do
              {^driver, agg} ->
                case List.keyfind(agg, op, 0) do
                  {^op, %{median: m}} -> m
                  nil -> nil
                end

              nil ->
                nil
            end
          end

        row =
          Enum.map_join(cells, "", fn cell -> pad("│ #{us_or_na(cell)}", col_w + 1) end) <> "│"

        IO.puts("  #{pad(op, 16)}#{row}")

        Enum.zip(drivers, cells)
        |> Enum.reduce(totals, fn {d, v}, acc ->
          if v, do: Map.update!(acc, d, &(&1 + v)), else: acc
        end)
      end)

    IO.puts(
      "  " <>
        String.duplicate("─", 16) <>
        Enum.map_join(drivers, "", fn _ -> "┼" <> String.duplicate("─", col_w) end) <> "┼"
    )

    total_row =
      Enum.map_join(drivers, "", fn d ->
        pad("│ #{us_or_na(totals[d])}", col_w + 1)
      end) <> "│"

    IO.puts("  #{pad("TOTAL", 16)}#{total_row}")

    IO.puts("")
    IO.puts("  #{@warmup_rounds} warmup + #{@bench_rounds} bench rounds per driver, median shown")
  end

  defp pad(val, width), do: String.pad_trailing(to_string(val), width)

  # Format microseconds smartly: <1000 → "123us", >=1000 → "1.2ms"
  defp us(us) when us < 1000, do: "#{us}us"
  defp us(us) when us < 10_000, do: "#{Float.round(us / 1000, 1)}ms"
  defp us(us), do: "#{div(us, 1000)}ms"

  defp us_or_na(nil), do: "-"
  defp us_or_na(val), do: us(val)
end
