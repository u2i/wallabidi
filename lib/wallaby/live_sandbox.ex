if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Wallabidi.LiveSandbox do
    @moduledoc """
    LiveView on_mount hook that propagates test sandbox access to
    WebSocket-connected LiveView processes.

    Safe to register unconditionally — does nothing when no sandbox
    metadata is present in the user-agent (i.e. in production).

    Must be registered **before** any on_mount hooks that access the
    database (e.g. authentication hooks), because it needs to grant
    sandbox access before those hooks run queries.

    ## Usage

        # In your live_view macro (lib/my_app_web.ex)
        def live_view do
          quote do
            use Phoenix.LiveView
            on_mount Wallabidi.LiveSandbox  # first
            on_mount MyAppWeb.Auth          # then auth
          end
        end

    Or in your router:

        live_session :default, on_mount: [Wallabidi.LiveSandbox, MyAuth] do
          # ...
        end

    ## How it works

    The HTTP plug (`Phoenix.Ecto.SQL.Sandbox`) handles the initial page
    load. But LiveView upgrades to a WebSocket — a new process that
    doesn't inherit the HTTP request's sandbox access.

    This hook decodes the sandbox metadata from the WebSocket's
    user-agent header and calls `allow` so the LiveView process (and
    its `start_async` / `assign_async` tasks via `$callers`) can
    access the test's database checkout.

    ## Configuration

    Uses the same sandbox module as `Phoenix.Ecto.SQL.Sandbox`:

        # config/test.exs
        config :wallabidi, otp_app: :your_app
        config :your_app, :sandbox, MyApp.Sandbox
    """

    import Phoenix.LiveView

    def on_mount(:default, _params, _session, socket) do
      maybe_allow_sandbox(socket)
      {:cont, socket}
    end

    defp maybe_allow_sandbox(socket) do
      if connected?(socket) do
        socket
        |> get_connect_info(:user_agent)
        |> decode_and_allow()
      end
    end

    defp decode_and_allow(nil), do: :ok

    defp decode_and_allow(user_agent) do
      case Phoenix.Ecto.SQL.Sandbox.decode_metadata(user_agent) do
        nil ->
          :ok

        metadata ->
          Phoenix.Ecto.SQL.Sandbox.allow(metadata, sandbox_module())
          allow_mocks(metadata)
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

    defp allow_mocks(%{owner: owner}) do
      child = self()
      allow_mimic(owner, child)
    end

    defp allow_mocks(_), do: :ok

    # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
    defp allow_mimic(owner, child) do
      mimic = Module.concat([Mimic])

      if Code.ensure_loaded?(mimic) do
        for mod <- mimic_modules() do
          # Dynamic call — Mimic is an optional dep
          mimic.allow(mod, owner, child)
        end
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
