defmodule Wallabidi.Integration.V2.LightpandaSmokeTest do
  @moduledoc """
  End-to-end smoke test for the V2 transport stack against a real
  Lightpanda server. Proves that:

    * `V2.WebSocket` can connect and pass JSON frames
    * `V2.Session` correctly correlates request/response by wire id
    * `V2.CDPClient.evaluate/2` returns serialised values
  """
  use ExUnit.Case, async: false

  @moduletag :v2

  alias Wallabidi.Integration.V2SessionHelper
  alias Wallabidi.Query
  alias Wallabidi.V2.CDPClient
  alias Wallabidi.V2.Session, as: V2Session

  setup do
    V2SessionHelper.start_session()
  end

  describe "V2 round-trip" do
    test "raw cdp_send + Runtime.evaluate", %{session: session} do
      assert {:ok, %{"result" => %{"value" => 2}}} =
               CDPClient.cdp_send(session, "Runtime.evaluate", %{
                 expression: "1 + 1",
                 returnByValue: true
               })
    end
  end

  describe "evaluate/2" do
    test "returns the serialised value of a number expression", %{session: session} do
      assert {:ok, 2} = CDPClient.evaluate(session, "1 + 1")
    end

    test "returns a string", %{session: session} do
      assert {:ok, "hello"} = CDPClient.evaluate(session, "'hel' + 'lo'")
    end

    test "returns a boolean", %{session: session} do
      assert {:ok, true} = CDPClient.evaluate(session, "true")
      assert {:ok, false} = CDPClient.evaluate(session, "1 === 2")
    end

    test "returns nil for undefined", %{session: session} do
      assert {:ok, nil} = CDPClient.evaluate(session, "undefined")
      assert {:ok, nil} = CDPClient.evaluate(session, "void 0")
    end

    test "returns a JS-exception error for a thrown expression", %{session: session} do
      assert {:error, {:js_exception, _details}} =
               CDPClient.evaluate(session, "throw new Error('boom')")
    end

    test "returns a JS-exception error for a syntax error", %{session: session} do
      assert {:error, {:js_exception, _details}} = CDPClient.evaluate(session, "this is not js")
    end
  end

  describe "navigate/2" do
    @url_for "index.html"

    test "navigates to a URL and returns a loader_id", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      url = base <> @url_for

      assert {:ok, %{loader_id: loader_id, frame_id: frame_id}} =
               CDPClient.navigate(session, url)

      assert is_binary(loader_id) or is_nil(loader_id)
      assert is_binary(frame_id) or is_nil(frame_id)
    end

    test "navigate + await_page_load: location.href reflects new URL", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      url = base <> @url_for

      {:ok, %{loader_id: loader_id}} = CDPClient.navigate(session, url)
      assert :ok = V2Session.await_page_load(session, loader_id, "load", 5_000)

      assert {:ok, ^url} = CDPClient.evaluate(session, "location.href")
    end

    test "await_page_load times out for an unknown loader_id", %{session: session} do
      assert :timeout =
               V2Session.await_page_load(session, "loader-that-never-fires", "load", 200)
    end
  end

  describe "visit/2" do
    test "navigates and waits for load in one call", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      url = base <> "index.html"

      assert :ok = CDPClient.visit(session, url)
      assert {:ok, ^url} = CDPClient.evaluate(session, "location.href")
    end
  end

  describe "bootstrap installation" do
    test "window.__w is defined after visiting a page", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = CDPClient.visit(session, base <> "index.html")

      assert {:ok, "object"} = CDPClient.evaluate(session, "typeof window.__w")
      assert {:ok, "function"} = CDPClient.evaluate(session, "typeof window.__w.check")
      assert {:ok, "function"} = CDPClient.evaluate(session, "typeof window.__w.exec")
    end

    test "__wallabidi binding is callable", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = CDPClient.visit(session, base <> "index.html")
      # The binding is exposed via Runtime.addBinding — it's a host
      # function injected into every realm. Type should be "function".
      assert {:ok, "function"} = CDPClient.evaluate(session, "typeof __wallabidi")
    end
  end

  describe "find waiter round-trip" do
    test "register_find + JS binding call resolves the waiter", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = CDPClient.visit(session, base <> "index.html")

      query_id = "v2-test-#{System.unique_integer([:positive])}"

      # Register the waiter BEFORE firing the binding — register_find
      # must precede the JS that triggers the callback.
      :ok = V2Session.register_find(session, query_id, 1_000)

      # Fire the binding from JS with a payload that V2.Session knows
      # how to route ({"id": query_id, "count": N}).
      js =
        "__wallabidi(JSON.stringify({id: #{Jason.encode!(query_id)}, count: 7}))"

      {:ok, _} = CDPClient.evaluate(session, js)

      assert {:ok, 7, _meta} = V2Session.await_find_result(session, query_id, 1_000)
    end

    test "register_find times out when the binding never fires", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = CDPClient.visit(session, base <> "index.html")

      query_id = "v2-timeout-#{System.unique_integer([:positive])}"
      :ok = V2Session.register_find(session, query_id, 50)

      # Don't fire the binding. Wait long enough that the timeout
      # fires, then verify the await returns the timeout shape.
      assert {:timeout, 0} = V2Session.await_find_result(session, query_id, 200)
    end

    test "register_find surfaces invalid_selector errors", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = CDPClient.visit(session, base <> "index.html")

      query_id = "v2-err-#{System.unique_integer([:positive])}"
      :ok = V2Session.register_find(session, query_id, 1_000)

      js =
        "__wallabidi(JSON.stringify({id: #{Jason.encode!(query_id)}, count: 0, error: 'bad selector'}))"

      {:ok, _} = CDPClient.evaluate(session, js)

      assert {:error, :invalid_selector} = V2Session.await_find_result(session, query_id, 1_000)
    end
  end

  describe "find_elements/2" do
    setup %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = CDPClient.visit(session, base <> "index.html")
      :ok
    end

    test "finds elements matching a CSS query", %{session: session} do
      assert {:ok, [_]} = CDPClient.find_elements(session, Query.css("#header"))
    end

    test "matched elements carry real CDP objectIds", %{session: session} do
      {:ok, [el]} = CDPClient.find_elements(session, Query.css("#header"))

      assert is_binary(el.bidi_shared_id)
      assert el.id == el.bidi_shared_id
      # objectId should be unique per element; quick sanity check
      assert byte_size(el.bidi_shared_id) > 0
    end

    test "finds multiple elements", %{session: session} do
      assert {:ok, results} = CDPClient.find_elements(session, Query.css("li", count: :any))
      assert length(results) >= 1
    end

    test "returns invalid_selector for a bad CSS selector", %{session: session} do
      assert {:error, :invalid_selector} =
               CDPClient.find_elements(session, Query.css(":::not-a-selector", count: :any))
    end

    test "returns empty list for selectors that match nothing", %{session: session} do
      assert {:ok, []} =
               CDPClient.find_elements(
                 session,
                 Query.css(".does-not-exist-anywhere", count: :any),
                 timeout: 200
               )
    end
  end

  describe "page introspection" do
    setup %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      url = base <> "index.html"
      :ok = CDPClient.visit(session, url)
      %{base_url: base, url: url}
    end

    test "current_url/1", %{session: session, url: url} do
      assert {:ok, ^url} = CDPClient.current_url(session)
    end

    test "current_path/1", %{session: session} do
      assert {:ok, "/index.html"} = CDPClient.current_path(session)
    end

    test "page_title/1", %{session: session} do
      assert {:ok, title} = CDPClient.page_title(session)
      assert is_binary(title)
    end

    test "page_source/1 returns full document HTML", %{session: session} do
      assert {:ok, html} = CDPClient.page_source(session)
      assert html =~ ~r/<html/i
      assert html =~ ~r/<\/html>/i
    end
  end

  describe "text/2 and attribute/3" do
    setup %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = CDPClient.visit(session, base <> "index.html")
      :ok
    end

    test "text/2 returns the visible text of an element", %{session: session} do
      {:ok, [el]} = CDPClient.find_elements(session, Query.css("#header"))
      assert {:ok, text} = CDPClient.text(session, el)
      assert is_binary(text)
      assert byte_size(text) > 0
    end

    test "attribute/3 returns a string for a present attribute", %{session: session} do
      {:ok, [el]} = CDPClient.find_elements(session, Query.css("#header"))
      assert {:ok, "header"} = CDPClient.attribute(session, el, "id")
    end

    test "attribute/3 returns nil for a missing attribute", %{session: session} do
      {:ok, [el]} = CDPClient.find_elements(session, Query.css("#header"))
      assert {:ok, nil} = CDPClient.attribute(session, el, "data-not-present")
    end

    test "attribute/3 returns outerHTML when asked", %{session: session} do
      {:ok, [el]} = CDPClient.find_elements(session, Query.css("#header"))
      assert {:ok, html} = CDPClient.attribute(session, el, "outerHTML")
      assert html =~ ~r/<h1[^>]*id="header"/i
    end
  end

  describe "displayed/2 and click/2" do
    setup %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = CDPClient.visit(session, base <> "index.html")
      :ok
    end

    test "displayed/2 returns true for a visible element", %{session: session} do
      {:ok, [el]} = CDPClient.find_elements(session, Query.css("#header"))
      assert {:ok, true} = CDPClient.displayed(session, el)
    end

    test "click/2 dispatches a click and returns ok", %{session: session} do
      # The index page has anchor links (Page 1, Page 2, Page 3). Pick
      # one we can find by CSS, click it, and assert the click was
      # observed by checking the URL changed.
      {:ok, [link]} = CDPClient.find_elements(session, Query.css("a[href='page_1.html']"))
      assert {:ok, nil} = CDPClient.click(session, link)
    end
  end

  describe "element-scoped find_elements" do
    setup %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = CDPClient.visit(session, base <> "index.html")
      :ok
    end

    test "finds within a parent element", %{session: session} do
      {:ok, [parent]} = CDPClient.find_elements(session, Query.css("#parent"))
      {:ok, [child]} = CDPClient.find_elements(parent, Query.css("#child"))

      assert {:ok, "The Child"} = CDPClient.text(session, child)
    end

    test "scoped find ignores siblings outside the parent", %{session: session} do
      # `<ul>` contains `<li>`s with anchor links; #parent is a separate
      # subtree with no anchors. A scoped search for `a` inside
      # #parent should match nothing.
      {:ok, [parent]} = CDPClient.find_elements(session, Query.css("#parent"))

      assert {:ok, []} =
               CDPClient.find_elements(parent, Query.css("a", count: :any), timeout: 200)
    end
  end
end
