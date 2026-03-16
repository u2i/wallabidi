if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Wallabidi.LiveSandbox do
    @moduledoc """
    LiveView on_mount hook that propagates test sandbox access.

    Safe to register unconditionally — does nothing when no sandbox
    metadata is present in the user-agent (i.e. in production).

    Must be registered **before** any on_mount hooks that access the
    database (e.g. authentication hooks), because it needs to allow
    sandbox access before those hooks run queries.

    ## Usage

        def live_view do
          quote do
            use Phoenix.LiveView
            on_mount Wallabidi.LiveSandbox  # first
            on_mount MyAppWeb.Auth          # then auth
          end
        end

    Or in your router:

        live_session :default, on_mount: [Wallabidi.LiveSandbox, MyAuth] do
          # ...
        end
    """

    import Phoenix.LiveView
    import Phoenix.Component

    def on_mount(:default, _params, _session, socket) do
      maybe_allow_sandbox(socket)
      {:cont, socket}
    end

    defp maybe_allow_sandbox(socket) do
      if connected?(socket) do
        socket
        |> get_connect_info(:user_agent)
        |> decode_and_allow()
      end
    end

    defp decode_and_allow(nil), do: :ok

    defp decode_and_allow(user_agent) do
      case Phoenix.Ecto.SQL.Sandbox.decode_metadata(user_agent) do
        nil -> :ok
        metadata -> Phoenix.Ecto.SQL.Sandbox.allow(metadata, Wallabidi.Sandbox.sandbox_module())
      end
    end
  end
end
