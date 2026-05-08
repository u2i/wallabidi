defmodule Wallabidi.Integration.LiveView.JoinPendingWaitTest do
  # Regression test for the teamology nav-click flake root cause.
  #
  # The /join-pending page presents a fake window.liveSocket whose
  # main.joinPending starts `true` and flips to `false` 800ms later.
  # A button's onclick records the delta between click time and flip
  # time into #jp-output.
  #
  # Wallabidi's click_full op should wait for !joinPending before
  # dispatching the synthetic click. If it does, the delta is >= 0
  # (click landed AFTER the flip). If it doesn't, the click lands
  # during the pending window and the delta is negative.

  use Wallabidi.Integration.SessionCase, async: false

  @moduletag :headless

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  test "click waits for liveSocket.main.joinPending to flip false", %{session: session} do
    session = visit(session, @base <> "/join-pending")

    # Let the page install its fake liveSocket (T+50ms). After this
    # sleep the window has liveSocket.main.joinPending === true, and
    # the flip will happen another ~750ms later.
    Process.sleep(150)

    click(session, Query.button("Click me"))

    text = Wallabidi.Browser.text(session, Query.css("#jp-output"))

    assert text != "unclicked", "click never landed"

    assert text == "clicked-after-flip",
           "click landed while liveSocket.main.joinPending was still true — " <>
             "the pre-click readiness wait didn't run (got #{inspect(text)})"
  end
end
