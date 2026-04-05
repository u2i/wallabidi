defmodule Wallabidi.Integration.LoadTestCase do
  @moduledoc false

  # Shared load-test scenario that exercises a realistic multi-interaction
  # LiveView flow. Used by each driver's integration suite to verify
  # behavior under concurrent load.
  #
  # Each test spawns N parallel sessions, each running a scenario with
  # multiple LiveView interactions (clicks, fills, navigations, async
  # updates). All must complete without errors.
  #
  # The `live_app_url` must be configured. For Chrome (BiDi and CDP) this
  # is a full http://host:port URL. For the LiveView driver it can be
  # anything — the driver extracts just the path.
  #
  # Runs the same scenario for each driver, so we can compare behavior
  # and catch regressions specific to concurrent test execution.

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: true
      use Wallabidi.DSL
      import Wallabidi.Integration.LoadTestCase

      @sessions_per_test 8
    end
  end

  require Wallabidi.Browser
  import Wallabidi.Browser
  alias Wallabidi.Query

  @doc """
  Runs the counter scenario: visit, click N times, assert count, exercise
  slow handler, assert server-side state.
  """
  def counter_scenario(url) do
    {:ok, session} = Wallabidi.start_session()

    try do
      session
      |> visit("#{url}/counter")
      |> assert_has(Query.css("#count", text: "0"))
      |> click(Query.css("#inc"))
      |> click(Query.css("#inc"))
      |> click(Query.css("#inc"))
      |> assert_has(Query.css("#count", text: "3"))
      |> click(Query.css("#slow-inc"))
      |> assert_has(Query.css("#count", text: "4"))
      |> assert_has(Query.css("#message", text: "done"))
    after
      Wallabidi.end_session(session)
    end
  end

  @doc """
  Runs the form scenario: visit, fill a field, verify live echo, submit,
  assert submitted state.
  """
  def form_scenario(url) do
    {:ok, session} = Wallabidi.start_session()

    try do
      session
      |> visit("#{url}/form")
      |> fill_in(Query.text_field("email"), with: "user@test.com")
      |> assert_has(Query.css("#server-email", text: "user@test.com"))
      |> click(Query.css("#submit-email"))
      |> assert_has(Query.css("#submitted", text: "user@test.com"))
    after
      Wallabidi.end_session(session)
    end
  end

  @doc """
  Runs N scenarios concurrently via Task.async_stream. Fails if any
  scenario raises or times out. Reports per-session timing stats so
  variance under load is visible in test output.
  """
  def run_parallel(scenario_fun, count, timeout \\ 60_000) when is_function(scenario_fun, 0) do
    results =
      1..count
      |> Task.async_stream(
        fn _i ->
          start = System.monotonic_time(:millisecond)

          try do
            scenario_fun.()
            {:ok, System.monotonic_time(:millisecond) - start}
          rescue
            e -> {:error, e, System.monotonic_time(:millisecond) - start}
          end
        end,
        max_concurrency: count,
        timeout: timeout,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.to_list()

    durations =
      for {:ok, {:ok, ms}} <- results, do: ms

    failures =
      for r <- results, not match?({:ok, {:ok, _}}, r), do: r

    report_timing(durations, count)

    if failures != [] do
      raise "#{length(failures)} of #{count} parallel sessions failed:\n#{format_failures(failures)}"
    end

    :ok
  end

  defp report_timing([], _count) do
    IO.puts("  (no successful sessions to time)")
  end

  defp report_timing(durations, count) do
    sorted = Enum.sort(durations)
    min = List.first(sorted)
    max = List.last(sorted)
    sum = Enum.sum(sorted)
    avg = div(sum, length(sorted))
    median = Enum.at(sorted, div(length(sorted), 2))
    n = length(sorted)

    IO.puts(
      "  #{n}/#{count} sessions " <>
        "min=#{min}ms median=#{median}ms avg=#{avg}ms max=#{max}ms " <>
        "spread=#{max - min}ms"
    )
  end

  defp format_failures(failures) do
    failures
    |> Enum.take(5)
    |> Enum.map_join("\n", fn
      {:ok, {:error, e, ms}} -> "  - #{ms}ms: #{Exception.message(e)}"
      {:exit, reason} -> "  - task exit: #{inspect(reason)}"
      other -> "  - #{inspect(other)}"
    end)
  end
end
