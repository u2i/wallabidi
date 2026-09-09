defmodule Wallabidi.Remote.Driver.PermissionsDispatchTest do
  use ExUnit.Case, async: true

  # Regression coverage for the same class of bug caught while building
  # open_stream/1: Chrome CDP and Lightpanda share the exact same
  # `wire_protocol` module (`Wallabidi.Remote.CDP.Client`), so a CDP-only
  # capability can't be gated in the Orchestrator via `function_exported?/3`
  # — it can't tell the two drivers apart. LightpandaCDP and ChromeBiDi
  # must both override the Generic delegate directly so dispatch never
  # reaches Orchestrator / CDP.Client for either.

  alias Wallabidi.Remote.Drivers.{ChromeBiDi, LightpandaCDP}
  alias Wallabidi.Session

  describe "LightpandaCDP" do
    test "grant_permissions/2 raises Wallabidi.DriverError without touching the transport" do
      assert_raise Wallabidi.DriverError, ~r/grant_permissions\/2 is not supported/, fn ->
        LightpandaCDP.grant_permissions(%Session{}, [:camera])
      end
    end
  end

  describe "ChromeBiDi" do
    test "grant_permissions/2 raises Wallabidi.DriverError without touching the transport" do
      assert_raise Wallabidi.DriverError, ~r/grant_permissions\/2 is not supported/, fn ->
        ChromeBiDi.grant_permissions(%Session{}, [:camera])
      end
    end
  end
end
