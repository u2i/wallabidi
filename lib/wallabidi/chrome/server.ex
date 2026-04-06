defmodule Wallabidi.Chrome.Server do
  @moduledoc false

  # Manages a Chrome process launched directly (no chromedriver).
  # Chrome is started with --remote-debugging-port=0 and we parse
  # the DevTools WebSocket URL from its stderr output.

  use GenServer

  require Logger

  defstruct [
    :port,
    :os_pid,
    :ws_url,
    ready?: false,
    buffer: "",
    calls_awaiting_readiness: []
  ]

  @startup_timeout 15_000

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    {start_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  @doc "Returns the browser-level DevTools WebSocket URL."
  def ws_url(server) do
    GenServer.call(server, :ws_url, @startup_timeout)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    chrome_path =
      Keyword.get_lazy(opts, :chrome_path, fn ->
        case Wallabidi.Chrome.find_chrome_executable() do
          {:ok, path} -> path
          {:error, err} -> raise err
        end
      end)

    args = chrome_args(opts)

    port =
      Port.open(
        {:spawn_executable, to_charlist(wrapper_script())},
        [
          :binary,
          :stream,
          :use_stdio,
          :stderr_to_stdout,
          :exit_status,
          args: [chrome_path | args]
        ]
      )

    Process.send_after(self(), :startup_timeout, @startup_timeout)
    {:ok, %__MODULE__{port: port}}
  end

  @impl true
  def handle_call(:ws_url, _from, %{ready?: true, ws_url: url} = state) do
    {:reply, url, state}
  end

  def handle_call(:ws_url, from, %{ready?: false} = state) do
    {:noreply, %{state | calls_awaiting_readiness: [from | state.calls_awaiting_readiness]}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = parse_output(state, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Chrome exited with status #{status}")
    {:stop, {:chrome_exit, status}, state}
  end

  def handle_info(:startup_timeout, %{ready?: true} = state), do: {:noreply, state}

  def handle_info(:startup_timeout, %{ready?: false} = state) do
    Logger.error("Chrome did not output DevTools URL within #{@startup_timeout}ms")
    Logger.error("Chrome output so far: #{state.buffer}")
    {:stop, :startup_timeout, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{os_pid: os_pid} = state) do
    if state.port, do: catch_port_close(state.port)

    if os_pid do
      System.cmd("kill", ["-9", to_string(os_pid)])
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Internal ---

  defp parse_output(%{ready?: true} = state, _data), do: state

  defp parse_output(state, data) do
    buffer = state.buffer <> data

    cond do
      is_nil(state.os_pid) && String.contains?(buffer, "PID:") ->
        case Regex.run(~r/PID:\s*(\d+)/, buffer) do
          [_, pid_str] ->
            parse_output(%{state | os_pid: String.to_integer(pid_str), buffer: buffer}, "")

          nil ->
            %{state | buffer: buffer}
        end

      String.contains?(buffer, "DevTools listening on") ->
        case Regex.run(~r{DevTools listening on (ws://\S+)}, buffer) do
          [_, ws_url] ->
            state = %{state | ws_url: ws_url, ready?: true, buffer: ""}

            for caller <- state.calls_awaiting_readiness do
              GenServer.reply(caller, ws_url)
            end

            %{state | calls_awaiting_readiness: []}

          nil ->
            %{state | buffer: buffer}
        end

      true ->
        %{state | buffer: buffer}
    end
  end

  defp chrome_args(opts) do
    base_args = [
      "--remote-debugging-port=0",
      "--no-sandbox",
      "--disable-gpu",
      "--headless=new",
      "--disable-background-networking",
      "--disable-background-timer-throttling",
      "--disable-backgrounding-occluded-windows",
      "--disable-renderer-backgrounding",
      "--disable-ipc-flooding-protection",
      "--disable-hang-monitor",
      "--disable-default-apps",
      "--disable-extensions",
      "--disable-sync",
      "--disable-translate",
      "--disable-dev-shm-usage",
      "--no-first-run",
      "--disable-popup-blocking",
      "window-size=1280,800"
    ]

    extra_args = Keyword.get(opts, :args, [])
    base_args ++ extra_args
  end

  defp wrapper_script do
    Path.absname("priv/run_command.sh", Application.app_dir(:wallabidi))
  end

  defp catch_port_close(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end
end
