defmodule Wallabidi.SandboxTest do
  use ExUnit.Case, async: true

  describe "Wallabidi.Sandbox" do
    test "module is defined (Phoenix.Ecto.SQL.Sandbox available)" do
      assert Code.ensure_loaded?(Wallabidi.Sandbox)
    end

    test "implements Plug behaviour" do
      assert function_exported?(Wallabidi.Sandbox, :init, 1)
      assert function_exported?(Wallabidi.Sandbox, :call, 2)
    end

    test "init returns opts unchanged" do
      assert Wallabidi.Sandbox.init([]) == []
      assert Wallabidi.Sandbox.init(foo: :bar) == [foo: :bar]
    end

    test "call passes through conn when no sandbox metadata in user-agent" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.put_req_header("user-agent", "Mozilla/5.0")

      result = Wallabidi.Sandbox.call(conn, [])
      assert result == conn
    end

    test "sandbox_module returns default when no otp_app configured" do
      original = Application.get_env(:wallabidi, :otp_app)
      Application.delete_env(:wallabidi, :otp_app)

      assert Wallabidi.Sandbox.sandbox_module() == Ecto.Adapters.SQL.Sandbox

      if original, do: Application.put_env(:wallabidi, :otp_app, original)
    end
  end
end
