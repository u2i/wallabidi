defmodule Wallabidi.Integration.LiveViewSmoke.NavigationTest do
  use Wallabidi.Integration.SessionCase, async: true

  alias Wallabidi.Query

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  @tag :cross_lv_nav
  test "<.link navigate>: same live_session, dest LV mounts", %{session: session} do
    # push_navigate within a single live_session — no full page reload.
    # The dest LV's mount sleeps 200ms in connected? branch; asserting
    # on lv-connected="yes" means the click waited for the destination
    # LV to finish its slow connected mount, not just for the URL change.
    session
    |> visit(@base <> "/nav-source")
    |> click(Query.css("#go-to-dest"))
    |> assert_has(Query.css("#dest-title", text: "Destination Page"))
    |> assert_has(Query.css("#lv-connected", text: "yes"))
  end

  @tag :cross_lv_nav
  test "<a href>: full page load across live_sessions", %{session: session} do
    # Crossing live_session boundaries forces a full HTTP navigation.
    # The LV-driver in-process is scoped to one LV at a time and can't
    # follow this; browser drivers can.
    session
    |> visit(@base <> "/nav-source")
    |> click(Query.css("#go-full-nav"))
    |> assert_has(Query.css("#full-dest-title", text: "Full Nav Destination"))
    |> assert_has(Query.css("#full-lv-connected", text: "yes"))
  end
end
