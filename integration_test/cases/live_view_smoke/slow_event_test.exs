defmodule Wallabidi.Integration.LiveViewSmoke.SlowEventTest do
  use Wallabidi.Integration.SessionCase, async: true

  alias Wallabidi.Query

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  @tag :cross_lv_nav
  test "click → 3s server work → push_navigate; assertion waits for full transition", %{
    session: session
  } do
    # SlowEventLive.handle_event sleeps 3s in the server before
    # push_navigate-ing to /slow-event-dest. A driver that returns
    # from `click/2` before the LV ack would race the assertion. This
    # is the canonical "did the driver wait long enough?" test.
    session
    |> visit(@base <> "/slow-event")
    |> click(Query.css("#start-link"))
    |> assert_has(Query.css("#dest-title", text: "Session Started"))
  end
end
