mox_available? =
  Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) and Code.ensure_loaded?(Phoenix.LiveView)

if mox_available? do
  defmodule Wallabidi.MoxSandbox do
    @moduledoc """
    Plug + LiveView on_mount that propagates Mox stubs to browser processes.

    Allows all mock modules listed in `config :wallabidi, :mox_mocks`
    when a request or LiveView mount carries sandbox metadata.

    ## Setup

        # config/test.exs
        config :wallabidi, mox_mocks: [MyApp.MockWeather, MyApp.MockMailer]

        # lib/your_app_web/endpoint.ex
        if Application.compile_env(:your_app, :sandbox, false) do
          plug Phoenix.Ecto.SQL.Sandbox
          plug Wallabidi.MoxSandbox
        end

        # lib/your_app_web.ex
        def live_view do
          quote do
            use Phoenix.LiveView
            on_mount Wallabidi.MoxSandbox
          end
        end

    No-op in production or when Mox is not loaded.
    """

    @behaviour Plug
    import Phoenix.LiveView

    # -- Plug callbacks --

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      case decode_owner(conn) do
        {:ok, owner} -> allow_all(owner, self())
        :skip -> :ok
      end

      conn
    end

    # -- LiveView on_mount --

    def on_mount(:default, _params, _session, socket) do
      if connected?(socket) do
        case decode_owner(socket) do
          {:ok, owner} -> allow_all(owner, self())
          :skip -> :ok
        end
      end

      {:cont, socket}
    end

    # -- Private --

    defp decode_owner(%Plug.Conn{} = conn) do
      ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")

      case Phoenix.Ecto.SQL.Sandbox.decode_metadata(ua) do
        %{owner: owner} -> {:ok, owner}
        _ -> :skip
      end
    end

    defp decode_owner(socket) do
      case get_connect_info(socket, :user_agent) do
        nil ->
          :skip

        ua ->
          case Phoenix.Ecto.SQL.Sandbox.decode_metadata(ua) do
            %{owner: owner} -> {:ok, owner}
            _ -> :skip
          end
      end
    end

    defp allow_all(owner, child) do
      mox = Module.concat([Mox])

      if Code.ensure_loaded?(mox) do
        for mod <- Application.get_env(:wallabidi, :mox_mocks, []) do
          mox.allow(mod, owner, child)
        end
      end
    catch
      _, _ -> :ok
    end
  end
end
