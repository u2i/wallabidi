defmodule Wallabidi.Integration.LiveView.SlowDestMountTest do
  # Regression test for the teamology StudentImpersonationTest flake.
  #
  # Scenario: phx-click="start-session" → fast handle_event → push_navigate
  # → destination LV with a slow mount (Ash query loading conversation +
  # student + character + messages under sandbox ownership). Source-side
  # everything is quick; the bottleneck is the destination's mount.
  #
  # Trace through the click path (browser.ex do_post_click "patch" + true):
  #   1. await_patch(1_000) — no patch (server picked push_navigate);
  #      times out at 1s.
  #   2. await_ack — server acks handle_event quickly (it's fast).
  #   3. await_page_ready_after(pre_page_id, 1_000) — waits for the new
  #      page's bootstrap notification, but the destination's mount is
  #      slow, so page_ready fires at ~3s, past this 1s budget.
  # Wallabidi returns; downstream assert_has runs against an in-flight
  # navigation; element not found.
  #
  # The fix raises the patch-branch's page_ready timeout to match the
  # navigate branch's default (5s).

  use Wallabidi.Integration.SessionCase, async: false

  @moduletag :browser

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  test "patch-classified click with slow handle_event + slow dest mount waits for page_ready",
       %{session: session} do
    session = visit(session, @base <> "/slow-evt-slow-dest")

    click(session, Query.css("#start-link"))

    # current_url does not poll. If wallabidi returned before the
    # destination's slow mount finished, we'd still be on the source URL.
    assert current_url(session) =~ "/slow-evt-slow-dest-target",
           "click returned before destination mount completed — current_url is #{current_url(session)}"

    assert_has(session, Query.css("#ready", text: "ready"))
  end
end
