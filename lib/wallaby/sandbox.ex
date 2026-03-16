if Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) do
  defmodule Wallabidi.Sandbox do
    @moduledoc """
    Plug that propagates test sandbox access to HTTP request processes.

    Drop-in replacement for `Phoenix.Ecto.SQL.Sandbox` — add to your
    endpoint before other plugs:

        # lib/my_app_web/endpoint.ex
        if Application.compile_env(:my_app, :sandbox) do
          plug Wallabidi.Sandbox
        end

    Configure the sandbox module in test config:

        # config/test.exs
        config :my_app, :sandbox, Ecto.Adapters.SQL.Sandbox

    For custom sandbox modules (e.g. to also propagate Mimic stubs):

        config :my_app, :sandbox, MyApp.Sandbox

    Where:

        defmodule MyApp.Sandbox do
          def allow(repo, owner_pid, child_pid) do
            Ecto.Adapters.SQL.Sandbox.allow(repo, owner_pid, child_pid)
            # Safe Mimic propagation — skip if owner is in global mode
            try do
              Mimic.allow(MyMock, owner_pid, child_pid)
            catch
              :error, _ -> :ok
            end
          end
        end
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
        nil ->
          conn

        metadata ->
          allow_sandbox(metadata)
          conn
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
