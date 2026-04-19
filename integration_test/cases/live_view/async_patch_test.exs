defmodule Wallabidi.Integration.LiveView.AsyncPatchTest do
  # Regression tests for CI-only flakes exposed by teamology u2i/teamology#586.
  #
  # Covers three click-then-render scenarios where wallabidi's post-click
  # awaits need to track more than the initial LiveView patch:
  #
  # 1. start_async — a click triggers both a synchronous assign and a
  #    deferred handle_async update. Assertions against the async result
  #    must wait for the async phase, not just the initial patch.
  #
  # 2. phx-trigger-action — a click triggers a phx-submit event, which
  #    flips @trigger_action, which triggers a native form POST to a
  #    controller that redirects. The load-bearing transition is a full
  #    page load, not the LV patch that flips the attribute.
  #
  # 3. Cross-session PubSub — session A's action broadcasts a message;
  #    session B's LV receives handle_info and re-renders. Session B's
  #    assertion must wait for the re-render.

  use Wallabidi.Integration.SessionCase, async: false

  # These tests exercise JavaScript-driven behaviour (phx-trigger-action
  # native submits, JS.navigate, async patches, PubSub-triggered re-renders)
  # so they only run on drivers that execute JS.
  @moduletag :browser

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  describe "start_async" do
    test "assert_has waits for handle_async-driven update", %{session: session} do
      session
      |> visit(@base <> "/async")
      |> assert_has(Query.css("#text", text: "idle"))
      |> click(Query.button("Go"))
      # First the synchronous assign makes "First" visible; the async
      # update arrives ~500ms later and replaces it with "Second".
      |> assert_has(Query.css("#text", text: "Second"))
    end
  end

  describe "phx-trigger-action" do
    test "click on submit button awaits the full-page redirect", %{session: session} do
      # The click fires phx-submit, which flips trigger_action, which fires
      # a native POST to /trigger-action-target, which redirects to
      # /full-nav-dest. assert_has on the destination content must wait
      # for the full chain, not the intermediate LV patch.
      session
      |> visit(@base <> "/trigger-action")
      |> click(Query.button("Sign in"))
      |> assert_has(Query.css("#full-dest-title", text: "Full Nav Destination"))
      |> assert_has(Query.css("#full-lv-connected", text: "yes"))
    end
  end

  describe "cross-session PubSub" do
    @tag :browser
    test "session B sees the broadcast from session A", %{session: session_a} do
      {:ok, session_b} = start_test_session()

      session_a |> visit(@base <> "/pubsub")
      session_b |> visit(@base <> "/pubsub")

      # Both start at "waiting"
      session_a |> assert_has(Query.css("#message", text: "waiting"))
      session_b |> assert_has(Query.css("#message", text: "waiting"))

      # Session A broadcasts; session B should receive via handle_info
      # and re-render. The assertion on session B must wait for the
      # asynchronous handle_info-driven patch.
      session_a |> click(Query.button("Broadcast"))

      session_b |> assert_has(Query.css("#message", text: "received"))
    end
  end
end
