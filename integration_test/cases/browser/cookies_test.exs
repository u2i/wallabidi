defmodule Wallabidi.Integration.Browser.CookiesTest do
  use Wallabidi.Integration.SessionCase, async: true
  @moduletag :headless

  alias Wallabidi.CookieError

  describe "cookies/1" do
    test "returns all of the cookies in the browser", %{session: session} do
      list =
        session
        |> visit("/")
        |> Browser.cookies()

      assert list == []
    end
  end

  describe "set_cookie/3" do
    test "sets a cookie in the browser", %{session: session} do
      cookie =
        session
        |> visit("/")
        |> Browser.set_cookie("api_token", "abc123")
        |> visit("/index.html")
        |> Browser.cookies()
        |> hd()

      assert cookie["name"] == "api_token"
      assert cookie["value"] == "abc123"
      assert cookie["path"] == "/"
      assert cookie["secure"] == false
      assert cookie["httpOnly"] == false
    end

    test "without visiting a page first throws an error", %{session: session} do
      assert_raise CookieError, fn ->
        session
        |> Browser.set_cookie("other_cookie", "test")
      end
    end
  end

  describe "set_cookie/4" do
    test "preserves cookie attributes round-trip", %{session: session} do
      # Verify our set_cookie/4 wrapper passes attrs through to the
      # browser AND reads them back. We avoid two browser-quirk
      # variations:
      #
      #   * `secure: true` — secure cookies are only returned for
      #     HTTPS URLs (Chrome relaxes this for localhost; Lightpanda
      #     doesn't), and the test server runs on plain HTTP.
      #   * `path: "/index.html"` — Lightpanda's cookie jar requires
      #     the cookie path to be a strict prefix of the URL path,
      #     so an exact-match path like `/index.html` for URL
      #     `/index.html` returns nothing on LP. Chromium's
      #     net::CookieMonster matches on exact-equal too.
      #
      # Both are about how *browsers* expose cookies — orthogonal to
      # whether our API forwards attrs correctly. Use `path: "/"`
      # which is unambiguous everywhere.
      expiry = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(1000)

      cookie =
        session
        |> visit("/")
        |> Browser.set_cookie("api_token", "abc123",
          path: "/",
          httpOnly: true,
          expiry: expiry
        )
        |> visit("/index.html")
        |> Browser.cookies()
        |> hd()

      assert cookie["name"] == "api_token"
      assert cookie["value"] == "abc123"
      assert cookie["path"] == "/"
      assert cookie["httpOnly"] == true
      assert cookie["expiry"] == expiry
    end

    test "without visiting a page first throws an error", %{session: session} do
      assert_raise CookieError, fn ->
        session
        |> Browser.set_cookie("other_cookie", "test", httpOnly: true)
      end
    end
  end
end
