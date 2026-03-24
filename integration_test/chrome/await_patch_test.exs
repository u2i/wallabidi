defmodule Wallabidi.Integration.AwaitPatchTest do
  use ExUnit.Case, async: true
  use Wallabidi.DSL

  setup do
    live_url = Application.get_env(:wallabidi, :live_app_url)
    {:ok, session} = Wallabidi.start_session()
    {:ok, session: session, live_url: live_url}
  end

  describe "await_patch (via click)" do
    test "click waits for LiveView patch before returning", %{session: session, live_url: url} do
      session
      |> visit("#{url}/counter")
      |> assert_has(Query.css("#count", text: "0"))
      |> click(Query.css("#inc"))
      # No settle() needed — click auto-awaits the patch
      |> assert_has(Query.css("#count", text: "1"))
    end

    test "multiple clicks await each patch", %{session: session, live_url: url} do
      session
      |> visit("#{url}/counter")
      |> click(Query.css("#inc"))
      |> click(Query.css("#inc"))
      |> click(Query.css("#inc"))
      |> assert_has(Query.css("#count", text: "3"))
    end

    test "awaits slow server-side processing", %{session: session, live_url: url} do
      session
      |> visit("#{url}/counter")
      |> click(Query.css("#slow-inc"))
      # Server takes 500ms — await_patch waits for the reply
      |> assert_has(Query.css("#count", text: "1"))
      |> assert_has(Query.css("#message", text: "done"))
    end
  end

  describe "await_patch (explicit)" do
    test "standalone await_patch waits for next patch", %{session: session, live_url: url} do
      session
      |> visit("#{url}/counter")
      |> assert_has(Query.css("#count", text: "0"))
      # Use execute_script to trigger a click, then await_patch explicitly
      |> execute_script("document.getElementById('inc').click()")
      |> await_patch()
      |> assert_has(Query.css("#count", text: "1"))
    end
  end

  describe "async LiveView updates" do
    test "await_patch catches async result after start_async", %{session: session, live_url: url} do
      session
      |> visit("#{url}/async")
      |> assert_has(Query.css("#status", text: "idle"))
      |> click(Query.css("#load"))
      # click awaits the first patch (handle_event reply — no DOM change)
      # The async result comes 300ms later as a second patch
      |> await_patch()
      |> assert_has(Query.css("#status", text: "done"))
      |> assert_has(Query.css("#result", text: "async result"))
    end

    test "settle works for async chains", %{session: session, live_url: url} do
      session
      |> visit("#{url}/async")
      |> click(Query.css("#load"))
      |> settle()
      |> assert_has(Query.css("#result", text: "async result"))
    end
  end

  describe "text-aware await_selector" do
    test "assert_has with text waits for text content change", %{session: session, live_url: url} do
      # h1#title exists immediately (dead render) with "Loading..."
      # After connected mount + 200ms async load, it changes to "Dashboard"
      # await_selector should wait for the text, not just the element
      session
      |> visit("#{url}/text-change")
      |> assert_has(Query.css("#title", text: "Dashboard"))
    end

    test "assert_has with text after click", %{session: session, live_url: url} do
      session
      |> visit("#{url}/text-change")
      |> assert_has(Query.css("#title", text: "Dashboard"))
      |> click(Query.css("#rename"))
      |> assert_has(Query.css("#title", text: "Renamed"))
    end
  end

  describe "navigation + assert_has" do
    test "assert_has finds element after push_navigate", %{session: session, live_url: url} do
      session
      |> visit("#{url}/nav-source")
      |> assert_has(Query.css("#nav-source"))
      |> click(Query.css("#go-to-dest"))
      # This assert is on the DESTINATION page — await_selector must
      # bail on the navigation and let retry find it on the new page
      |> assert_has(Query.css("#dest-title", text: "Destination Page"))
    end

    test "click on navigate link doesn't waste 5s on await_patch", %{session: session, live_url: url} do
      start = System.monotonic_time(:millisecond)

      session
      |> visit("#{url}/nav-source")
      # click triggers push_navigate — await_patch should bail on URL change
      |> click(Query.css("#go-to-dest"))

      elapsed = System.monotonic_time(:millisecond) - start
      # click itself should return fast — not wait 5s for a patch
      assert elapsed < 3_000
    end

    test "click on navigate link waits for LiveView connected", %{session: session, live_url: url} do
      # NavDestLive has a 200ms sleep in connected mount. Without
      # await_liveview_connected, click returns before the LV connects
      # and the element doesn't exist yet (same live_session nav has
      # no dead render — DOM only appears after connected mount).
      session
      |> visit("#{url}/nav-source")
      |> click(Query.css("#go-to-dest"))
      |> execute_script(
        "var el = document.getElementById('lv-connected'); return el ? el.textContent : 'missing'",
        fn value -> assert value == "yes" end
      )
    end

    test "await_liveview_connected waits for NEW LiveView, not old one", %{session: session, live_url: url} do
      # Directly test that await_liveview_connected doesn't resolve
      # on the OLD liveSocket.main (which is already connected).
      # Use execute_script to trigger the click, then call
      # await_liveview_connected manually — without await_patch's delay.
      session = visit(session, "#{url}/nav-source")
      {:ok, pre_url} = Wallabidi.BiDiClient.current_url(session)
      execute_script(session, "document.getElementById('go-to-dest').click()")
      Wallabidi.BiDiClient.await_liveview_connected(session, pre_url: pre_url)

      execute_script(session,
        "var el = document.getElementById('lv-connected'); return el ? el.textContent : 'missing'",
        fn value -> assert value == "yes" end
      )
    end

    test "assert_has with text after navigation doesn't waste 5s", %{session: session, live_url: url} do
      start = System.monotonic_time(:millisecond)

      session
      |> visit("#{url}/nav-source")
      |> click(Query.css("#go-to-dest"))
      |> assert_has(Query.css("#dest-status", text: "arrived"))

      elapsed = System.monotonic_time(:millisecond) - start
      # Should be well under 5s — navigation detection bails fast
      assert elapsed < 4_000
    end
  end

  describe "full page navigation" do
    test "click on plain link waits for page load and LV connected", %{session: session, live_url: url} do
      # #go-full-nav is a plain <a href="/full-nav-dest"> — no data-phx-link.
      # This triggers a full HTTP navigation to a different live_session.
      # FullNavDestLive has a 200ms sleep in connected mount.
      # Without waiting for page load + LV connected, the element
      # either doesn't exist (page not loaded) or shows "no".
      session
      |> visit("#{url}/nav-source")
      |> click(Query.css("#go-full-nav"))
      |> execute_script(
        "var el = document.getElementById('full-lv-connected'); return el ? el.textContent : 'missing'",
        fn value -> assert value == "yes" end
      )
    end
  end

  describe "XPath query classification" do
    test "click via XPath on navigate link waits for LV connected", %{session: session, live_url: url} do
      # XPath queries currently default to :patch — they should detect
      # the actual binding on the resolved element. This navigate link
      # has a 200ms slow mount on the destination.
      session
      |> visit("#{url}/nav-source")
      |> click(Query.xpath("//a[@id='go-to-dest']"))
      |> execute_script(
        "var el = document.getElementById('lv-connected'); return el ? el.textContent : 'missing'",
        fn value -> assert value == "yes" end
      )
    end

    test "click via XPath on plain link waits for page load", %{session: session, live_url: url} do
      session
      |> visit("#{url}/nav-source")
      |> click(Query.xpath("//a[@id='go-full-nav']"))
      |> execute_script(
        "var el = document.getElementById('full-lv-connected'); return el ? el.textContent : 'missing'",
        fn value -> assert value == "yes" end
      )
    end
  end

  describe "form submit with redirect" do
    test "phx-submit that redirects waits for page load and LV connected", %{session: session, live_url: url} do
      # The form has phx-submit (classified as :patch), but the server
      # handler calls redirect/2 which triggers a full page navigation.
      # Without handling this, await_patch fails with stale context.
      session
      |> visit("#{url}/form-redirect")
      |> click(Query.css("#submit-btn"))
      |> execute_script(
        "var el = document.getElementById('full-lv-connected'); return el ? el.textContent : 'missing'",
        fn value -> assert value == "yes" end
      )
    end

    test "phx-submit redirect is detected quickly, not via 5s timeout", %{session: session, live_url: url} do
      start = System.monotonic_time(:millisecond)

      session
      |> visit("#{url}/form-redirect")
      |> click(Query.css("#submit-btn"))
      |> assert_has(Query.css("#full-dest-title", text: "Full Nav Destination"))

      elapsed = System.monotonic_time(:millisecond) - start
      # beforeunload resolves immediately — should be well under 2s
      assert elapsed < 2_000
    end
  end

  describe "multiple matching elements" do
    test "assert_has with text checks all matching elements", %{session: session, live_url: url} do
      session
      |> visit("#{url}/multi")
      |> assert_has(Query.css(".message", text: "Hello"))
      |> assert_has(Query.css(".message", text: "World"))
      |> click(Query.css("#add"))
      # "New message" is the THIRD .message — querySelector would miss it
      |> assert_has(Query.css(".message", text: "New message"))
    end
  end

  describe "fallback on non-LiveView pages" do
    @tag :pending
    test "click works normally on plain HTML pages", %{session: session} do
      session
      |> visit("/click.html")
      |> click(Query.css("#button"))
      |> assert_has(Query.css("#log", text: "Left"))
    end
  end
end
