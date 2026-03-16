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

    In your LiveView macro:

        def live_view do
          quote do
            use Phoenix.LiveView
            on_mount Wallabidi.LiveSandbox
            # auth hooks go after
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
        nil ->
          :ok

        metadata ->
          allow_sandbox(metadata)
          # Store metadata so downstream code (e.g. Cachex wrappers)
          # can re-allow spawned workers
          Process.put(:wallabidi_sandbox_metadata, metadata)
      end
    end

    defp allow_sandbox(metadata) do
      otp_app = Application.get_env(:wallabidi, :otp_app)

      sandbox =
        if otp_app do
          Application.get_env(otp_app, :sandbox, Ecto.Adapters.SQL.Sandbox)
        else
          Ecto.Adapters.SQL.Sandbox
        end

      Phoenix.Ecto.SQL.Sandbox.allow(metadata, sandbox)
    end
  end
end
