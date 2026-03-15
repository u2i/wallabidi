defmodule Wallaby.Chrome do
  @moduledoc """
  The Chrome driver uses chromedriver and WebDriver BiDi to control Chrome.

  ## Usage

  ```elixir
  {:ok, session} = Wallaby.start_session()
  ```

  ## Configuration

  ### Headless

  Chrome will run in headless mode by default.

  ```elixir
  config :wallaby,
    chromedriver: [
      headless: false
    ]
  ```

  ### Capabilities

  ```elixir
  config :wallaby,
    chromedriver: [
      capabilities: %{
        chromeOptions: %{args: ["--headless"]}
      }
    ]
  ```

  ### ChromeDriver binary

  ```elixir
  config :wallaby,
    chromedriver: [
      path: "path/to/chromedriver"
    ]
  ```

  ### Chrome binary

  ```elixir
  config :wallaby,
    chromedriver: [
      binary: "path/to/chrome"
    ]
  ```
  """
  use Supervisor

  @default_readiness_timeout 10_000

  alias Wallaby.BiDi.{Commands, ResponseParser, WebSocketClient}
  alias Wallaby.BiDiClient
  alias Wallaby.Chrome.Chromedriver
  alias Wallaby.{DependencyError, Metadata}
  import Wallaby.Driver.LogChecker

  @typedoc """
  Options to pass to Wallaby.start_session/1

  * `:capabilities` - capabilities to pass to chromedriver on session startup
  * `:readiness_timeout` - milliseconds to wait for chromedriver to be ready (default: #{@default_readiness_timeout})
  * `:window_size` - initial window size as `[width: w, height: h]`
  * `:metadata` - beam metadata to append to user-agent
  """
  @type start_session_opts ::
          {:capabilities, map}
          | {:readiness_timeout, timeout()}
          | {:window_size, keyword()}
          | {:metadata, map()}

  @doc false
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @doc false
  def init(_) do
    children = [
      {PartitionSupervisor,
       child_spec: Wallaby.Chrome.Chromedriver,
       name: Wallaby.Chromedrivers,
       partitions: min(System.schedulers_online(), 10)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec validate() :: :ok | {:error, DependencyError.t()}
  def validate do
    with {:ok, chromedriver_version} <- get_chromedriver_version(),
         {:ok, chrome_version} <- get_chrome_version(),
         :ok <- minimum_version_check(chromedriver_version) do
      version_compare(chrome_version, chromedriver_version)
    end
  end

  @doc false
  def start_session(opts \\ []) do
    opts |> Keyword.get(:readiness_timeout, @default_readiness_timeout) |> wait_until_ready!()

    base_url = Chromedriver.base_url()

    capabilities =
      opts
      |> Keyword.get_lazy(:capabilities, fn -> capabilities_from_config(opts) end)
      |> put_beam_metadata(opts)
      |> Map.put(:webSocketUrl, true)

    with {:ok, response} <- create_session(base_url, capabilities) do
      id = response["sessionId"]

      session = %Wallaby.Session{
        session_url: base_url <> "session/#{id}",
        url: base_url <> "session/#{id}",
        id: id,
        driver: __MODULE__,
        server: Chromedriver,
        capabilities: capabilities
      }

      session = connect_bidi!(session, response)

      if window_size = Keyword.get(opts, :window_size),
        do: {:ok, _} = set_window_size(session, window_size[:width], window_size[:height])

      {:ok, session}
    end
  end

  defp create_session(base_url, capabilities) do
    params = Jason.encode!(%{desiredCapabilities: capabilities})
    url = "#{base_url}session"

    case mint_request(:post, url, params) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect_bidi!(session, response) do
    ws_url =
      get_in(response, ["value", "capabilities", "webSocketUrl"]) ||
        get_in(response, ["capabilities", "webSocketUrl"]) ||
        raise "chromedriver did not return a webSocketUrl — upgrade chromedriver"

    {:ok, bidi_pid} = WebSocketClient.start_link(ws_url)

    {:ok, result} =
      WebSocketClient.send_command(bidi_pid, "browsingContext.getTree", %{})

    {:ok, context_id} = ResponseParser.extract_context(result)

    # Subscribe to log events so they buffer from session start
    {method, params} = Commands.subscribe(["log.entryAdded"])
    WebSocketClient.send_command(bidi_pid, method, params)
    WebSocketClient.subscribe(bidi_pid, "log.entryAdded")

    %{session | bidi_pid: bidi_pid, browsing_context: context_id}
  end

  @doc false
  def end_session(%Wallaby.Session{} = session, _opts \\ []) do
    if session.bidi_pid, do: WebSocketClient.close(session.bidi_pid)
    delete_session(session)
    :ok
  end

  defp delete_session(session) do
    mint_request(:delete, session.session_url, "")
  rescue
    _ -> {:ok, %{}}
  end

  @doc false
  def blank_page?(session) do
    case current_url(session) do
      {:ok, url} -> url in ["data:,", "about:blank"]
      _ -> false
    end
  end

  # All operations delegate to BiDiClient
  defp delegate(fun, element_or_session, args \\ []) do
    check_logs!(element_or_session, fn ->
      apply(BiDiClient, fun, [element_or_session | args])
    end)
  end

  @doc false
  defdelegate accept_alert(session, fun), to: BiDiClient
  @doc false
  defdelegate dismiss_alert(session, fun), to: BiDiClient
  @doc false
  defdelegate accept_confirm(session, fun), to: BiDiClient
  @doc false
  defdelegate dismiss_confirm(session, fun), to: BiDiClient
  @doc false
  defdelegate accept_prompt(session, input, fun), to: BiDiClient
  @doc false
  defdelegate dismiss_prompt(session, fun), to: BiDiClient
  @doc false
  defdelegate parse_log(log), to: Wallaby.Chrome.Logger
  @doc false
  defdelegate log(session), to: BiDiClient

  @doc false
  def window_handle(session), do: delegate(:window_handle, session)
  @doc false
  def window_handles(session), do: delegate(:window_handles, session)
  @doc false
  def focus_window(session, window_handle), do: delegate(:focus_window, session, [window_handle])
  @doc false
  def close_window(session), do: delegate(:close_window, session)
  @doc false
  def get_window_size(session), do: delegate(:get_window_size, session)
  @doc false
  def set_window_size(session, width, height),
    do: delegate(:set_window_size, session, [width, height])

  @doc false
  def get_window_position(session), do: delegate(:get_window_position, session)
  @doc false
  def set_window_position(session, x, y), do: delegate(:set_window_position, session, [x, y])
  @doc false
  def maximize_window(session), do: delegate(:maximize_window, session)
  @doc false
  def focus_frame(session, frame), do: delegate(:focus_frame, session, [frame])
  @doc false
  def focus_parent_frame(session), do: delegate(:focus_parent_frame, session)
  @doc false
  def cookies(session), do: delegate(:cookies, session)
  @doc false
  def current_path(session), do: delegate(:current_path, session)
  @doc false
  def current_url(session), do: delegate(:current_url, session)
  @doc false
  def page_title(session), do: delegate(:page_title, session)
  @doc false
  def page_source(session), do: delegate(:page_source, session)

  @doc false
  def set_cookie(session, key, value, attributes \\ []),
    do: delegate(:set_cookie, session, [key, value, attributes])

  @doc false
  def visit(session, url), do: delegate(:visit, session, [url])
  @doc false
  def attribute(element, name), do: delegate(:attribute, element, [name])
  @doc false
  def click(element), do: delegate(:click, element)
  @doc false
  def click(parent, button), do: delegate(:click, parent, [button])
  @doc false
  def double_click(parent), do: delegate(:double_click, parent)
  @doc false
  def button_down(parent, button), do: delegate(:button_down, parent, [button])
  @doc false
  def button_up(parent, button), do: delegate(:button_up, parent, [button])
  @doc false
  def hover(element), do: delegate(:move_mouse_to, element, [element])
  @doc false
  def move_mouse_by(parent, x_offset, y_offset),
    do: delegate(:move_mouse_to, parent, [nil, x_offset, y_offset])

  @doc false
  def touch_down(session, element, x_or_offset, y_or_offset),
    do: delegate(:touch_down, session, [element, x_or_offset, y_or_offset])

  @doc false
  def touch_up(session), do: delegate(:touch_up, session)
  @doc false
  def tap(element), do: delegate(:tap, element)
  @doc false
  def touch_move(parent, x, y), do: delegate(:touch_move, parent, [x, y])
  @doc false
  def touch_scroll(element, x_offset, y_offset),
    do: delegate(:touch_scroll, element, [x_offset, y_offset])

  @doc false
  def clear(element), do: delegate(:clear, element)
  @doc false
  def displayed(element), do: delegate(:displayed, element)
  @doc false
  def selected(element), do: delegate(:selected, element)
  @doc false
  def set_value(element, value), do: delegate(:set_value, element, [value])
  @doc false
  def text(element), do: delegate(:text, element)

  @doc false
  def execute_script(session_or_element, script, args \\ [], opts \\ []) do
    check_logs = Keyword.get(opts, :check_logs, true)

    request_fn = fn ->
      BiDiClient.execute_script(session_or_element, script, args)
    end

    if check_logs do
      check_logs!(session_or_element, request_fn)
    else
      request_fn.()
    end
  end

  @doc false
  def execute_script_async(session_or_element, script, args \\ [], opts \\ []) do
    check_logs = Keyword.get(opts, :check_logs, true)

    request_fn = fn ->
      BiDiClient.execute_script_async(session_or_element, script, args)
    end

    if check_logs do
      check_logs!(session_or_element, request_fn)
    else
      request_fn.()
    end
  end

  @doc false
  def find_elements(session_or_element, compiled_query),
    do: delegate(:find_elements, session_or_element, [compiled_query])

  @doc false
  def send_keys(session_or_element, keys), do: delegate(:send_keys, session_or_element, [keys])
  @doc false
  def element_size(element), do: delegate(:element_size, element)
  @doc false
  def element_location(element), do: delegate(:element_location, element)
  @doc false
  def take_screenshot(session_or_element), do: delegate(:take_screenshot, session_or_element)

  @doc false
  def default_capabilities do
    chrome_options =
      maybe_put_chrome_executable(%{
        args: [
          "--no-sandbox",
          "window-size=1280,800",
          "--disable-gpu",
          "--headless",
          "--fullscreen",
          "--user-agent=Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"
        ]
      })

    %{
      javascriptEnabled: false,
      loadImages: false,
      version: "",
      rotatable: false,
      takesScreenshot: true,
      cssSelectorsEnabled: true,
      nativeEvents: false,
      platform: "ANY",
      unhandledPromptBehavior: "accept",
      loggingPrefs: %{
        browser: "DEBUG"
      },
      chromeOptions: chrome_options
    }
  end

  # HTTP helpers using Mint (for session create/delete only)

  defp mint_request(method, url, body) do
    uri = URI.parse(url)
    port = uri.port || 80

    with {:ok, conn} <- Mint.HTTP.connect(:http, uri.host, port),
         {:ok, conn, ref} <-
           Mint.HTTP.request(conn, String.upcase(to_string(method)), uri.path, headers(), body) do
      receive_response(conn, ref, "")
    end
  end

  defp receive_response(conn, ref, acc) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            {done?, acc} =
              Enum.reduce(responses, {false, acc}, fn
                {:data, ^ref, data}, {_, a} -> {false, a <> data}
                {:done, ^ref}, {_, a} -> {true, a}
                _, acc -> acc
              end)

            if done? do
              Mint.HTTP.close(conn)

              case Jason.decode(acc) do
                {:ok, decoded} -> check_for_errors(decoded)
                {:error, _} -> {:ok, %{}}
              end
            else
              receive_response(conn, ref, acc)
            end

          {:error, _, reason, _} ->
            {:error, reason}
        end
    after
      10_000 -> {:error, :timeout}
    end
  end

  defp check_for_errors(%{"value" => %{"message" => "stale element reference" <> _}}),
    do: {:error, :stale_reference}

  defp check_for_errors(%{"value" => %{"error" => _, "message" => msg}}),
    do: raise(msg)

  defp check_for_errors(response), do: {:ok, response}

  defp headers do
    [{"accept", "application/json"}, {"content-type", "application/json;charset=UTF-8"}]
  end

  # Chrome/chromedriver discovery and version checking

  @doc false
  def find_chrome_executable do
    default_chrome_paths =
      case :os.type() do
        {:unix, :darwin} ->
          [
            "/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium"
          ]

        {:unix, :linux} ->
          ["google-chrome", "chromium", "chromium-browser"]

        {:win32, :nt} ->
          ["C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"]
      end

    chrome_path =
      :wallaby
      |> Application.get_env(:chromedriver, [])
      |> Keyword.get(:binary, [])

    [Path.expand(chrome_path) | default_chrome_paths]
    |> Enum.find_value(&System.find_executable/1)
    |> case do
      path when is_binary(path) ->
        {:ok, path}

      nil ->
        {:error,
         DependencyError.exception(
           "Wallaby can't find Chrome. Make sure you have chrome installed and included in your path."
         )}
    end
  end

  @doc false
  def find_chromedriver_executable do
    chromedriver_path =
      :wallaby
      |> Application.get_env(:chromedriver, [])
      |> Keyword.get(:path, "chromedriver")

    [Path.expand(chromedriver_path), chromedriver_path]
    |> Enum.find_value(&System.find_executable/1)
    |> case do
      path when is_binary(path) ->
        {:ok, path}

      nil ->
        {:error,
         DependencyError.exception(
           "Wallaby can't find chromedriver. Make sure you have chromedriver installed and included in your path."
         )}
    end
  end

  @doc false
  def get_chrome_version do
    case :os.type() do
      {:win32, :nt} ->
        {stdout, 0} =
          System.cmd("reg", [
            "query",
            "HKLM\\SOFTWARE\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Google Chrome"
          ])

        {:ok, parse_version(stdout)}

      _ ->
        case find_chrome_executable() do
          {:ok, exe} ->
            {stdout, 0} = System.cmd(exe, ["--version"])
            {:ok, parse_version(stdout)}

          error ->
            error
        end
    end
  end

  @doc false
  def get_chromedriver_version do
    case find_chromedriver_executable() do
      {:ok, exe} ->
        {stdout, 0} = System.cmd(exe, ["--version"])
        {:ok, parse_version(stdout)}

      error ->
        error
    end
  end

  defp parse_version(body) do
    case Regex.run(~r/.*?(\d+\.\d+(\.\d+)?)/, body) do
      [_, version, _] -> String.split(version, ".") |> Enum.map(&String.to_integer/1)
      [_, version] -> String.split(version, ".") |> Enum.map(&String.to_integer/1)
    end
  end

  defp version_compare(chrome, chromedriver) when chrome == chromedriver, do: :ok

  defp version_compare(chrome, chromedriver) do
    IO.warn(
      "Chrome version #{Enum.join(chrome, ".")} and chromedriver version #{Enum.join(chromedriver, ".")} don't match."
    )

    :ok
  end

  defp minimum_version_check([major | _]) when major > 2, do: :ok
  defp minimum_version_check([2, minor | _]) when minor >= 30, do: :ok

  defp minimum_version_check(_) do
    {:error,
     DependencyError.exception("Wallaby needs at least chromedriver 2.30 to run correctly.")}
  end

  defp wait_until_ready!(timeout) do
    case Chromedriver.wait_until_ready(timeout) do
      :ok -> :ok
      {:error, :timeout} -> raise "timeout waiting for chromedriver to be ready"
    end
  end

  defp capabilities_from_config(opts) do
    :wallaby
    |> Application.get_env(:chromedriver, [])
    |> Keyword.get_lazy(:capabilities, &default_capabilities/0)
    |> put_headless_config(opts)
    |> put_binary_config(opts)
  end

  defp maybe_put_chrome_executable(chrome_options) do
    case find_chrome_executable() do
      {:ok, binary} -> Map.put(chrome_options, :binary, binary)
      _ -> chrome_options
    end
  end

  defp put_headless_config(capabilities, opts) do
    case resolve_opt(opts, :headless) do
      nil ->
        capabilities

      true ->
        update_in(capabilities, [:chromeOptions, :args], fn args ->
          Enum.uniq(args ++ ["--headless"])
        end)

      false ->
        update_in(capabilities, [:chromeOptions, :args], fn args ->
          args -- ["--headless"]
        end)
    end
  end

  defp put_binary_config(capabilities, opts) do
    case resolve_opt(opts, :binary) do
      nil -> capabilities
      path -> put_in(capabilities, [:chromeOptions, :binary], path)
    end
  end

  defp put_beam_metadata(capabilities, opts) do
    update_in(capabilities, [:chromeOptions, :args], fn args ->
      Enum.map(args, fn
        "--user-agent=" <> ua ->
          "--user-agent=#{Metadata.append(ua, opts[:metadata])}"

        arg ->
          arg
      end)
    end)
  end

  defp resolve_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Application.get_env(:wallaby, :chromedriver, []) |> Keyword.get(key)
    end
  end
end
