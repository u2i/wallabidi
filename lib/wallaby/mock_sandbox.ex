if Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) do
  defmodule Wallabidi.MockSandbox do
    @moduledoc """
    Plug that propagates Mimic and Mox stubs to HTTP request processes.

    Sits alongside `Phoenix.Ecto.SQL.Sandbox` in your endpoint:

        if Application.compile_env(:your_app, :sandbox, false) do
          plug Phoenix.Ecto.SQL.Sandbox   # Ecto
          plug Wallabidi.MockSandbox      # Mimic + Mox
        end

    Automatically discovers and allows:
    - All `Mimic.copy`'d modules
    - All modules listed in `config :wallabidi, :mox_mocks`

    No-op in production (when no sandbox metadata in user-agent).
    """

    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      user_agent =
        conn
        |> Plug.Conn.get_req_header("user-agent")
        |> List.first("")

      case Phoenix.Ecto.SQL.Sandbox.decode_metadata(user_agent) do
        %{owner: owner} ->
          child = self()
          allow_mimic(owner, child)
          allow_mox(owner, child)
          conn

        _ ->
          conn
      end
    end

    defp allow_mimic(owner, child) do
      mimic = Module.concat([Mimic])

      if Code.ensure_loaded?(mimic) do
        server = Module.concat([Mimic, Server])

        for mod <- mimic_modules(server) do
          mimic.allow(mod, owner, child)
        end
      end
    catch
      _, _ -> :ok
    end

    defp mimic_modules(server) do
      :sys.get_state(server).modules_opts |> Map.keys()
    catch
      _, _ -> []
    end

    defp allow_mox(owner, child) do
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
