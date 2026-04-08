defmodule Wallabidi.Integration.Chrome.LoadStaleTest do
  @moduledoc false

  # Focused load test: many sessions concurrently visiting a page with
  # a time-sensitive element. Reproduces the flaky stale_nodes failure
  # by running the scenario enough times under concurrent load to surface
  # any visit-latency-driven race.

  use ExUnit.Case, async: false
  use Wallabidi.DSL


  setup do
    url = Application.fetch_env!(:wallabidi, :live_app_url)
    {:ok, live_app_url: url}
  end

  # stale_nodes.html removes #removed-node after 3000ms.
  # If visit + find takes longer than 3s, the test fails.
  test "visit+find finishes well before stale-node removal under load", %{live_app_url: _url} do
    base_url = Application.fetch_env!(:wallabidi, :base_url)

    results =
      1..16
      |> Task.async_stream(
        fn _ ->
          start = System.monotonic_time(:millisecond)
          {:ok, session} = Wallabidi.start_session()

          try do
            visit_time = System.monotonic_time(:millisecond)

            session
            |> visit("#{base_url}/stale_nodes.html")
            |> find(Query.css("#removed-node"))

            find_time = System.monotonic_time(:millisecond)
            total = find_time - start
            visit_only = find_time - visit_time
            {:ok, %{total: total, visit_and_find: visit_only}}
          rescue
            e ->
              elapsed = System.monotonic_time(:millisecond) - start
              {:error, %{elapsed: elapsed, error: Exception.message(e)}}
          after
            Wallabidi.end_session(session)
          end
        end,
        max_concurrency: 16,
        timeout: 30_000
      )
      |> Enum.to_list()

    successes = for {:ok, {:ok, stats}} <- results, do: stats
    failures = for r <- results, not match?({:ok, {:ok, _}}, r), do: r

    if successes != [] do
      times = Enum.map(successes, & &1.visit_and_find)
      sorted = Enum.sort(times)

      IO.puts(
        "  #{length(successes)}/16 visit+find: " <>
          "min=#{List.first(sorted)}ms " <>
          "median=#{Enum.at(sorted, div(length(sorted), 2))}ms " <>
          "max=#{List.last(sorted)}ms " <>
          "spread=#{List.last(sorted) - List.first(sorted)}ms"
      )
    end

    if failures != [] do
      IO.puts("failures:")

      for f <- failures do
        IO.puts("  - #{inspect(f)}")
      end
    end

    assert failures == [],
           "#{length(failures)}/16 sessions failed. " <>
             "If all succeeded but took >3s, the stale_nodes test flake is a " <>
             "visit-latency issue, not a driver bug."
  end
end
