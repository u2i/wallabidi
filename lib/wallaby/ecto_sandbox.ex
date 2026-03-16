ecto_available? =
  Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) and Code.ensure_loaded?(Phoenix.LiveView)

if ecto_available? do
  defmodule Wallabidi.EctoSandbox do
    @moduledoc """
    LiveView on_mount that propagates Ecto sandbox access to WebSocket processes.

    The `Phoenix.Ecto.SQL.Sandbox` plug handles HTTP requests, but
    LiveView upgrades to a WebSocket — a new process that needs its
    own sandbox access. This hook handles that.

    ## Setup

        # lib/your_app_web.ex
        def live_view do
          quote do
            use Phoenix.LiveView
            on_mount Wallabidi.EctoSandbox
          end
        end

    No-op in production (when no sandbox metadata in user-agent).

    ## Configuration

        # config/test.exs
        config :wallabidi, otp_app: :your_app
        config :your_app, :sandbox, Ecto.Adapters.SQL.Sandbox
    """

    import Phoenix.LiveView

    def on_mount(:default, _params, _session, socket) do
      if connected?(socket), do: maybe_allow(socket)
      {:cont, socket}
    end

    defp maybe_allow(socket) do
      with ua when is_binary(ua) <- get_connect_info(socket, :user_agent),
           %{} = metadata when map_size(metadata) > 0 <-
             Phoenix.Ecto.SQL.Sandbox.decode_metadata(ua) do
        Phoenix.Ecto.SQL.Sandbox.allow(metadata, sandbox_module())
      end
    end

    defp sandbox_module do
      otp_app = Application.get_env(:wallabidi, :otp_app)

      if otp_app do
        Application.get_env(otp_app, :sandbox, Ecto.Adapters.SQL.Sandbox)
      else
        Ecto.Adapters.SQL.Sandbox
      end
    end
  end
end
