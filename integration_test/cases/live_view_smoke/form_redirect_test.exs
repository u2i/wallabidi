defmodule Wallabidi.Integration.LiveViewSmoke.FormRedirectTest do
  use Wallabidi.Integration.SessionCase, async: true

  alias Wallabidi.Query

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  @tag :native_form_submit
  @tag :cross_lv_nav
  test "phx-submit then server redirect across live_session", %{session: session} do
    # FormRedirectLive's handle_event redirects to /full-nav-dest, which
    # is in a different live_session. That forces a full page reload —
    # exercises both native form submit (via the type=submit button)
    # and cross-live_session navigation.
    session
    |> visit(@base <> "/form-redirect")
    |> click(Query.css("#submit-btn"))
    |> assert_has(Query.css("#full-dest-title", text: "Full Nav Destination"))
  end
end
