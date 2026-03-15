defmodule Wallabidi.Integration.WallabidiTest do
  use Wallabidi.Integration.SessionCase, async: true

  describe "end_session/2" do
    test "calling end_session on an active session", %{session: session} do
      assert :ok = Wallabidi.end_session(session)
    end

    test "calling end_session on an already closed session", %{session: session} do
      Wallabidi.end_session(session)

      assert :ok = Wallabidi.end_session(session)
    end
  end
end
