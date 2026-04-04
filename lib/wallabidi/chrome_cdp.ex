defmodule Wallabidi.ChromeCDP do
  @moduledoc """
  Chrome driver using CDP (Chrome DevTools Protocol) directly.

  Launches one Chrome process, maintains one CDP WebSocket connection,
  and creates a fresh target (tab) per test — matching Playwright's
  "reuse browser, fresh context" model.

  User-agent metadata for Ecto sandbox isolation is set per-target via
  `Emulation.setUserAgentOverride`.

  ## Usage

  ```elixir
  config :wallabidi, driver: :chrome_cdp
  ```

  ## Configuration

  ```elixir
  config :wallabidi,
    chrome_cdp: [
      remote_url: "ws://chrome:9222/devtools/browser/..."  # optional
    ]
  ```

  When no `remote_url` is set, Wallabidi launches a local Chrome process.
  """

  use Supervisor

  @behaviour Wallabidi.Driver

  alias Wallabidi.BiDi.WebSocketClient
  alias Wallabidi.{CDPClient, DependencyError, Metadata, Session}
  alias Wallabidi.Chrome.Server, as: ChromeServer
  import Wallabidi.Driver.LogChecker

  @base_user_agent "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"

  # --- Supervisor ---

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl Supervisor
  def init(_) do
    server =
      if remote_url() do
        []
      else
        [{ChromeServer, [name: Wallabidi.ChromeCDP.Server]}]
      end

    Supervisor.init(server, strategy: :one_for_one)
  end

  # --- Validation ---

  @doc false
  def validate do
    cond do
      remote_url() ->
        :ok

      chrome_available?() ->
        :ok

      true ->
        {:error,
         DependencyError.exception(
           "Wallabidi can't find Chrome. Install Chrome or configure a remote_url."
         )}
    end
  end

  # --- Session lifecycle ---

  @impl true
  def start_session(opts \\ []) do
    cdp_pid = ensure_cdp_connection()

    # Create an isolated browser context (incognito-like) per test,
    # then a target within it. Disposal cleans up everything.
    with {:ok, %{"browserContextId" => ctx_id}} <-
           CDPClient.create_browser_context(cdp_pid),
         {:ok, %{target_id: target_id, session_id: session_id}} <-
           CDPClient.create_session(cdp_pid,
             flat_session_id: true,
             browser_context_id: ctx_id
           ) do
      unique_id = "chrome-cdp-#{System.unique_integer([:positive])}"

      session = %Session{
        id: unique_id,
        session_url: "cdp://#{unique_id}",
        url: "cdp://#{unique_id}",
        driver: __MODULE__,
        server: __MODULE__,
        bidi_pid: cdp_pid,
        browsing_context: session_id,
        capabilities: %{
          target_id: target_id,
          browser_context_id: ctx_id,
          flat_session_id: true
        }
      }

      # Subscribe to console/error events and forward as log.entryAdded
      # so LogChecker can drain them
      WebSocketClient.subscribe(cdp_pid, "Runtime.consoleAPICalled")
      WebSocketClient.subscribe(cdp_pid, "Runtime.exceptionThrown")

      if metadata = Keyword.get(opts, :metadata) do
        CDPClient.set_user_agent(session, Metadata.append(@base_user_agent, metadata))
      end

      if window_size = Keyword.get(opts, :window_size) do
        {:ok, _} = set_window_size(session, window_size[:width], window_size[:height])
      end

      {:ok, session}
    end
  end

  @impl true
  def end_session(session) do
    CDPClient.close_session(session)
    :ok
  rescue
    _ -> :ok
  end

  # --- Delegation to CDPClient (wrapped in check_logs! for JS error detection) ---

  defp delegate(fun, session_or_element, args \\ []) do
    check_logs!(session_or_element, fn ->
      apply(CDPClient, fun, [session_or_element | args])
    end)
  end

  @impl true
  def visit(session, url), do: delegate(:visit, session, [url])

  @impl true
  def current_url(session), do: delegate(:current_url, session)

  @impl true
  def current_path(session) do
    case current_url(session) do
      {:ok, url} -> {:ok, URI.parse(url).path || "/"}
      error -> error
    end
  end

  @impl true
  def find_elements(parent, query), do: delegate(:find_elements, parent, [query])

  @impl true
  def click(element), do: delegate(:click, element)

  @impl true
  def text(element), do: delegate(:text, element)

  @impl true
  def attribute(element, name), do: delegate(:attribute, element, [name])

  @impl true
  def displayed(element), do: delegate(:displayed, element)

  @impl true
  def selected(element), do: delegate(:selected, element)

  @impl true
  def set_value(element, value), do: delegate(:set_value, element, [value])

  @impl true
  def clear(element, _opts \\ []), do: delegate(:clear, element)

  @impl true
  def page_source(session), do: delegate(:page_source, session)

  @impl true
  def page_title(session), do: delegate(:page_title, session)

  @impl true
  def execute_script(session, script, args), do: delegate(:execute_script, session, [script, args])

  @impl true
  def execute_script_async(session, script, args),
    do: delegate(:execute_script_async, session, [script, args])

  @impl true
  def send_keys(session_or_element, keys), do: delegate(:send_keys, session_or_element, [keys])

  @impl true
  def cookies(session), do: CDPClient.cookies(session)

  @impl true
  def set_cookie(session, name, value), do: CDPClient.set_cookie(session, name, value)

  @impl true
  def set_cookie(session, name, value, attrs),
    do: CDPClient.set_cookie(session, name, value, attrs)

  @impl true
  def take_screenshot(session), do: CDPClient.take_screenshot(session)

  @impl true
  def get_window_size(session), do: CDPClient.get_window_size(session)

  @impl true
  def set_window_size(session, w, h), do: CDPClient.set_window_size(session, w, h)

  # --- Mouse events via Input.dispatchMouseEvent ---

  def hover(element) do
    session = root_session(element)

    case get_element_center(element) do
      {:ok, {x, y}} ->
        put_mouse_pos(session, x, y)
        dispatch_mouse(session, "mouseMoved", x, y)

      error ->
        error
    end
  end

  def double_click(parent) do
    {x, y} = get_mouse_pos(parent)
    dispatch_mouse(parent, "mousePressed", x, y, button: "left", clickCount: 2)
    dispatch_mouse(parent, "mouseReleased", x, y, button: "left", clickCount: 2)
  end

  def click(parent, button) do
    {x, y} = get_mouse_pos(parent)
    btn = mouse_button(button)
    dispatch_mouse(parent, "mousePressed", x, y, button: btn, clickCount: 1)
    dispatch_mouse(parent, "mouseReleased", x, y, button: btn, clickCount: 1)
  end

  def button_down(parent, button) do
    {x, y} = get_mouse_pos(parent)
    dispatch_mouse(parent, "mousePressed", x, y, button: mouse_button(button), clickCount: 1)
  end

  def button_up(parent, button) do
    {x, y} = get_mouse_pos(parent)
    dispatch_mouse(parent, "mouseReleased", x, y, button: mouse_button(button), clickCount: 1)
  end

  def move_mouse_by(parent, x_offset, y_offset) do
    {cx, cy} = get_mouse_pos(parent)
    nx = cx + x_offset
    ny = cy + y_offset
    put_mouse_pos(parent, nx, ny)
    dispatch_mouse(parent, "mouseMoved", nx, ny)
  end

  # --- Touch events via Input.dispatchTouchEvent ---

  def touch_down(session, nil, x, y) do
    dispatch_touch(root_session(session), "touchStart", x, y)
  end

  def touch_down(session, element, x_offset, y_offset) do
    session = root_session(session)

    case get_element_topleft(element) do
      {:ok, {ex, ey}} ->
        dispatch_touch(session, "touchStart", trunc(ex + x_offset), trunc(ey + y_offset))

      error ->
        error
    end
  end

  def touch_up(session), do: dispatch_touch(session, "touchEnd", 0, 0)

  def tap(element) do
    session = root_session(element)

    case get_element_center(element) do
      {:ok, {x, y}} ->
        dispatch_touch(session, "touchStart", trunc(x), trunc(y))
        dispatch_touch(session, "touchEnd", trunc(x), trunc(y))

      error ->
        error
    end
  end

  def touch_move(session, x, y), do: dispatch_touch(session, "touchMove", x, y)

  def touch_scroll(element, x_offset, y_offset) do
    session = root_session(element)

    case get_element_center(element) do
      {:ok, {x, y}} ->
        sx = trunc(x)
        sy = trunc(y)
        dispatch_touch(session, "touchStart", sx, sy)
        dispatch_touch(session, "touchMove", sx + x_offset, sy + y_offset)
        dispatch_touch(session, "touchEnd", sx + x_offset, sy + y_offset)

      error ->
        error
    end
  end

  # --- Element geometry ---

  def element_size(element) do
    session = root_session(element)

    CDPClient.send_cdp_command(session, "Runtime.callFunctionOn", %{
      objectId: element.bidi_shared_id,
      functionDeclaration: "function() { var r = this.getBoundingClientRect(); return JSON.stringify({width: Math.round(r.width), height: Math.round(r.height)}); }",
      returnByValue: true
    })
    |> extract_json_result()
  end

  def element_location(element) do
    session = root_session(element)

    CDPClient.send_cdp_command(session, "Runtime.callFunctionOn", %{
      objectId: element.bidi_shared_id,
      functionDeclaration: "function() { var r = this.getBoundingClientRect(); return JSON.stringify({x: Math.round(r.x), y: Math.round(r.y)}); }",
      returnByValue: true
    })
    |> extract_json_result()
  end

  defdelegate parse_log(log), to: Wallabidi.Chrome.Logger
  def log(_session), do: {:ok, []}

  def blank_page?(session) do
    case current_url(session) do
      {:ok, url} -> url in ["data:,", "about:blank", ""]
      _ -> false
    end
  end

  # --- Dialog handling via CDP Page.javascriptDialogOpening ---

  @impl true
  def accept_alert(session, fun), do: handle_dialog(session, fun, true)

  @impl true
  def accept_confirm(session, fun), do: handle_dialog(session, fun, true)

  @impl true
  def accept_prompt(session, text, fun), do: handle_dialog(session, fun, true, text)

  @impl true
  def dismiss_confirm(session, fun), do: handle_dialog(session, fun, false)

  @impl true
  def dismiss_prompt(session, fun), do: handle_dialog(session, fun, false)

  defp handle_dialog(session, fun, accept, prompt_text \\ nil) do
    pid = session.bidi_pid
    caller = self()

    # Spawn a handler that listens for the dialog and handles it.
    # This avoids deadlocking: fun.(session) blocks until dialog is handled.
    handler =
      spawn_link(fn ->
        WebSocketClient.subscribe(pid, "Page.javascriptDialogOpening")

        {message, default_value} =
          receive do
            {:bidi_event, "Page.javascriptDialogOpening", event} ->
              msg = get_in(event, ["params", "message"]) || ""
              default = get_in(event, ["params", "defaultPrompt"])
              {msg, default}
          after
            10_000 -> {"", nil}
          end

        effective_text = prompt_text || default_value
        params = %{accept: accept}
        params = if effective_text, do: Map.put(params, :promptText, effective_text), else: params

        CDPClient.send_cdp_command(session, "Page.handleJavaScriptDialog", params)
        send(caller, {:dialog_handled, message})
      end)

    fun.(session)

    message =
      receive do
        {:dialog_handled, msg} -> msg
      after
        10_000 -> ""
      end

    Process.unlink(handler)
    message
  end

  @impl true
  def window_handle(_), do: {:ok, "main"}

  @impl true
  def window_handles(_), do: {:ok, ["main"]}

  @impl true
  def focus_window(_, _), do: {:ok, nil}

  @impl true
  def close_window(_), do: {:ok, nil}

  @impl true
  def maximize_window(_), do: {:ok, nil}

  @impl true
  def get_window_position(_), do: {:ok, %{"x" => 0, "y" => 0}}

  @impl true
  def set_window_position(_, _, _), do: {:ok, nil}

  @impl true
  def focus_frame(_, _), do: {:ok, nil}

  @impl true
  def focus_parent_frame(_), do: {:ok, nil}

  def cleanup_stale_sessions, do: :ok

  # --- Element helpers ---

  defp root_session(%Session{} = s), do: s
  defp root_session(%Wallabidi.Element{parent: p}), do: root_session(p)

  defp get_element_topleft(%Wallabidi.Element{bidi_shared_id: object_id} = element) do
    session = root_session(element)

    case CDPClient.send_cdp_command(session, "Runtime.callFunctionOn", %{
           objectId: object_id,
           functionDeclaration: "function() { var r = this.getBoundingClientRect(); return JSON.stringify({x: r.x, y: r.y}); }",
           returnByValue: true
         }) do
      {:ok, %{"result" => %{"value" => json}}} ->
        %{"x" => x, "y" => y} = Jason.decode!(json)
        {:ok, {x, y}}

      error ->
        error
    end
  end

  defp get_element_center(%Wallabidi.Element{bidi_shared_id: object_id} = element) do
    session = root_session(element)

    case CDPClient.send_cdp_command(session, "Runtime.callFunctionOn", %{
           objectId: object_id,
           functionDeclaration: "function() { var r = this.getBoundingClientRect(); return JSON.stringify({x: r.x + r.width/2, y: r.y + r.height/2}); }",
           returnByValue: true
         }) do
      {:ok, %{"result" => %{"value" => json}}} ->
        %{"x" => x, "y" => y} = Jason.decode!(json)
        {:ok, {x, y}}

      error ->
        error
    end
  end

  defp dispatch_mouse(parent, type, x, y, opts \\ []) do
    session = root_session(parent)

    params =
      %{type: type, x: trunc(x), y: trunc(y)}
      |> Map.merge(Map.new(opts))

    CDPClient.send_cdp_command(session, "Input.dispatchMouseEvent", params)
    {:ok, nil}
  end

  defp dispatch_touch(parent, type, x, y) do
    session = root_session(parent)
    touch_points = if type == "touchEnd", do: [], else: [%{x: x, y: y}]

    CDPClient.send_cdp_command(session, "Input.dispatchTouchEvent", %{
      type: type,
      touchPoints: touch_points
    })

    {:ok, nil}
  end

  defp put_mouse_pos(parent, x, y) do
    id = root_session(parent).id
    Process.put({:cdp_mouse, id}, {trunc(x), trunc(y)})
  end

  defp get_mouse_pos(parent) do
    id = root_session(parent).id
    Process.get({:cdp_mouse, id}, {0, 0})
  end

  defp mouse_button(:left), do: "left"
  defp mouse_button(:middle), do: "middle"
  defp mouse_button(:right), do: "right"
  defp mouse_button(other), do: to_string(other)

  defp extract_json_result({:ok, %{"result" => %{"value" => json}}}) when is_binary(json) do
    {:ok, Jason.decode!(json)}
  end

  defp extract_json_result(error), do: error

  # --- Internal ---

  defp ensure_cdp_connection do
    case :persistent_term.get({__MODULE__, :cdp_pid}, nil) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: create_cdp_connection()

      nil ->
        create_cdp_connection()
    end
  end

  defp create_cdp_connection do
    ws_url =
      if url = remote_url() do
        url
      else
        ChromeServer.ws_url(Wallabidi.ChromeCDP.Server)
      end

    {:ok, pid} = CDPClient.connect(ws_url)
    :persistent_term.put({__MODULE__, :cdp_pid}, pid)
    pid
  end

  defp remote_url do
    config(:remote_url)
  end

  defp chrome_available? do
    match?({:ok, _}, Wallabidi.Chrome.find_chrome_executable())
  end

  defp config(key, default \\ nil) do
    Application.get_env(:wallabidi, :chrome_cdp, []) |> Keyword.get(key, default)
  end
end
