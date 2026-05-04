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

    test "the destination URL is reflected by location.href", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      url = base <> "/" <> @url_for

      {:ok, _} = CDPClient.navigate(session, url)
      # Briefly wait for the load to settle. evaluate against the
      # post-navigate page returns the new URL once the document is
      # parsed; we poll up to ~500ms.
      assert eventually(fn ->
               case CDPClient.evaluate(session, "location.href") do
                 {:ok, ^url} -> true
                 _ -> false
               end
             end)
    end
  end

  defp eventually(fun, attempts \\ 25, sleep \\ 20)

  defp eventually(_fun, 0, _sleep), do: false

  defp eventually(fun, attempts, sleep) do
    if fun.() do
      true
    else
      Process.sleep(sleep)
      eventually(fun, attempts - 1, sleep)
    end
  end
end
