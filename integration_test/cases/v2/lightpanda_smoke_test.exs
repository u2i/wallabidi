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
end
