defmodule Wallabidi.Integration.LiveView.NavigateTimeoutTest do
  # Regression test for the teamology nav-click flake.
  #
  # Scenario: click a <.link navigate=...> pointing at a destination whose
  # connected mount takes longer than await_liveview_connected's deadline.
  # The current implementation (0.2.9) silently returns :ok from
  # do_post_click/4, masking the failure. The next assertion then fails
  # with a confusing "h1 not found" error against the still-rendered
  # source page, instead of "navigation timed out".
  #
  # Desired behaviour: wallabidi propagates the timeout. The click raises
  # a diagnostic error that names the missed URL transition, so the user
  # knows the navigation never completed.

  use Wallabidi.Integration.SessionCase, async: false

  @moduletag :browser

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  @tag slow: 8_000
  test "click on <.link navigate> whose destination is slower than the deadline raises a nav-timeout error",
       %{session: session} do
    # /slow-nav-dest sleeps 6s in connected mount — well past the 5s
    # await_liveview_connected deadline. The click should either succeed
    # (if the implementation waits longer / retries) or raise a clear
    # timeout error — NOT return silently and leave the test to discover
    # the missed navigation via a downstream assertion.

    session = visit(session, @base <> "/nav-source")

    # The error message names the URL we're stuck on (the source, since
    # we never left it), so the reader immediately sees that navigation
    # didn't happen rather than hunting for why a downstream h1 wasn't
    # found.
    assert_raise Wallabidi.NavigationTimeoutError, ~r/nav-source/, fn ->
      click(session, Query.link("Go to Slow Destination"))
    end
  end
end
