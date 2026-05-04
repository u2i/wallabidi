defmodule Wallabidi.V2.WebSocketTest do
  use ExUnit.Case, async: true

  alias Wallabidi.V2.WebSocket

  # Smoke tests for the public API surface. The end-to-end flow
  # (connect, encode JSON, route responses, fan out events) is
  # exercised when V2.Session lands and the integration suite runs
  # against it.

  describe "module shape" do
    test "exports the expected functions" do
      funs = WebSocket.__info__(:functions)
      assert {:start_link, 1} in funs
      assert {:cast_send, 4} in funs
      assert {:cast_send, 5} in funs
      assert {:subscribe, 2} in funs
      assert {:subscribe, 4} in funs
      assert {:unsubscribe, 4} in funs
      assert {:unsubscribe_all, 2} in funs
      assert {:close, 1} in funs
    end

    test "has expected default state fields" do
      state = %WebSocket{}
      assert state.next_id == 1
      assert state.pending == %{}
      assert state.queued == []
      assert state.websocket == nil
    end
  end
end
