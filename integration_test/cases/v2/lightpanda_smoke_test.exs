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
      url = base <> "/" <> @url_for

      assert {:ok, %{loader_id: loader_id, frame_id: frame_id}} =
               CDPClient.navigate(session, url)

      assert is_binary(loader_id) or is_nil(loader_id)
      assert is_binary(frame_id) or is_nil(frame_id)
    end

    test "navigate + await_page_load: location.href reflects new URL", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      url = base <> "/" <> @url_for

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
      url = base <> "/index.html"

      assert :ok = CDPClient.visit(session, url)
      assert {:ok, ^url} = CDPClient.evaluate(session, "location.href")
    end
  end
end
