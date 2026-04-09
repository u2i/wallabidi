defmodule Wallabidi.Integration.Browser.SessionIsolationTest do
  use ExUnit.Case, async: true
  use Wallabidi.DSL

  import Wallabidi.Integration.SessionCase, only: [start_test_session: 0]

  @moduletag :isolation

  test "concurrent sessions have independent browsing contexts" do
    {:ok, session_a} = start_test_session()
    {:ok, session_b} = start_test_session()

    # Navigate each session to a different page
    session_a |> visit("page_1.html")
    session_b |> visit("index.html")

    # Each session sees its own page
    assert_has(session_a, Query.text("Page 1"))
    refute_has(session_a, Query.text("Test Index"))

    assert_has(session_b, Query.css("#header", text: "Test Index"))

    Wallabidi.end_session(session_a)
    Wallabidi.end_session(session_b)
  end

  @tag :browser
  test "concurrent sessions have independent cookies" do
    {:ok, session_a} = start_test_session()
    {:ok, session_b} = start_test_session()

    session_a |> visit("/")
    session_b |> visit("/")

    # Set a cookie in session A only
    session_a |> Browser.set_cookie("test_cookie", "from_a")

    # Session B should not see session A's cookie
    cookies_b = Browser.cookies(session_b)
    cookie_names = Enum.map(cookies_b, & &1["name"])
    refute "test_cookie" in cookie_names

    # Session A should see its own cookie
    cookies_a = Browser.cookies(session_a)
    assert Enum.any?(cookies_a, &(&1["name"] == "test_cookie"))

    Wallabidi.end_session(session_a)
    Wallabidi.end_session(session_b)
  end

  test "ending one session does not affect another" do
    {:ok, session_a} = start_test_session()
    {:ok, session_b} = start_test_session()

    session_a |> visit("page_1.html")
    session_b |> visit("page_1.html")

    # End session A
    Wallabidi.end_session(session_a)

    # Session B still works
    assert_has(session_b, Query.text("Page 1"))
    title = Browser.page_title(session_b)
    assert is_binary(title)

    Wallabidi.end_session(session_b)
  end
end
