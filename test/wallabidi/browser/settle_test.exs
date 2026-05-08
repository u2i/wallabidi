defmodule Wallabidi.Browser.SettleTest do
  use ExUnit.Case, async: true

  alias Wallabidi.Browser
  alias Wallabidi.Session

  describe "settle/2 with non-BiDi session" do
    test "returns session immediately (no-op)" do
      session = %Session{id: "test", bidi_pid: nil}
      assert ^session = Browser.settle(session)
    end

    test "accepts options and still returns session" do
      session = %Session{id: "test", bidi_pid: nil}
      assert ^session = Browser.settle(session, timeout: 1000, idle_time: 100)
    end
  end

  describe "on_console/2 with non-BiDi session" do
    test "returns session immediately (no-op)" do
      session = %Session{id: "test", bidi_pid: nil}
      assert ^session = Browser.on_console(session, fn _level, _msg -> :ok end)
    end
  end

  describe "intercept_request/3" do
    test "raises RuntimeError (V1 BiDi feature retired, V2 not yet ported)" do
      session = %Session{id: "test", bidi_pid: nil}

      assert_raise RuntimeError, ~r/not currently supported/, fn ->
        Browser.intercept_request(session, "/api/*", %{status: 200, body: "ok"})
      end
    end
  end
end
