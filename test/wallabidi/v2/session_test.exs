defmodule Wallabidi.V2.SessionTest do
  use ExUnit.Case, async: true

  alias Wallabidi.V2.Session

  describe "module shape" do
    test "exports the expected functions" do
      funs = Session.__info__(:functions)
      assert {:start_link, 1} in funs
      assert {:cdp_send, 3} in funs
      assert {:cdp_send, 4} in funs
      assert {:stop, 1} in funs
    end

    test "has expected default state fields" do
      state = %Session{}
      assert state.pending_calls == %{}
      assert state.session == nil
      assert state.ws_pid == nil
    end
  end
end
