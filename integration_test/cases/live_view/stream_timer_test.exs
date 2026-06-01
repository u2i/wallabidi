defmodule Wallabidi.Integration.LiveView.StreamTimerTest do
  @moduledoc """
  Post-mount, self-scheduled patch chains that no browser interaction
  triggers — the combination that regressed in the wild (a
  `stream_insert` driven by a `Process.send_after` chain was never
  observed). Unlike the click-triggered async tests, there is nothing to
  hang the await on: after a plain `visit/2` the patches arrive on their
  own, so this exercises `assert_has`'s event-driven wait
  (`onPatchEnd` + MutationObserver) surviving across several unsolicited
  patches.

  Runs on every driver — including the in-process LV driver, where
  `Phoenix.LiveViewTest` processes the `send_after`-driven `handle_info`
  messages and re-renders, so the same assertions hold.
  """
  use Wallabidi.Integration.SessionCase, async: false

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  describe "self-scheduled patch chain (no interaction)" do
    test "mount-rendered content is present immediately", %{session: session} do
      session
      |> visit(@base <> "/stream-timer")
      |> assert_has(Query.css("#always", text: "Rendered at mount"))
    end

    test "stream_insert from a send_after chain is observed", %{session: session} do
      # Three messages stream-insert one per 50ms tick, post-mount, with
      # no click to await on. Asserting on the LAST one (Third) forces the
      # auto-wait to ride past the intermediate stream patches.
      session
      |> visit(@base <> "/stream-timer")
      |> assert_has(Query.css("#messages > div", text: "First message"))
      |> assert_has(Query.css("#messages > div", text: "Third message"))
    end

    test "all stream items end up present together", %{session: session} do
      session
      |> visit(@base <> "/stream-timer")
      # After the last insert, all three keyed children coexist.
      |> assert_has(Query.css("#messages > div", count: 3))
    end

    test "a longer plain-assign chain settles on its final value", %{session: session} do
      # #counter increments on each of 5 ticks. Asserting on 5 (not an
      # intermediate 1..4) checks the wait doesn't settle on an early patch.
      session
      |> visit(@base <> "/stream-timer")
      |> assert_has(Query.css("#counter", text: "5"))
    end
  end
end
