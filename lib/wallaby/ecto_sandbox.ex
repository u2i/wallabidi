if Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) and Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Wallabidi.EctoSandbox do
    @moduledoc """
    Plug + LiveView on_mount that propagates Ecto sandbox access.

    Register conditionally so it's never loaded in production:

        # lib/your_app_web/endpoint.ex
        if Application.compile_env(:your_app, :sandbox) do
          plug Phoenix.Ecto.SQL.Sandbox
        end

        # lib/your_app_web.ex
        def live_view do
          quote do
            use Phoenix.LiveView
            if Application.compile_env(:your_app, :sandbox) do
              on_mount Wallabidi.EctoSandbox
            end
          end
        end
    """

    @behaviour Plug
    import Phoenix.LiveView

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts), do: conn

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
