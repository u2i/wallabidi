defmodule Wallabidi.Driver.UtilsTest do
  use ExUnit.Case, async: true

  alias Wallabidi.Driver.Utils

  describe "find_available_port/0" do
    test "returns an unused port" do
      port = Utils.find_available_port()

      assert port >= 0
      assert port <= 65535
    end
  end
end
