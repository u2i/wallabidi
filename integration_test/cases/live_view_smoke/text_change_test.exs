defmodule Wallabidi.Integration.LiveViewSmoke.TextChangeTest do
  use Wallabidi.Integration.SessionCase, async: true

  alias Wallabidi.Query

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  test "connected? mount fires send(self, :load_data) and updates text", %{session: session} do
    # Initial render returns "Loading..." / "pending"; after the LV
    # WebSocket connects, mount sends :load_data which updates the text
    # to "Dashboard" / "ready". Asserting on the post-connect text means
    # the LiveSocket has connected and the patch has landed.
    session
    |> visit(@base <> "/text-change")
    |> assert_has(Query.css("#title", text: "Dashboard"))
    |> assert_has(Query.css("#status", text: "ready"))
  end

  test "phx-click with phx-value-* sends parameterized event", %{session: session} do
    session
    |> visit(@base <> "/text-change")
    |> assert_has(Query.css("#title", text: "Dashboard"))
    |> click(Query.css("#rename"))
    |> assert_has(Query.css("#title", text: "Renamed"))
  end
end
