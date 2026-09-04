defmodule Wallabidi.Remote.Driver.StreamingDispatchTest do
  use ExUnit.Case, async: true

  # Regression coverage for a real bug caught during development: Chrome
  # CDP and Lightpanda share the exact same `wire_protocol` module
  # (`Wallabidi.Remote.CDP.Client`), so gating open_stream/close_stream
  # support on that module (e.g. via `function_exported?/3` in the
  # Orchestrator) can't tell the two drivers apart — Lightpanda would
  # silently attempt the real CDP dispatch and crash its transport actor
  # (a FunctionClauseError in Transport.PerSession.Actor, which never
  # learned about streaming) instead of raising a clean DriverError.
  #
  # The fix: LightpandaCDP and ChromeBiDi both override the Generic
  # delegate directly, so dispatch never reaches Orchestrator /
  # CDP.Client for either. These tests exercise the driver modules'
  # own open_stream/1 clauses with a bare struct — no real browser
  # process involved, so a regression here fails fast without needing
  # the :browser-tagged integration suite.

  alias Wallabidi.Remote.Drivers.{ChromeBiDi, LightpandaCDP}
  alias Wallabidi.Session

  describe "LightpandaCDP" do
    test "open_stream/1 raises Wallabidi.DriverError without touching the transport" do
      assert_raise Wallabidi.DriverError, ~r/open_stream\/1 is not supported/, fn ->
        LightpandaCDP.open_stream(%Session{})
      end
    end

    test "close_stream/2 is a no-op" do
      assert LightpandaCDP.close_stream(%Session{}, "whatever") == :ok
    end
  end

  describe "ChromeBiDi" do
    test "open_stream/1 raises Wallabidi.DriverError without touching the transport" do
      assert_raise Wallabidi.DriverError, ~r/open_stream\/1 is not supported/, fn ->
        ChromeBiDi.open_stream(%Session{})
      end
    end

    test "close_stream/2 is a no-op" do
      assert ChromeBiDi.close_stream(%Session{}, "whatever") == :ok
    end
  end
end
