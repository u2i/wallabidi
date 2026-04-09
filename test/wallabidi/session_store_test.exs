defmodule Wallabidi.SessionStoreTest do
  @moduledoc false
  use ExUnit.Case
  alias Wallabidi.SessionStore
  alias Wallabidi.Session

  setup do
    session_store = start_supervised!({SessionStore, [ets_name: :test_table]})
    [session_store: session_store, table: :sys.get_state(session_store).ets_table]
  end

  describe "register/3" do
    test "adds session to the store", %{session_store: session_store, table: table} do
      assert [] == SessionStore.list_sessions_for(name: table)
      session = %Session{id: "foo"}
      :ok = SessionStore.register(session_store, session, self())

      assert [_] = SessionStore.list_sessions_for(name: table)
    end

    test "adds multiple sessions to store", %{session_store: session_store, table: table} do
      assert [] == SessionStore.list_sessions_for(name: table)
      sessions = [%Session{id: "foo"}, %Session{id: "bar"}]

      for session <- sessions do
        :ok = SessionStore.register(session_store, session, self())
      end

      store = SessionStore.list_sessions_for(name: table)

      for session <- sessions do
        assert Enum.member?(store, session)
      end
    end
  end

  describe "unregister/2" do
    test "removes session from list of active sessions", %{
      session_store: session_store,
      table: table
    } do
      session = %Session{id: "foo"}
      :ok = SessionStore.register(session_store, session, self())
      :ok = SessionStore.unregister(session_store, session)

      assert [] == SessionStore.list_sessions_for(name: table)
    end

    test "removes a single session from the store", %{
      session_store: session_store,
      table: table
    } do
      assert [] == SessionStore.list_sessions_for(name: table)
      first = %Session{id: "foo"}
      second = %Session{id: "bar"}
      third = %Session{id: "baz"}

      for session <- [first, second, third] do
        :ok = SessionStore.register(session_store, session, self())
      end

      :ok = SessionStore.unregister(session_store, second)

      store = SessionStore.list_sessions_for(name: table)

      assert Enum.member?(store, first)
      refute Enum.member?(store, second)
      assert Enum.member?(store, third)
    end
  end

  describe "list_sessions_for/1" do
    test "scoped to owner pid", %{session_store: session_store, table: table} do
      me = self()
      other = spawn(fn -> receive do: (_ -> :ok) end)

      :ok = SessionStore.register(session_store, %Session{id: "mine"}, me)
      :ok = SessionStore.register(session_store, %Session{id: "theirs"}, other)

      my_sessions = SessionStore.list_sessions_for(name: table, owner_pid: me)
      assert length(my_sessions) == 1
      assert hd(my_sessions).id == "mine"

      their_sessions = SessionStore.list_sessions_for(name: table, owner_pid: other)
      assert length(their_sessions) == 1
      assert hd(their_sessions).id == "theirs"
    end
  end
end
