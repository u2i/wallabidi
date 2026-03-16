mimic_available? =
  Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) and Code.ensure_loaded?(Phoenix.LiveView)

if mimic_available? do
  defmodule Wallabidi.MimicSandbox do
    @moduledoc """
    Plug + LiveView on_mount that propagates Mimic stubs to browser processes.

    Automatically discovers all `Mimic.copy`'d modules and calls
    `Mimic.allow` for each when a request or LiveView mount carries
    sandbox metadata.

    ## Setup

        # lib/your_app_web/endpoint.ex
        if Application.compile_env(:your_app, :sandbox, false) do
          plug Phoenix.Ecto.SQL.Sandbox
          plug Wallabidi.MimicSandbox
        end

        # lib/your_app_web.ex
        def live_view do
          quote do
            use Phoenix.LiveView
            on_mount Wallabidi.MimicSandbox
          end
        end

    No-op in production or when Mimic is not loaded.
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
