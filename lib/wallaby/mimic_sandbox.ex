if Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) and Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Wallabidi.MimicSandbox do
    @moduledoc """
    Plug + LiveView on_mount that propagates Mimic stubs.

    Auto-discovers all `Mimic.copy`'d modules. Register conditionally:

        # lib/your_app_web/endpoint.ex
        if Application.compile_env(:your_app, :sandbox) do
          plug Wallabidi.MimicSandbox
        end

        # lib/your_app_web.ex
        def live_view do
          quote do
            if Application.compile_env(:your_app, :sandbox) do
              on_mount Wallabidi.MimicSandbox
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
      mimic = Module.concat([Mimic])

      if Code.ensure_loaded?(mimic) do
        for mod <- mimic_modules(), do: mimic.allow(mod, owner, child)
      end
    catch
      _, _ -> :ok
    end

    defp mimic_modules do
      server = Module.concat([Mimic, Server])
      :sys.get_state(server).modules_opts |> Map.keys()
    catch
      _, _ -> []
    end
  end
end
