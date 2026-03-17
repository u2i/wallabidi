defmodule Wallabidi.Sandbox do
  @moduledoc """
  Macros and runtime hooks for propagating test sandbox access
  (Ecto, Mimic, Mox) to browser-spawned processes.

  ## Endpoint setup

      # lib/your_app_web/endpoint.ex
      import Wallabidi.Sandbox
      wallabidi_plug()

      socket "/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [:user_agent, session: @session_options]]

  ## LiveView setup

      # lib/your_app_web.ex
      def live_view do
        quote do
          use Phoenix.LiveView
          import Wallabidi.Sandbox
          wallabidi_on_mount()
          # auth hooks after
        end
      end

  ## Configuration

      # config/test.exs
      config :wallabidi,
        otp_app: :your_app,
        sandbox: true,
        mox_mocks: [MyApp.MockWeather]  # if using Mox

      config :your_app, :sandbox, Ecto.Adapters.SQL.Sandbox

  Both macros expand to nothing when `config :wallabidi, :sandbox` is falsy,
  so there is zero overhead in production.
  """

  @doc """
  Adds sandbox plugs to the endpoint. Expands to nothing in production.

  Adds:
  - `Phoenix.Ecto.SQL.Sandbox` (if available)
  - Mimic stub propagation (if Mimic is loaded)
  - Mox stub propagation (if Mox is loaded and mocks configured)
  """
  defmacro wallabidi_plug do
    quote do
      if Application.compile_env(:wallabidi, :sandbox) do
        if Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) do
          plug(Phoenix.Ecto.SQL.Sandbox)
        end

        plug(Wallabidi.Sandbox.Plug)
      end
    end
  end

  @doc """
  Adds sandbox on_mount hooks to a LiveView. Expands to nothing in production.

  Adds:
  - Ecto sandbox access for the WebSocket process
  - Mimic stub propagation (if Mimic is loaded)
  - Mox stub propagation (if Mox is loaded and mocks configured)
  """
  defmacro wallabidi_on_mount do
    quote do
      if Application.compile_env(:wallabidi, :sandbox) do
        on_mount(Wallabidi.Sandbox.Hook)
      end
    end
  end
end

if Code.ensure_loaded?(Plug) do
  defmodule Wallabidi.Sandbox.Plug do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")

      if Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) do
        case Phoenix.Ecto.SQL.Sandbox.decode_metadata(ua) do
          %{owner: owner} ->
            allow_mocks(owner, self())

          _ ->
            :ok
        end
      end

      conn
    end

    defp allow_mocks(owner, child) do
      allow_mimic(owner, child)
      allow_mox(owner, child)
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

if Code.ensure_loaded?(Phoenix.LiveView) and Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) do
  defmodule Wallabidi.Sandbox.Hook do
    @moduledoc false
    import Phoenix.LiveView

    def on_mount(:default, _params, _session, socket) do
      if connected?(socket), do: maybe_allow(socket)
      {:cont, socket}
    end

    defp maybe_allow(socket) do
      with ua when is_binary(ua) <- get_connect_info(socket, :user_agent),
           %{owner: owner} = metadata <- Phoenix.Ecto.SQL.Sandbox.decode_metadata(ua) do
        # Ecto
        Phoenix.Ecto.SQL.Sandbox.allow(metadata, sandbox_module())
        # Mocks
        allow_mimic(owner, self())
        allow_mox(owner, self())
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
