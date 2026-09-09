defmodule Wallabidi.Remote.CDP.ClientTest do
  use ExUnit.Case, async: true

  alias Wallabidi.Remote.CDP.Client, as: CDPClient
  alias Wallabidi.Session

  describe "grant_permissions/2" do
    test "raises ArgumentError for an unknown permission before touching the transport" do
      assert_raise ArgumentError, ~r/unknown permission :geolocation/, fn ->
        CDPClient.grant_permissions(%Session{}, [:geolocation])
      end
    end
  end
end
