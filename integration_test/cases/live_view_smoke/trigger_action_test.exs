defmodule Wallabidi.Integration.LiveViewSmoke.TriggerActionTest do
  use Wallabidi.Integration.SessionCase, async: true

  alias Wallabidi.Query

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  @tag :native_form_submit
  @tag :cross_lv_nav
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
    session
    |> visit(@base <> "/trigger-action")
    |> click(Query.css("#ta-submit"))
    # The controller redirects somewhere — minimum smoke is that we
    # leave the trigger-action page (i.e. didn't get stuck on the
    # original LV after the patch landed).
    |> refute_has(Query.css("#ta-form"))
  end
end
