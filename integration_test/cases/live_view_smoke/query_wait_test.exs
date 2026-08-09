defmodule Wallabidi.Integration.LiveViewSmoke.QueryWaitTest do
  @moduledoc """
  The `wait:` query option — wallabidi's vocabulary for "now" and "not yet",
  alongside its existing "eventually" (see issue #67).

  `/dependent-selects` is the optimistic-UI shape this exists for: a client
  -side select updates in the same task as the event, while a server-rendered
  one can't change until the round-trip completes. With the latency simulator
  holding the reply, the two are distinguishable — but only if an assertion
  can ask "is it there *right now*" rather than "does it appear eventually".
  """
  use Wallabidi.Integration.SessionCase, async: false
  @moduletag :headless

  alias Wallabidi.LiveView

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  describe "wait: 0" do
    test "refute_has means 'absent right now', not 'never appears'", %{session: session} do
      session
      |> visit(@base <> "/dependent-selects")
      |> LiveView.set_latency(1_000)

      session = click(session, Query.css("#country option[value='CA']", visible: :any))

      # The client-side select has already updated, in the same task as the
      # change event.
      assert_has(session, Query.css("#fast-region option", text: "Ontario", visible: :any))

      # The server-rendered one cannot have: the reply is still in flight.
      # Without `wait: 0` this would retry for the full max_wait_time, find
      # the legitimate patch land at ~1s, and fail — the exact trap that
      # produced the false bug report in #67.
      refute_has(
        session,
        Query.css("#slow-region option", text: "Ontario", visible: :any, wait: 0)
      )

      # And it does arrive, once the round-trip completes.
      assert_has(session, Query.css("#slow-region option", text: "Ontario", visible: :any))
    end

    test "returns promptly rather than burning the wait budget", %{session: session} do
      visit(session, @base <> "/dependent-selects")

      elapsed =
        time_ms(fn ->
          refute_has(session, Query.css("#nothing-here", wait: 0))
        end)

      assert elapsed < 500,
             "wait: 0 took #{elapsed}ms — expected a single check, not a wait"
    end
  end

  describe "wait: n" do
    test "overrides max_wait_time for one query", %{session: session} do
      session
      |> visit(@base <> "/dependent-selects")
      |> LiveView.set_latency(600)

      session = click(session, Query.css("#country option[value='CA']", visible: :any))

      # A budget longer than the latency window: the server patch lands
      # inside it, so this passes where `wait: 0` would (correctly) not.
      assert_has(
        session,
        Query.css("#slow-region option", text: "Ontario", visible: :any, wait: 5_000)
      )
    end

    test "a too-short budget gives up before a slow element arrives", %{session: session} do
      session
      |> visit(@base <> "/dependent-selects")
      |> LiveView.set_latency(1_500)

      session = click(session, Query.css("#country option[value='CA']", visible: :any))

      refute_has(
        session,
        Query.css("#slow-region option", text: "Ontario", visible: :any, wait: 200)
      )
    end
  end

  describe "validation" do
    test "rejects a negative wait", %{session: session} do
      visit(session, @base <> "/dependent-selects")

      assert_raise Wallabidi.QueryError, ~r/not a non-negative number/, fn ->
        find(session, Query.css("#country", wait: -1))
      end
    end

    test "rejects a non-integer wait", %{session: session} do
      visit(session, @base <> "/dependent-selects")

      assert_raise Wallabidi.QueryError, ~r/not a non-negative number/, fn ->
        find(session, Query.css("#country", wait: :forever))
      end
    end
  end

  defp time_ms(fun) do
    t0 = System.monotonic_time(:millisecond)
    fun.()
    System.monotonic_time(:millisecond) - t0
  end
end
