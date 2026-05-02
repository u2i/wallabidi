defmodule Wallabidi.Chrome.BidiServer do
  @moduledoc false

  # Manages a chromium-bidi Node process that exposes a BiDi WebSocket
  # server. Replaces chromedriver in the Wallabidi.Chrome (BiDi) driver
  # path.
  #
  # The Node runner lives at `priv/bidi-server/run.mjs` and depends on
  # the `chromium-bidi` npm package (installed via `npm install` in that
  # directory). It speaks BiDi natively to a Chrome instance via CDP —
  # the same architecture chromedriver uses internally, but without
  # chromedriver's single-threaded Java event loop in the way.
  #
  # Lifecycle:
  #   - Spawns Node via `priv/run_command.sh` so the OS-level process
  #     dies when the BEAM port closes.
  #   - Reads stderr until "ready on port=NNNN" appears; only then is
  #     the WebSocket URL handed out to callers.
  #   - On terminate, sends SIGKILL via the captured os_pid.

  use GenServer

  require Logger

  defstruct [
    :port,
    :os_pid,
    :tcp_port,
    ready?: false,
    buffer: "",
    calls_awaiting_readiness: []
  ]

  @startup_timeout 30_000

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    {start_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  @doc """
  Returns the BiDi WebSocket URL once the server is listening.
  Blocks until ready (up to @startup_timeout).
  """
  @spec ws_url(GenServer.server()) :: String.t()
  def ws_url(server) do
    GenServer.call(server, :ws_url, @startup_timeout + 1_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    chrome_path =
      Keyword.get_lazy(opts, :chrome_path, fn ->
        Wallabidi.BrowserPaths.chrome_path!()
      end)

    tcp_port = Keyword.get(opts, :tcp_port, find_available_port())

    port =
      Port.open(
        {:spawn_executable, to_charlist(wrapper_script())},
        [
          :binary,
          :stream,
          :use_stdio,
          :stderr_to_stdout,
          :exit_status,
          args: ["node", run_script()],
          env: env(chrome_path, tcp_port)
        ]
      )

    Process.send_after(self(), :startup_timeout, @startup_timeout)
    {:ok, %__MODULE__{port: port, tcp_port: tcp_port}}
  end

  @impl true
  def handle_call(:ws_url, _from, %{ready?: true, tcp_port: p} = state) do
    {:reply, "ws://localhost:#{p}/session", state}
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
    Logger.error("Wallabidi BiDi server exited with status #{status}; buffer: #{state.buffer}")
    {:stop, {:bidi_server_exit, status}, state}
  end

  def handle_info(:startup_timeout, %{ready?: true} = state), do: {:noreply, state}

  def handle_info(:startup_timeout, %{ready?: false} = state) do
    Logger.error("Wallabidi BiDi server didn't become ready within #{@startup_timeout}ms")
    Logger.error("Output so far: #{state.buffer}")
    {:stop, :startup_timeout, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{os_pid: os_pid} = state) do
    if state.port, do: catch_port_close(state.port)
    if os_pid, do: System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Internal ---

  defp parse_output(%{ready?: true} = state, _data), do: state

  defp parse_output(state, data) do
    buffer = state.buffer <> data

    state =
      case Regex.run(~r/PID:\s*(\d+)/, buffer) do
        [_, pid_str] when is_nil(state.os_pid) ->
          %{state | os_pid: String.to_integer(pid_str)}

        _ ->
          state
      end

    if String.contains?(buffer, "wallabidi-bidi-server: ready on port=") do
      case Regex.run(~r/wallabidi-bidi-server: ready on port=(\d+)/, buffer) do
        [_, p] ->
          tcp_port = String.to_integer(p)
          state = %{state | tcp_port: tcp_port, ready?: true, buffer: ""}

          for caller <- state.calls_awaiting_readiness do
            GenServer.reply(caller, "ws://localhost:#{tcp_port}/session")
          end

          %{state | calls_awaiting_readiness: []}

        nil ->
          %{state | buffer: buffer}
      end
    else
      %{state | buffer: buffer}
    end
  end

  defp env(chrome_path, tcp_port) do
    [
      {~c"BROWSER_BIN", to_charlist(chrome_path)},
      {~c"PORT", to_charlist(Integer.to_string(tcp_port))},
      {~c"HEADLESS", ~c"true"},
      {~c"PATH", to_charlist(System.get_env("PATH") || "/usr/bin:/bin")}
    ]
  end

  defp wrapper_script do
    Path.absname("priv/run_command.sh", Application.app_dir(:wallabidi))
  end

  defp run_script do
    Path.absname("priv/bidi-server/run.mjs", Application.app_dir(:wallabidi))
  end

  defp find_available_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp catch_port_close(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end
end
