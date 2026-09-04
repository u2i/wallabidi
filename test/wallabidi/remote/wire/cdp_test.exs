defmodule Wallabidi.Remote.Wire.CDPTest do
  use ExUnit.Case, async: true

  alias Wallabidi.Remote.Transport.Common
  alias Wallabidi.Remote.Wire.CDP, as: Wire

  defp state, do: %{streams: %{}}

  describe "Runtime.bindingCalled routing" do
    test "__wallabidi_stream_raw payload decodes and delivers a chunk in order" do
      state = Common.open_stream(state(), "s1", self())

      payload = Jason.encode!(%{"streamId" => "s1", "seq" => 0, "data" => Base.encode64("hi")})

      event = %{"params" => %{"name" => "__wallabidi_stream_raw", "payload" => payload}}

      Wire.handle_event(state, "Runtime.bindingCalled", event)

      assert_received {:wallabidi_stream, "s1", 0, "hi"}
    end

    test "a malformed payload is dropped without raising" do
      state = Common.open_stream(state(), "s1", self())
      event = %{"params" => %{"name" => "__wallabidi_stream_raw", "payload" => "not json"}}

      assert Wire.handle_event(state, "Runtime.bindingCalled", event) == state
      refute_received {:wallabidi_stream, _, _, _}
    end

    test "a payload with non-base64 data is dropped without raising" do
      state = Common.open_stream(state(), "s1", self())

      payload = Jason.encode!(%{"streamId" => "s1", "seq" => 0, "data" => "not-valid-base64!!"})

      event = %{"params" => %{"name" => "__wallabidi_stream_raw", "payload" => payload}}

      assert Wire.handle_event(state, "Runtime.bindingCalled", event) == state
      refute_received {:wallabidi_stream, _, _, _}
    end

    test "an unrelated binding name is ignored" do
      state = state()
      event = %{"params" => %{"name" => "some_other_binding", "payload" => "{}"}}

      assert Wire.handle_event(state, "Runtime.bindingCalled", event) == state
    end
  end
end
