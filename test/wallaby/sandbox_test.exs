defmodule Wallabidi.SandboxTest do
  use ExUnit.Case, async: true

  describe "Wallabidi.Sandbox.Hook" do
    test "module is defined" do
      assert Code.ensure_loaded?(Wallabidi.Sandbox.Hook)
    end

    test "exports on_mount/4" do
      funs = Wallabidi.Sandbox.Hook.__info__(:functions)
      assert {:on_mount, 4} in funs
    end
  end

  describe "Wallabidi.Sandbox.Plug" do
    test "module is defined" do
      assert Code.ensure_loaded?(Wallabidi.Sandbox.Plug)
    end

    test "implements Plug" do
      funs = Wallabidi.Sandbox.Plug.__info__(:functions)
      assert {:init, 1} in funs
      assert {:call, 2} in funs
    end

    test "passes through conn when no metadata" do
      conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("user-agent", "Mozilla/5.0")
      result = Wallabidi.Sandbox.Plug.call(conn, [])
      assert result == conn
    end
  end

  describe "Wallabidi.Sandbox macros" do
    test "wallabidi_plug and wallabidi_on_mount are defined" do
      macros = Wallabidi.Sandbox.__info__(:macros)
      assert {:wallabidi_plug, 0} in macros
      assert {:wallabidi_on_mount, 0} in macros
    end
  end
end
