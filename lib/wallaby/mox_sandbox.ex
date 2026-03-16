if Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) and Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Wallabidi.MoxSandbox do
    @moduledoc """
    Plug + LiveView on_mount that propagates Mox stubs.

    Reads mock list from `config :wallabidi, :mox_mocks`. Register conditionally:

        # config/test.exs
        config :wallabidi, mox_mocks: [MyApp.MockWeather, MyApp.MockMailer]

        # lib/your_app_web/endpoint.ex
        if Application.compile_env(:your_app, :sandbox) do
          plug Wallabidi.MoxSandbox
        end

        # lib/your_app_web.ex
        def live_view do
          quote do
            if Application.compile_env(:your_app, :sandbox) do
              on_mount Wallabidi.MoxSandbox
            end
          end
        end
    """

    @behaviour Plug
    import Phoenix.LiveView

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

    def on_mount(:default, _params, _session, socket) do
      if connected?(socket) do
        case decode_owner(socket) do
          {:ok, owner} -> allow_all(owner, self())
          :skip -> :ok
        end
      end

      {:cont, socket}
    end

    defp decode_owner(%Plug.Conn{} = conn) do
      ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")

      case Phoenix.Ecto.SQL.Sandbox.decode_metadata(ua) do
        %{owner: owner} -> {:ok, owner}
        _ -> :skip
      end
    end

    defp decode_owner(socket) do
      with ua when is_binary(ua) <- get_connect_info(socket, :user_agent),
           %{owner: owner} <- Phoenix.Ecto.SQL.Sandbox.decode_metadata(ua) do
        {:ok, owner}
      else
        _ -> :skip
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
