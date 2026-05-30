defmodule Wallabidi.BrowserPathsTest do
  use ExUnit.Case, async: false

  alias Wallabidi.BrowserPaths

  @env "WALLABIDI_LIGHTPANDA_PATH"

  setup do
    original = System.get_env(@env)

    on_exit(fn ->
      if original, do: System.put_env(@env, original), else: System.delete_env(@env)
    end)

    :ok
  end

  describe "lightpanda/0" do
    test "resolves WALLABIDI_LIGHTPANDA_PATH when the file exists" do
      bin = Path.join(System.tmp_dir!(), "lp-#{System.unique_integer([:positive])}")
      File.write!(bin, "")
      on_exit(fn -> File.rm_rf!(bin) end)

      System.put_env(@env, bin)

      assert BrowserPaths.lightpanda() == {:path, bin}
      assert BrowserPaths.lightpanda_path() == {:ok, bin}
    end

    test "a missing WALLABIDI_LIGHTPANDA_PATH file does not resolve to that path" do
      ghost = Path.join(System.tmp_dir!(), "does-not-exist-#{System.unique_integer([:positive])}")
      System.put_env(@env, ghost)

      # The env var points nowhere, so resolution must not return it. It
      # may still resolve via the .browsers/PATHS LIGHTPANDA= line (if one
      # is present in this working tree), but never the ghost path.
      refute BrowserPaths.lightpanda() == {:path, ghost}
    end

    test "an empty WALLABIDI_LIGHTPANDA_PATH is treated as unset" do
      System.put_env(@env, "")
      # Empty string must not resolve as a path.
      refute match?({:path, ""}, BrowserPaths.lightpanda())
    end
  end

  describe "lightpanda_install_dir/0" do
    test "is version-stamped under .browsers/lightpanda, mirroring Chrome's layout" do
      dir = BrowserPaths.lightpanda_install_dir()

      # The lightpanda dep exposes target/0 + release/0, so this resolves.
      assert is_binary(dir)
      assert String.starts_with?(dir, Path.join(".browsers", "lightpanda"))
      assert dir == Path.join([".browsers", "lightpanda", "#{Lightpanda.target()}-#{Lightpanda.release()}"])
    end
  end
end
