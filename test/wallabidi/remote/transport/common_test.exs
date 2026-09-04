defmodule Wallabidi.Remote.Transport.CommonTest do
  use ExUnit.Case, async: true

  alias Wallabidi.Remote.Transport.Common

  defp state(streams \\ %{}), do: %{streams: streams}

  describe "open_stream/3" do
    test "registers a subscriber and monitors it" do
      state = Common.open_stream(state(), "s1", self())

      assert %{subscriber: subscriber, next_seq: 0, pending: %{}} = state.streams["s1"]
      assert subscriber == self()
    end

    test "re-opening an already-open stream replaces the subscriber" do
      other = spawn(fn -> Process.sleep(:infinity) end)

      state =
        state()
        |> Common.open_stream("s1", other)
        |> Common.open_stream("s1", self())

      assert state.streams["s1"].subscriber == self()

      Process.exit(other, :kill)
    end
  end

  describe "close_stream/2" do
    test "drops a known stream" do
      state =
        state()
        |> Common.open_stream("s1", self())
        |> Common.close_stream("s1")

      assert state.streams == %{}
    end

    test "is a no-op for an unknown stream" do
      assert Common.close_stream(state(), "unknown") == state()
    end
  end

  describe "route_stream_chunk/4" do
    test "delivers a single in-order chunk immediately" do
      state = Common.open_stream(state(), "s1", self())
      Common.route_stream_chunk(state, "s1", 0, "hello")

      assert_received {:wallabidi_stream, "s1", 0, "hello"}
    end

    test "delivers chunks in order as gaps fill, buffering out-of-order arrivals" do
      state = Common.open_stream(state(), "s1", self())

      # seq 1 arrives before seq 0 — must be buffered, not delivered.
      state = Common.route_stream_chunk(state, "s1", 1, "b")
      refute_received {:wallabidi_stream, "s1", 1, "b"}
      assert state.streams["s1"].pending == %{1 => "b"}
      assert state.streams["s1"].next_seq == 0

      # seq 0 arrives — both 0 and the buffered 1 should flush in order.
      state = Common.route_stream_chunk(state, "s1", 0, "a")

      assert_received {:wallabidi_stream, "s1", 0, "a"}
      assert_received {:wallabidi_stream, "s1", 1, "b"}
      assert state.streams["s1"].pending == %{}
      assert state.streams["s1"].next_seq == 2
    end

    test "delivers a long out-of-order run correctly once the gap closes" do
      state = Common.open_stream(state(), "s1", self())

      state =
        Enum.reduce([3, 1, 2], state, fn seq, acc ->
          Common.route_stream_chunk(acc, "s1", seq, "chunk#{seq}")
        end)

      refute_received {:wallabidi_stream, "s1", _, _}

      Common.route_stream_chunk(state, "s1", 0, "chunk0")

      for seq <- 0..3 do
        expected = "chunk#{seq}"
        assert_received {:wallabidi_stream, "s1", ^seq, ^expected}
      end
    end

    test "drops a chunk for an unknown or already-closed stream" do
      state = state()
      assert Common.route_stream_chunk(state, "unknown", 0, "x") == state
      refute_received {:wallabidi_stream, _, _, _}
    end
  end

  describe "handle_stream_subscriber_down/2" do
    test "drops every stream owned by the down process, leaves others" do
      other = spawn(fn -> Process.sleep(:infinity) end)
      other_ref = Process.monitor(other)

      state = %{
        streams: %{
          "mine" => %{subscriber: self(), monitor_ref: make_ref(), next_seq: 0, pending: %{}},
          "theirs" => %{subscriber: other, monitor_ref: other_ref, next_seq: 0, pending: %{}}
        }
      }

      state = Common.handle_stream_subscriber_down(state, other_ref)

      assert Map.keys(state.streams) == ["mine"]

      Process.exit(other, :kill)
    end
  end
end
