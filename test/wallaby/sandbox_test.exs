defmodule Wallabidi.SandboxTest do
  use ExUnit.Case, async: true

  describe "Wallabidi.EctoSandbox" do
    test "module is defined" do
      assert Code.ensure_loaded?(Wallabidi.EctoSandbox)
    end

    test "exports on_mount/4" do
      funs = Wallabidi.EctoSandbox.__info__(:functions)
      assert {:on_mount, 4} in funs
    end
  end

  describe "Wallabidi.MimicSandbox" do
    test "module is defined" do
      assert Code.ensure_loaded?(Wallabidi.MimicSandbox)
    end

    test "implements Plug and on_mount" do
      funs = Wallabidi.MimicSandbox.__info__(:functions)
      assert {:init, 1} in funs
      assert {:call, 2} in funs
      assert {:on_mount, 4} in funs
    end
  end

  describe "Wallabidi.MoxSandbox" do
    test "module is defined" do
      assert Code.ensure_loaded?(Wallabidi.MoxSandbox)
    end

    test "implements Plug and on_mount" do
      funs = Wallabidi.MoxSandbox.__info__(:functions)
      assert {:init, 1} in funs
      assert {:call, 2} in funs
      assert {:on_mount, 4} in funs
    end
  end
end
