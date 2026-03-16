if Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) do
  defmodule Wallabidi.Sandbox do
    @moduledoc """
    Plug that propagates test sandbox access to HTTP request processes.

    Drop-in replacement for `Phoenix.Ecto.SQL.Sandbox` — add to your
    endpoint before other plugs:

        # lib/my_app_web/endpoint.ex
        if Application.compile_env(:my_app, :sandbox, false) do
          plug Wallabidi.Sandbox
        end

    ## How sandbox propagation works

    Browser tests need every process that touches the database to share
    the same sandbox checkout. The chain looks like:

        test process (owns checkout)
          → HTTP request (allowed by this plug)
            → LiveView mount (allowed by Wallabidi.LiveSandbox)
              → Task (allowed via $callers)
              → spawn_link worker (NOT allowed — no $callers)

    Processes spawned via `Task` automatically inherit sandbox access
    through the `$callers` process dictionary. But `spawn_link` doesn't
    set `$callers`, so libraries like Cachex that use `spawn_link`
    internally will fail with sandbox errors.

    ## Handling spawn_link workers (Cachex, etc.)

    For libraries that spawn workers via `spawn_link`, use shared
    sandbox mode in your custom sandbox module:

        defmodule MyApp.Sandbox do
          def allow(repo, owner_pid, child_pid) do
            # Shared mode lets ANY process on this node access the checkout.
            # Safe for browser tests because each test has its own transaction.
            Ecto.Adapters.SQL.Sandbox.allow(repo, owner_pid, child_pid)
          end
        end

    If you need Cachex specifically, the simplest approach is to configure
    Ecto sandbox in shared mode for the repos Cachex accesses:

        # test/test_helper.exs
        Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, :auto)

    Or wrap Cachex calls to ensure sandbox access:

        # lib/my_app/cache.ex
        defmodule MyApp.Cache do
          def fetch(cache, key, fallback) do
            if sandbox_metadata = Process.get(:wallabidi_sandbox_metadata) do
              Cachex.fetch(cache, key, fn key ->
                # Re-allow this spawned worker process
                Phoenix.Ecto.SQL.Sandbox.allow(sandbox_metadata, sandbox_module())
                fallback.(key)
              end)
            else
              Cachex.fetch(cache, key, fallback)
            end
          end
        end

    ## Custom sandbox (Mimic propagation)

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
          allow_sandbox(metadata)
          # Store metadata in process dictionary so downstream code
          # (e.g. Cachex wrappers) can re-allow spawned workers
          Process.put(:wallabidi_sandbox_metadata, metadata)
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

    defp allow_sandbox(metadata) do
      Phoenix.Ecto.SQL.Sandbox.allow(metadata, sandbox_module())
    end
  end
end
