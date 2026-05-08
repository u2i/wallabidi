defmodule Wallabidi.Integration.LiveView.SlowEventAckTest do
  # Regression test for the teamology "Start Session" slow-event race.
  #
  # Scenario: phx-click on an <a> triggers a server handle_event that
  # does 2s of work (DB, state transitions) before calling push_navigate.
  # The current await_patch has a 1s budget — it times out, then
  # await_page_ready_after runs with another 1s budget, total 2s. The
  # server's push_navigate arrives right around that boundary, so the
  # assertion after the click frequently races the redirect.
  #
  # The fix (see do_post_click/4 for "patch" classification) waits on
  # the LiveView's own server-ack signal — view.lastAckRef reaching the
  # ref we captured pre-click — so the click-to-next-assertion path
  # waits for the server to actually finish its work, however long.

  use Wallabidi.Integration.SessionCase, async: false

  @moduletag :headless

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  test "click returns only after the server has acked the slow event",
       %{session: session} do
    # After the click, current_url should already be the destination. If
    # wallabidi returns while the server is still processing the event,
    # current_url still points at the source page. current_url does NOT
    # poll — it reports whatever the browser has right now.
    session = visit(session, @base <> "/slow-event")

    click(session, Query.css("#start-link"))

    assert current_url(session) =~ "/slow-event-dest",
           "click returned before server processed the event — current_url is still #{current_url(session)}"
  end
end
