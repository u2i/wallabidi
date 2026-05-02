defmodule Wallabidi.Chrome do
  @moduledoc """
  The Chrome driver speaks WebDriver BiDi to a chromium-bidi standalone
  server (`Wallabidi.Chrome.BidiServer`), which forwards to Chrome over
  CDP. No chromedriver is involved.

  All test sessions multiplex over one shared Chrome instance via BiDi
  `userContext`s — each test gets its own isolated profile (cookies,
  localStorage, etc.) and a fresh `browsingContext` (tab) within it.
  This matches Playwright's "one browser, many contexts" model.

  ## Usage

  ```elixir
  {:ok, session} = Wallabidi.start_session()
  ```

  ## Configuration

  Chrome runs headless by default. Pass `[window_size: [width: W, height: H]]`
  to `start_session/1` to override the viewport.
  """
  use Supervisor

  alias Wallabidi.BiDi.WebSocketClient
  alias Wallabidi.{BiDiClient, DependencyError}
  alias Wallabidi.Driver.SessionLifecycle
  import Wallabidi.Driver.LogChecker

  @typedoc """
  Options to pass to Wallabidi.start_session/1

  * `:capabilities` — extra capabilities to merge into the session struct
  * `:window_size` — initial viewport size as `[width: w, height: h]`
  * `:metadata` — beam metadata appended to the user-agent (Ecto sandbox)
  """
  @behaviour Wallabidi.Driver

  @type start_session_opts ::
          {:capabilities, map}
          | {:window_size, keyword()}
          | {:metadata, map()}

  @doc false
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @doc false
  def init(_) do
    # The Chrome (BiDi) driver speaks BiDi to a chromium-bidi standalone
    # server (Wallabidi.Chrome.BidiServer), which forwards to Chrome via
    # CDP. No chromedriver involved.
    children = [
      {Wallabidi.Chrome.BidiServer, [name: Wallabidi.Chrome.BidiServer]},
      Wallabidi.Chrome.SharedSession
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  @spec validate() :: :ok | {:error, DependencyError.t()}
  def validate do
    cond do
      not chrome_available?() ->
        {:error,
         DependencyError.exception(
           "Chrome binary not found. Run `mix wallabidi.install`."
         )}

      not node_available?() ->
        {:error,
         DependencyError.exception(
           "Node.js not found. Wallabidi's BiDi driver runs the chromium-bidi server " <>
             "(a small Node process). Install Node 20+ to use the Chrome BiDi driver."
         )}

      not bidi_server_installed?() ->
        {:error,
         DependencyError.exception(
           "chromium-bidi server dependencies not installed. " <>
             "Run `cd #{bidi_server_dir()} && npm install`."
         )}

      true ->
        :ok
    end
  end

  defp chrome_available? do
    case Wallabidi.BrowserPaths.chrome_path() do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp node_available? do
    case System.find_executable("node") do
      nil -> false
      _ -> true
    end
  end

  defp bidi_server_installed? do
    File.exists?(Path.join([bidi_server_dir(), "node_modules", "chromium-bidi"]))
  end

  defp bidi_server_dir do
    Path.absname("priv/bidi-server", Application.app_dir(:wallabidi))
  end

  @doc false
  def start_session(opts \\ []) do
    Wallabidi.SessionProcess.start_link(
      init_fun: fn -> do_start_session(opts) end,
      teardown_fun: &do_end_session/1
    )
  end

  defp do_start_session(opts) do
    # Reuse the shared BiDi connection (chromium-bidi → CDP → one
    # Chrome). Each test session creates its own userContext (isolated
    # cookies/storage) and a new browsingContext (tab) within that
    # context.
    bidi_pid = Wallabidi.Chrome.SharedSession.get()

    {:ok, user_context_id} = create_user_context(bidi_pid)

    {:ok, browsing_context_id} = create_browsing_context(bidi_pid, user_context_id)

    install_bootstrap!(bidi_pid, browsing_context_id)

    user_caps = Keyword.get(opts, :capabilities, %{})

    unique_id = "chrome-bidi-#{System.unique_integer([:positive])}"

    session = %Wallabidi.Session{
      session_url: "bidi://#{unique_id}",
      url: "bidi://#{unique_id}",
      id: unique_id,
      driver: __MODULE__,
      protocol: Wallabidi.Protocol.BiDi,
      server: __MODULE__,
      bidi_pid: bidi_pid,
      browsing_context: browsing_context_id,
      capabilities:
        Map.merge(user_caps, %{
          user_context_id: user_context_id,
          shared_connection: true
        })
    }

    # Subscribe to console logs so they buffer from session start,
    # and to page load events so SessionProcess can track navigations.
    Wallabidi.Protocol.subscribe(session, :log)
    Wallabidi.Protocol.subscribe(session, :page_load)
    Wallabidi.Protocol.subscribe(session, :find_binding)

    if window_size = Keyword.get(opts, :window_size),
      do: {:ok, _} = set_window_size(session, window_size[:width], window_size[:height])

    {:ok, session}
  end

  defp create_user_context(bidi_pid) do
    {method, params} = Wallabidi.BiDi.Commands.create_user_context()

    case WebSocketClient.send_command(bidi_pid, method, params) do
      {:ok, %{"result" => %{"userContext" => uc}}} -> {:ok, uc}
      {:ok, %{"userContext" => uc}} -> {:ok, uc}
      other -> {:error, {:create_user_context_failed, other}}
    end
  end

  defp create_browsing_context(bidi_pid, user_context_id) do
    {method, params} =
      Wallabidi.BiDi.Commands.create_context("tab", %{userContext: user_context_id})

    case WebSocketClient.send_command(bidi_pid, method, params) do
      {:ok, %{"result" => %{"context" => ctx}}} -> {:ok, ctx}
      {:ok, %{"context" => ctx}} -> {:ok, ctx}
      other -> {:error, {:create_context_failed, other}}
    end
  end

  defp install_bootstrap!(bidi_pid, context_id) do
    # Install push-based element finding via two paths:
    #
    # 1. addPreloadScript — persists across navigations. Each new document
    #    gets the bootstrap with a fresh channel callback.
    # 2. callFunction — installs immediately on the current page so finds
    #    work before the first navigation. The channel argument makes
    #    __wallabidi callable right away (no about:blank navigate needed).
    #
    # The bootstrap guards with `if (window.__w) return;` so the preload
    # script is a no-op if callFunction already installed it on this page.
    channel_arg = [%{type: "channel", value: %{channel: "__wallabidi"}}]
    bootstrap_fn = Wallabidi.Bootstrap.bidi_preload()

    {cmd, params} = Wallabidi.BiDi.Commands.add_preload_script(bootstrap_fn, channel_arg)
    {:ok, _} = WebSocketClient.send_command(bidi_pid, cmd, params)

    {cmd, params} =
      Wallabidi.BiDi.Commands.call_function(context_id, bootstrap_fn, channel_arg)

    WebSocketClient.send_command(bidi_pid, cmd, params)
    :ok
  end

  @doc false
  def end_session(%Wallabidi.Session{} = session, _opts \\ []) do
    Wallabidi.SessionProcess.stop(session)
    :ok
  end

  # Runs inside SessionProcess.terminate/2. Must not raise — wrapped in
  # SessionLifecycle.teardown for idempotent, exit-safe cleanup.
  defp do_end_session(session) do
    SessionLifecycle.teardown(session)
  end

  @doc """
  Returns the default BiDi capabilities used by Wallabidi-managed
  sessions. Mostly a starting point for users who want to merge in
  their own capabilities — the chromium-bidi server applies its own
  Chrome launch args independently.
  """
  def default_capabilities do
    %{
      browserName: "chrome",
      unhandledPromptBehavior: "ignore"
    }
  end

  @doc false
  # Releases per-session server-side resources. Sessions share the
  # underlying chromium-bidi connection / Chrome instance via
  # Chrome.SharedSession, so this only removes the per-session
  # userContext (closing its browsingContexts and clearing its
  # cookies/storage).
  def release_server_session(
        %Wallabidi.Session{capabilities: caps, bidi_pid: pid, browsing_context: ctx} = _session
      ) do
    # Drop the BEAM-side ETS subscriptions for this browsing context so the
    # shared dispatch table doesn't grow without bound across many sessions.
    if is_pid(pid) and is_binary(ctx) do
      WebSocketClient.unsubscribe_session(pid, ctx)
    end

    case caps do
      %{user_context_id: uc} when is_binary(uc) and is_pid(pid) ->
        {method, params} = Wallabidi.BiDi.Commands.remove_user_context(uc)

        try do
          WebSocketClient.send_command(pid, method, params, 5_000)
        rescue
          _ -> {:ok, %{}}
        catch
          :exit, _ -> {:ok, %{}}
        end

      _ ->
        {:ok, %{}}
    end
  end

  @doc false
  # No stale-session cleanup needed: with chromium-bidi, session state
  # lives in the Node subprocess. When wallabidi (and the BidiServer
  # GenServer) shuts down, the Node subprocess gets killed and Chrome
  # goes with it.
  def cleanup_stale_sessions, do: :ok

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
  defdelegate parse_log(log), to: Wallabidi.Chrome.Logger
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
  def clear(element, opts \\ []), do: delegate(:clear, element, [opts])
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

end
