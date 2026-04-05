defmodule Wallabidi.Integration.Chrome.LoadMailboxTest do
  @moduledoc false

  # Load test that specifically exercises sequential scenarios in the same
  # process and verifies that the mailbox is cleaned up between sessions.
  #
  # The hypothesis we're testing: `Page.loadEventFired` events from a
  # previous session's navigations can linger in the test process mailbox
  # and be consumed by the next session's `wait_for_page_load`, causing it
  # to return before the new page has actually loaded.
  #
  # This test:
  #   1. Runs a scenario (visit → interact)
  #   2. Ends the session
  #   3. Counts any leftover `:bidi_event` messages in the mailbox
  #   4. Repeats N times
  #   5. Asserts the mailbox is clean between scenarios
  #
  # Also measures per-iteration timing so any degradation is visible.

  use ExUnit.Case, async: false
  use Wallabidi.DSL

  @moduletag :load

  setup do
    url = Application.fetch_env!(:wallabidi, :live_app_url)
    {:ok, live_app_url: url}
  end

  test "sequential sessions leave no stale events in mailbox", %{live_app_url: url} do
    iterations = 10

    stats =
      for i <- 1..iterations do
        before_count = count_bidi_events()
        start = System.monotonic_time(:millisecond)

        {:ok, session} = Wallabidi.start_session()

        try do
          session
          |> visit("#{url}/counter")
          |> assert_has(Query.css("#count", text: "0"))
          |> click(Query.css("#inc"))
          |> assert_has(Query.css("#count", text: "1"))
        after
          Wallabidi.end_session(session)
        end

        duration = System.monotonic_time(:millisecond) - start
        after_count = count_bidi_events()
        leftover = drain_and_log_bidi_events(i)

        IO.puts(
          "iteration #{i}: #{duration}ms " <>
            "(mailbox before=#{before_count} after=#{after_count} leftover=#{leftover})"
        )

        %{iteration: i, duration: duration, leftover: leftover}
      end

    total_leftover = Enum.sum(Enum.map(stats, & &1.leftover))
    durations = Enum.map(stats, & &1.duration)

    IO.puts("")
    IO.puts("summary:")
    IO.puts("  min=#{Enum.min(durations)}ms max=#{Enum.max(durations)}ms")
    IO.puts("  first=#{List.first(durations)}ms last=#{List.last(durations)}ms")
    IO.puts("  total leftover messages across iterations: #{total_leftover}")

    assert total_leftover == 0,
           "Mailbox leaked #{total_leftover} :bidi_event messages across #{iterations} iterations. " <>
             "Per-iteration: #{inspect(Enum.map(stats, & &1.leftover))}"
  end

  # Count :bidi_event messages currently in the mailbox without removing them.
  defp count_bidi_events do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.count(messages, &match?({:bidi_event, _, _}, &1))
  end

  # Drain all :bidi_event messages and log them (method names only).
  defp drain_and_log_bidi_events(iteration) do
    methods = collect_bidi_methods([])

    if methods != [] do
      IO.puts(
        "  iteration #{iteration}: leftover events: #{Enum.join(methods, ", ")}"
      )
    end

    length(methods)
  end

  defp collect_bidi_methods(acc) do
    receive do
      {:bidi_event, method, _} -> collect_bidi_methods([method | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
