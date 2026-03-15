defmodule Wallaby.Chrome.BrowserServer do
  @moduledoc false
  # GenServer that launches Chrome directly and exposes a BiDi WebSocket URL.
  # Eliminates the need for chromedriver by connecting to Chrome's built-in
  # WebDriver BiDi endpoint.

  use GenServer
  require Logger

  defstruct [
    :chrome_port,
    :chrome_os_pid,
    :ws_url,
    ready?: false,
    calls_awaiting_readiness: [],
    stderr_buffer: ""
  ]

  @default_startup_timeout :timer.seconds(10)

  def child_spec(args) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, args}}
  end

  def start_link(chrome_path, opts \\ []) do
    {start_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {chrome_path, opts}, start_opts)
  end

  def wait_until_ready(server, timeout \\ 10_000) do
    GenServer.call(server, :wait_until_ready, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  def get_ws_url(server) do
    GenServer.call(server, :get_ws_url)
  end

  def stop(server) do
    GenServer.stop(server, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  # GenServer callbacks

  @impl true
  def init({chrome_path, opts}) do
    startup_timeout = Keyword.get(opts, :startup_timeout, @default_startup_timeout)
    Process.send_after(self(), :ensure_readiness, startup_timeout)

    chrome_args = Keyword.get(opts, :chrome_args, [])
    user_data_dir = create_temp_profile()

    args =
      [
        chrome_path,
        "--remote-debugging-port=0",
        "--user-data-dir=#{user_data_dir}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-networking",
        "--disable-client-side-phishing-detection",
        "--disable-default-apps",
        "--disable-extensions",
        "--disable-hang-monitor",
        "--disable-popup-blocking",
        "--disable-prompt-on-repost",
        "--disable-sync",
        "--disable-translate",
        "--metrics-recording-only",
        "--safebrowsing-disable-auto-update",
        "--enable-features=NetworkService,NetworkServiceInProcess"
        | chrome_args
      ]

    wrapper_script = Path.absname("priv/run_command.sh", Application.app_dir(:wallaby))

    port =
      Port.open(
        {:spawn_executable, to_charlist(wrapper_script)},
        [
          :binary,
          :stream,
          :use_stdio,
          :stderr_to_stdout,
          :exit_status,
          args: args
        ]
      )

    {:ok, %__MODULE__{chrome_port: port}}
  end

  @impl true
  def handle_info(:ensure_readiness, %{ready?: true} = state), do: {:noreply, state}

  def handle_info(:ensure_readiness, %{ready?: false}) do
    raise "Chrome browser not ready after startup timeout — DevTools WebSocket URL not found"
  end

  def handle_info({port, {:data, output}}, %{chrome_port: port} = state) do
    state = process_output(state, output)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{chrome_port: port} = state) do
    {:stop, {:chrome_exited, status}, state}
  end

  @impl true
  def handle_call(:wait_until_ready, _from, %{ready?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:wait_until_ready, from, %{ready?: false} = state) do
    {:noreply, %{state | calls_awaiting_readiness: [from | state.calls_awaiting_readiness]}}
  end

  def handle_call(:get_ws_url, _from, state) do
    {:reply, state.ws_url, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.chrome_os_pid do
      System.cmd("kill", ["-9", to_string(state.chrome_os_pid)])
    end
  end

  # Private

  defp process_output(state, output) do
    buffer = state.stderr_buffer <> output

    cond do
      # Chrome outputs "DevTools listening on ws://..." to stderr
      ws_url = extract_ws_url(buffer) ->
        become_ready(%{state | ws_url: ws_url, stderr_buffer: ""})

      # Wrapper script outputs "PID: <pid>"
      os_pid = extract_os_pid(buffer) ->
        %{state | chrome_os_pid: os_pid, stderr_buffer: buffer}

      true ->
        %{state | stderr_buffer: buffer}
    end
  end

  defp extract_ws_url(output) do
    case Regex.run(~r/DevTools listening on (ws:\/\/\S+)/, output) do
      [_, url] -> url
      nil -> nil
    end
  end

  defp extract_os_pid(output) do
    case Regex.run(~r/PID: (\d+)/, output) do
      [_, pid] -> String.to_integer(pid)
      nil -> nil
    end
  end

  defp become_ready(state) do
    for call <- state.calls_awaiting_readiness do
      GenServer.reply(call, :ok)
    end

    %{state | ready?: true, calls_awaiting_readiness: []}
  end

  defp create_temp_profile do
    dir = Path.join(System.tmp_dir!(), "wallaby_chrome_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
