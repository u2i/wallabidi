defmodule Wallabidi.Sandbox do
  @moduledoc """
  Runtime hooks for propagating test sandbox access
  (Ecto, Mimic, Mox, Cachex, FunWithFlags) to browser-spawned processes.

  ## Endpoint setup

      # lib/your_app_web/endpoint.ex
      import PhoenixTestOnly
      plug_if_test Phoenix.Ecto.SQL.Sandbox
      plug_if_test Wallabidi.Sandbox.Plug

  ## LiveView setup

      # lib/your_app_web.ex
      def live_view do
        quote do
          use Phoenix.LiveView
          import PhoenixTestOnly
          on_mount_if_test Wallabidi.Sandbox.Hook
        end
      end

  ## Configuration

      # config/test.exs
      config :wallabidi,
        otp_app: :your_app,
        mox_mocks: [MyApp.MockWeather]  # if using Mox

  The `PhoenixTestOnly` macros check module availability at compile time.
  In production (where wallabidi isn't a dep), they emit nothing.
  """
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
            propagate_sandbox(owner, self())

          _ ->
            :ok
        end
      end

      conn
    end

    defp propagate_sandbox(owner, child) do
      allow_mimic(owner, child)
      allow_mox(owner, child)
      propagate_cachex_sandbox(owner)
      propagate_fwf_sandbox(owner)
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

    defp propagate_cachex_sandbox(owner) do
      case :erlang.process_info(owner, :dictionary) do
        {:dictionary, dict} ->
          for {key, value} <- dict, match?({:cachex_sandbox, _}, key) do
            Process.put(key, value)
          end

        _ ->
          :ok
      end
    catch
      _, _ -> :ok
    end

    defp propagate_fwf_sandbox(owner) do
      case :erlang.process_info(owner, :dictionary) do
        {:dictionary, dict} ->
          case List.keyfind(dict, :fwf_sandbox, 0) do
            {:fwf_sandbox, table} -> Process.put(:fwf_sandbox, table)
            _ -> :ok
          end

        _ ->
          :ok
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
           %{owner: owner} <- Phoenix.Ecto.SQL.Sandbox.decode_metadata(ua) do
        # Ecto — set $callers so this process and its sub-processes
        # (e.g. start_async tasks, Cachex Courier workers) can access
        # the test sandbox via the ownership chain. This avoids the
        # deadlock that occurs with allow/3: allow gives this process
        # its own proxy, and when a sub-process inherits that proxy
        # via $callers while this process is blocked, they deadlock
        # on the shared connection.
        callers = Process.get(:"$callers") || []
        unless owner in callers, do: Process.put(:"$callers", [owner | callers])
        # Mocks
        allow_mimic(owner, self())
        allow_mox(owner, self())
        # Cachex sandbox
        propagate_cachex_sandbox(owner)
        # FunWithFlags sandbox
        propagate_fwf_sandbox(owner)
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

    defp propagate_cachex_sandbox(owner) do
      case :erlang.process_info(owner, :dictionary) do
        {:dictionary, dict} ->
          for {key, value} <- dict, match?({:cachex_sandbox, _}, key) do
            Process.put(key, value)
          end

        _ ->
          :ok
      end
    catch
      _, _ -> :ok
    end

    defp propagate_fwf_sandbox(owner) do
      case :erlang.process_info(owner, :dictionary) do
        {:dictionary, dict} ->
          case List.keyfind(dict, :fwf_sandbox, 0) do
            {:fwf_sandbox, table} -> Process.put(:fwf_sandbox, table)
            _ -> :ok
          end

        _ ->
          :ok
      end
    catch
      _, _ -> :ok
    end
  end
end
