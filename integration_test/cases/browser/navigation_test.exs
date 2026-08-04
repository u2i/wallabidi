defmodule Wallabidi.Integration.Browser.NavigationTest do
  use Wallabidi.Integration.SessionCase, async: true

  test "navigating by path only", %{session: session} do
    visit(session, "page_1.html")

    element =
      session
      |> find(Query.css(".blue"))

    assert element
  end

  test "visit/2 with an absolute path does not use the base url", %{session: session} do
    session
    |> visit("/page_1.html")

    assert has_css?(session, "#visible")
  end

  @tag :headless
  test "status/1 reports the HTTP status of the visited page", %{session: session} do
    visit(session, "page_1.html")
    assert status(session) == 200

    # An error status is not a navigation failure — the page loads normally
    # and visit/2 does not raise, so status/1 is the only way to see it.
    visit(session, "no_such_page_here.html")
    assert status(session) == 404
  end

  @tag :headless
  test "response_headers/1 exposes the response headers", %{session: session} do
    visit(session, "page_1.html")

    headers = response_headers(session)
    assert is_map(headers)
    assert headers["content-type"] =~ "text/html"
  end

  # A failed navigation used to return normally, leaving the browser on the
  # previously loaded page — so every subsequent read silently returned stale
  # content from the page before it.
  @tag :headless
  test "visit/2 raises rather than leaving the previous page loaded", %{session: session} do
    visit(session, "page_1.html")
    assert has_css?(session, "#visible")

    # Port 1 on loopback: nothing listens, so the connection is refused
    # without any DNS lookup or network egress.
    assert_raise Wallabidi.NavigationError, ~r/Failed to navigate/, fn ->
      visit(session, "http://127.0.0.1:1/unreachable.html")
    end
  end
end
