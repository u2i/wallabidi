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
