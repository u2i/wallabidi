defmodule Wallabidi.SessionPoolTest do
  use ExUnit.Case, async: false

  describe "SessionPool" do
    test "starts a pool and checks out/in sessions" do
      {:ok, pool} = Wallabidi.SessionPool.start_link(pool_size: 2)

      session1 = Wallabidi.SessionPool.checkout(pool)
      assert %Wallabidi.Session{} = session1

      session2 = Wallabidi.SessionPool.checkout(pool)
      assert %Wallabidi.Session{} = session2
      assert session1.id != session2.id

      Wallabidi.SessionPool.checkin(pool, session1)
      Wallabidi.SessionPool.checkin(pool, session2)

      # Can checkout again after checkin
      session3 = Wallabidi.SessionPool.checkout(pool)
      assert session3.id in [session1.id, session2.id]

      Wallabidi.SessionPool.checkin(pool, session3)
      GenServer.stop(pool)
    end

    test "start_session uses pool from config" do
      Application.put_env(:wallabidi, :session_pool, pool_size: 1)
      {:ok, _} = Wallabidi.SessionPool.start_link(pool_size: 1)

      {:ok, session} = Wallabidi.start_session()
      assert %Wallabidi.Session{} = session

      Wallabidi.SessionPool.checkin(session)
      GenServer.stop(Wallabidi.SessionPool)
      Application.delete_env(:wallabidi, :session_pool)
    end

    test "checkout accepts metadata and injects it into the session" do
      {:ok, pool} = Wallabidi.SessionPool.start_link(pool_size: 1)

      # Simulate sandbox metadata
      metadata = %{owner: self(), repo: [SomeRepo]}

      session = Wallabidi.SessionPool.checkout(pool, metadata: metadata)
      assert %Wallabidi.Session{} = session

      # The session should have the metadata stored so the Plug can read it
      assert session.metadata == metadata

      Wallabidi.SessionPool.checkin(pool, session)
      GenServer.stop(pool)
    end

    test "checkin navigates to about:blank" do
      {:ok, pool} = Wallabidi.SessionPool.start_link(pool_size: 1)

      session = Wallabidi.SessionPool.checkout(pool)
      Wallabidi.Browser.visit(session, "about:blank")
      Wallabidi.SessionPool.checkin(pool, session)

      # Re-checkout — should be at about:blank
      session2 = Wallabidi.SessionPool.checkout(pool)
      {:ok, url} = session.driver.current_url(session2)
      assert url in ["about:blank", "data:,"]

      Wallabidi.SessionPool.checkin(pool, session2)
      GenServer.stop(pool)
    end
  end
end
