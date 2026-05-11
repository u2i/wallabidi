defmodule Wallabidi.Integration.LiveViewSmoke.TriggerActionTest do
  use Wallabidi.Integration.SessionCase, async: true

  alias Wallabidi.Query

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  @tag :native_form_submit
  @tag :cross_lv_nav
  # Real validate→flip→submit→POST→redirect chain across two LV processes.
  @tag :polling
  test "phx-trigger-action: validate → flip → native submit → POST → redirect", %{
    session: session
  } do
    # The 4-step AshAuthentication pattern:
    #   1. phx-submit fires LV validate
    #   2. server flips @trigger_action truthy
    #   3. LV client JS sees the flip and fires a native form submit
    #   4. POST to /trigger-action-target redirects somewhere
    # The driver's click classifier has to recognise phx-trigger-action
    # and wait for the full page load, not just the LV patch.
    # Assert on the destination content — assert_has polls within
    # max_wait_time so it gives the LV patch + native form submit +
    # POST + redirect chain time to play out. refute_has won't wait
    # the same way (returns the instant the absence is true, which
    # can be the pre-redirect snapshot).
    session
    |> visit(@base <> "/trigger-action")
    |> click(Query.css("#ta-submit"))
    |> assert_has(Query.css("#full-dest-title", text: "Full Nav Destination"))
  end
end
