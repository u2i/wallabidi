defmodule Wallabidi.Integration.Chrome.LoadTest do
  @moduledoc false

  use Wallabidi.Integration.LoadTestCase
  @moduletag :load

  # Concurrent LiveView load test — exercises connection management,
  # session cleanup, event handling, and DOM diffing under load.

  setup do
    url = Application.fetch_env!(:wallabidi, :live_app_url)
    {:ok, live_app_url: url}
  end

  test "counter scenario runs cleanly in parallel", %{live_app_url: url} do
    run_parallel(fn -> counter_scenario(url) end, @sessions_per_test)
  end

  test "form scenario runs cleanly in parallel", %{live_app_url: url} do
    run_parallel(fn -> form_scenario(url) end, @sessions_per_test)
  end

  test "mixed scenarios run cleanly in parallel", %{live_app_url: url} do
    scenarios = [
      fn -> counter_scenario(url) end,
      fn -> form_scenario(url) end
    ]

    results =
      1..@sessions_per_test
      |> Task.async_stream(
        fn i -> Enum.at(scenarios, rem(i, length(scenarios))).() end,
        max_concurrency: @sessions_per_test,
        timeout: 60_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, _}, &1)),
           "mixed scenarios had failures: #{inspect(results)}"
  end

  test "sequential scenarios reuse cleanly", %{live_app_url: url} do
    for _ <- 1..3 do
      counter_scenario(url)
      form_scenario(url)
    end
  end

  test "counter scenario — 3 consecutive parallel batches (variance check)", %{live_app_url: url} do
    for i <- 1..3 do
      IO.write("batch #{i}: ")
      run_parallel(fn -> counter_scenario(url) end, @sessions_per_test)
    end
  end
end
