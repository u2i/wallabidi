defmodule Wallabidi.Chrome.Docker do
  @moduledoc false
  # Manages a Docker container running ChromeDriver + Chrome.
  # Used as a fallback when no local chromedriver is installed
  # and no remote_url is configured.

  require Logger

  @container_name "wallabidi-chrome"
  @image "erseco/alpine-chromedriver:latest"
  @container_port 9515
  @startup_timeout 30_000

  def start do
    if container_running?() do
      Logger.info("Wallabidi: reusing existing Docker container #{@container_name}")
      {:ok, container_url()}
    else
      stop()

      Logger.info("Wallabidi: starting Chrome via Docker (#{@image})")

      port = find_available_port()

      with :ok <- run_container(port),
           url = "http://localhost:#{port}/",
           :ok <- wait_for_ready(url, @startup_timeout) do
        Application.put_env(:wallabidi, :chromedriver, remote_url: url)
        {:ok, url}
      else
        {:error, :timeout} ->
          stop()
          {:error, :docker_startup_timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def stop do
    System.cmd("docker", ["rm", "-f", @container_name], stderr_to_stdout: true)
    :ok
  end

  def available? do
    case System.cmd("docker", ["info"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp container_running? do
    case System.cmd("docker", ["inspect", "-f", "{{.State.Running}}", @container_name],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  defp container_url do
    case System.cmd(
           "docker",
           ["port", @container_name, to_string(@container_port)],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        port =
          output
          |> String.trim()
          |> String.split(":")
          |> List.last()

        url = "http://localhost:#{port}/"
        Application.put_env(:wallabidi, :chromedriver, remote_url: url)
        url

      _ ->
        "http://localhost:4444/"
    end
  end

  defp run_container(port) do
    args =
      [
        "run",
        "-d",
        "--name",
        @container_name,
        "-p",
        "#{port}:#{@container_port}",
        "--shm-size=512m"
      ] ++ host_gateway_args() ++ [@image]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, {:docker_run_failed, output}}
    end
  end

  defp wait_for_ready(url, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_ready(url, deadline)
  end

  defp do_wait_for_ready(url, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case check_ready(url) do
        true ->
          :ok

        false ->
          Process.sleep(500)
          do_wait_for_ready(url, deadline)
      end
    end
  end

  defp check_ready(base_url) do
    uri = URI.parse("#{base_url}status")
    port = uri.port || 80

    with {:ok, conn} <- Mint.HTTP.connect(:http, uri.host, port),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", uri.path, [], "") do
      result =
        receive do
          message ->
            case Mint.HTTP.stream(conn, message) do
              {:ok, _conn, responses} ->
                Enum.any?(responses, fn
                  {:data, ^ref, data} ->
                    case Jason.decode(data) do
                      {:ok, %{"value" => %{"ready" => true}}} -> true
                      _ -> false
                    end

                  _ ->
                    false
                end)

              _ ->
                false
            end
        after
          2_000 -> false
        end

      Mint.HTTP.close(conn)
      result
    else
      _ -> false
    end
  end

  defp host_gateway_args do
    # Allow Chrome in Docker to reach the host machine's services
    # (e.g. the Phoenix test server). Docker Desktop supports
    # host.docker.internal natively; Linux needs --add-host.
    case :os.type() do
      {:unix, :linux} ->
        ["--add-host=host.docker.internal:host-gateway"]

      _ ->
        # Docker Desktop (macOS, Windows) supports host.docker.internal natively
        []
    end
  end

  @doc """
  Rewrites a localhost base_url to use host.docker.internal so that
  Chrome running inside Docker can reach the host's test server.
  """
  def rewrite_base_url(base_url) when is_binary(base_url) do
    uri = URI.parse(base_url)

    if uri.host in ["localhost", "127.0.0.1"] do
      URI.to_string(%{uri | host: "host.docker.internal"})
    else
      base_url
    end
  end

  def rewrite_base_url(other), do: other

  defp find_available_port do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end
end
