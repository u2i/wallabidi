defmodule Wallabidi.SandboxTest do
  use ExUnit.Case, async: true

  describe "Wallabidi.LiveSandbox" do
    test "module is defined (Phoenix.LiveView available)" do
      assert Code.ensure_loaded?(Wallabidi.LiveSandbox)
    end

    test "exports on_mount/4" do
      funs = Wallabidi.LiveSandbox.__info__(:functions)
      assert {:on_mount, 4} in funs
    end
  end
end
