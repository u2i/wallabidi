defmodule Wallabidi.Integration.LiveView.OptimisticCounterTest do
  # Exercises the two-phase observation pattern enabled by
  # `Wallabidi.LiveView.with_latency/3` + `await: :defer` +
  # `Wallabidi.LiveView.await_patch/2`.
  #
  # The page paints an "optimistic" count immediately on click, then
  # reconciles when the server's reply lands. With ~300ms of simulated
  # latency we can assert on the optimistic span *between* the click
  # and the await.

  use Wallabidi.Integration.SessionCase, async: false

  alias Wallabidi.LiveView

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  describe "two-phase observation" do
    @tag :browser
    test "observes optimistic phase then reconciled phase", %{session: session} do
      session = visit(session, @base <> "/optimistic-counter")

      LiveView.with_latency(session, 300, fn s ->
        # Pre-click: both spans read "0".
        assert_has(s, Wallabidi.Query.css("#count", text: "0"))
        assert_has(s, Wallabidi.Query.css("#optimistic-count", text: "0"))

        s = click(s, Wallabidi.Query.button("Increment"), await: :defer)

        # Phase 1 (optimistic): #optimistic-count shows "1" before the
        # server has replied. #count is still the old authoritative "0"
        # until LV applies its patch.
        assert_has(s, Wallabidi.Query.css("#optimistic-count", text: "1"))

        s = LiveView.await_patch(s)

        # Phase 2 (reconciled): both read "1".
        assert_has(s, Wallabidi.Query.css("#count", text: "1"))
        assert_has(s, Wallabidi.Query.css("#optimistic-count", text: "1"))
        s
      end)
    end

    @tag :browser
    test "with_latency clears the simulator on exit", %{session: session} do
      session = visit(session, @base <> "/optimistic-counter")

      LiveView.with_latency(session, 300, fn s ->
        click(s, Wallabidi.Query.button("Increment"))
      end)

      # After exiting with_latency, a click without :defer should
      # round-trip at normal speed.
      session
      |> click(Wallabidi.Query.button("Increment"))
      |> assert_has(Wallabidi.Query.css("#count", text: "2"))
    end
  end
end
