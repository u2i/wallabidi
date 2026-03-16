if Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) do
  defmodule Wallabidi.Sandbox do
    @moduledoc """
    Plug that propagates test sandbox access to HTTP request processes.

    Add to your endpoint before other plugs:

        # lib/my_app_web/endpoint.ex
        if Application.compile_env(:my_app, :sandbox, false) do
          plug Wallabidi.Sandbox
        end

    ## Configuration

        # config/test.exs
        config :wallabidi, otp_app: :your_app
        config :your_app, :sandbox, Ecto.Adapters.SQL.Sandbox

    ## How sandbox propagation works

    Browser tests need every process that touches the database to share
    the test process's sandbox checkout:

        test process (owns checkout)
          → HTTP request (allowed by this plug)
            → LiveView mount (allowed by Wallabidi.LiveSandbox)
              → Task / assign_async (allowed via $callers)
              → Cachex 4+ workers (allowed via $callers)

    Processes spawned via `Task` or libraries that set `$callers`
    (including Cachex 4+) automatically inherit sandbox access.

    ## Custom sandbox (Mimic propagation)

        config :your_app, :sandbox, MyApp.Sandbox

        defmodule MyApp.Sandbox do
          def allow(repo, owner_pid, child_pid) do
            Ecto.Adapters.SQL.Sandbox.allow(repo, owner_pid, child_pid)
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
          Phoenix.Ecto.SQL.Sandbox.allow(metadata, sandbox_module())
          conn
      end
    end

    @doc false
    def sandbox_module do
      otp_app = Application.get_env(:wallabidi, :otp_app)

      if otp_app do
        Application.get_env(otp_app, :sandbox, Ecto.Adapters.SQL.Sandbox)
      else
        Ecto.Adapters.SQL.Sandbox
      end
    end
  end
end
