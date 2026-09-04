defmodule Wallabidi.V2.SessionTest do
  use ExUnit.Case, async: true

  alias Wallabidi.Remote.Transport.Session, as: Session

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

  describe "find_timeout handler" do
    # When the resolve event and the timer fire in close succession,
    # the timer handler must NOT drop the resolved payload — the
    # awaiter still needs to harvest it.
    test "preserves an already-resolved waiter when timer fires" do
      payload = %{"ok" => true, "elements" => []}

      state = %Session{
        find_waiters: %{"q1" => {:resolved, payload}}
      }

      assert {:noreply, new_state} = Session.handle_info({:find_timeout, "q1"}, state)

      assert Map.get(new_state.find_waiters, "q1") == {:resolved, payload}
    end

    test "drops an unknown waiter" do
      state = %Session{find_waiters: %{}}
      assert {:noreply, new_state} = Session.handle_info({:find_timeout, "q1"}, state)
      assert new_state.find_waiters == %{}
    end

    test "drops a pending unblocked waiter" do
      state = %Session{find_waiters: %{"q1" => {:pending, make_ref(), nil}}}
      assert {:noreply, new_state} = Session.handle_info({:find_timeout, "q1"}, state)
      assert new_state.find_waiters == %{}
    end
  end

  describe "streaming" do
    test "open_stream then close_stream round-trips through handle_call" do
      state = %Session{}

      assert {:reply, :ok, state} = Session.handle_call({:open_stream, "s1", self()}, nil, state)
      assert Map.has_key?(state.streams, "s1")

      assert {:reply, :ok, state} = Session.handle_call({:close_stream, "s1"}, nil, state)
      refute Map.has_key?(state.streams, "s1")
    end

    test "owner DOWN still stops the session (unaffected by stream subscriber tracking)" do
      owner_ref = make_ref()
      state = %Session{owner_ref: owner_ref, streams: %{}}

      assert {:stop, :normal, ^state} =
               Session.handle_info({:DOWN, owner_ref, :process, self(), :normal}, state)
    end

    test "a stream subscriber's DOWN drops its stream without stopping the session" do
      {:reply, :ok, state} = Session.handle_call({:open_stream, "s1", self()}, nil, %Session{})

      subscriber_ref = state.streams["s1"].monitor_ref

      assert {:noreply, new_state} =
               Session.handle_info({:DOWN, subscriber_ref, :process, self(), :normal}, state)

      refute Map.has_key?(new_state.streams, "s1")
    end
  end
end
