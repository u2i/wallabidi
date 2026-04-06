defmodule Wallabidi.Integration.Chrome.TraceTimingTest do
  @moduledoc false

  # Breaks down per-operation timing to find where time goes under load.
  # Run with:  WALLABIDI_DRIVER=chrome_cdp mix test integration_test/chrome/trace_timing_test.exs --include trace

  use Wallabidi.Integration.SessionCase, async: true

  @moduletag :trace

  setup do
    url = Application.fetch_env!(:wallabidi, :live_app_url)
    {:ok, live_url: url}
  end

  test "per-operation breakdown for js-toggle scenario", %{session: session, live_url: url} do
    t = fn label, fun ->
      t0 = System.monotonic_time(:microsecond)
      result = fun.()
      elapsed = System.monotonic_time(:microsecond) - t0
      IO.puts("  #{String.pad_trailing(label, 40)} #{div(elapsed, 1000)}ms")
      result
    end

    IO.puts("\n--- js-toggle timing breakdown ---")

    session = t.("visit", fn -> visit(session, "#{url}/js-toggle") end)

    t.("find [id='#menu-btn']", fn ->
      find(session, Query.css("[id='#menu-btn']"))
    end)

    t.("click [id='#menu-btn']", fn ->
      click(session, Query.css("[id='#menu-btn']"))
    end)

    t.("assert_has #menu-content", fn ->
      assert_has(session, Query.css("#menu-content", text: "Menu is open"))
    end)

    IO.puts("--- end ---\n")
  end

  test "per-operation breakdown for navigate scenario", %{session: session, live_url: url} do
    t = fn label, fun ->
      t0 = System.monotonic_time(:microsecond)
      result = fun.()
      elapsed = System.monotonic_time(:microsecond) - t0
      IO.puts("  #{String.pad_trailing(label, 40)} #{div(elapsed, 1000)}ms")
      result
    end

    IO.puts("\n--- navigate timing breakdown ---")

    session = t.("visit /nav-source", fn -> visit(session, "#{url}/nav-source") end)

    t.("click #go-to-dest", fn ->
      click(session, Query.css("#go-to-dest"))
    end)

    IO.puts("--- end ---\n")
  end

  test "raw RPC round-trip latency", %{session: session, live_url: url} do
    session = visit(session, "#{url}/counter")

    times =
      for _ <- 1..20 do
        t0 = System.monotonic_time(:microsecond)
        {:ok, _} = Wallabidi.Protocol.eval(session, "1+1")
        System.monotonic_time(:microsecond) - t0
      end

    sorted = Enum.sort(times)
    IO.puts("\n--- raw eval RPC latency (20 calls) ---")
    IO.puts("  min=#{div(Enum.min(sorted), 1000)}ms  median=#{div(Enum.at(sorted, 10), 1000)}ms  max=#{div(Enum.max(sorted), 1000)}ms")
    IO.puts("--- end ---\n")
  end
end
