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
  alias Wallabidi.Driver.SessionLifecycle
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

    children = server ++ [{Wallabidi.ChromeCDP.SharedConnection, []}]
    Supervisor.init(children, strategy: :one_for_one)
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
           "Chrome not found. Run `mix wallabidi.install` or set WALLABIDI_CHROME_URL."
         )}
    end
  end

  # --- Session lifecycle ---

  @impl true
  def start_session(opts \\ []) do
    Wallabidi.SessionProcess.start_link(
      init_fun: fn -> do_start_session(opts) end,
      teardown_fun: &SessionLifecycle.teardown/1
    )
  end

  defp do_start_session(opts) do
    cdp_pid = Wallabidi.ChromeCDP.SharedConnection.get()

    with {:ok, %{"browserContextId" => ctx_id}} <-
           CDPClient.create_browser_context(cdp_pid),
         {:ok, %{target_id: target_id, session_id: session_id}} <-
           CDPClient.create_session(cdp_pid,
             flat_session_id: true,
             browser_context_id: ctx_id
           ) do
      unique_id = "chrome-cdp-#{System.unique_integer([:positive])}"

      # Merge user-provided capabilities with internal ones for discoverability
      user_caps = Keyword.get(opts, :capabilities, %{})

      session = %Session{
        id: unique_id,
        session_url: "cdp://#{unique_id}",
        url: "cdp://#{unique_id}",
        driver: __MODULE__,
        protocol: Wallabidi.Protocol.CDP,
        server: __MODULE__,
        bidi_pid: cdp_pid,
        browsing_context: session_id,
        capabilities:
          Map.merge(user_caps, %{
            target_id: target_id,
            browser_context_id: ctx_id,
            flat_session_id: true,
            shared_connection: true
          })
      }

      # Subscribe to console/error events so LogChecker can drain them,
      # and to page load events so CDPClient.visit can wait for DOMContentLoaded.
      Wallabidi.Protocol.subscribe(session, :log)
      Wallabidi.Protocol.subscribe(session, :page_load)
      Wallabidi.Protocol.subscribe(session, :binding)

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
    Wallabidi.SessionProcess.stop(session)
    :ok
  end

  @impl true
  def release_server_session(session), do: CDPClient.close_session(session)

  # --- Delegation to CDPClient (wrapped in check_logs! for JS error detection) ---

  defp delegate(fun, session_or_element, args \\ []) do
    check_logs!(session_or_element, fn ->
      apply(CDPClient, fun, [session_or_element | args])
    end)
  end

  @impl true
  def visit(session, url) do
    result = delegate(:visit, session, [url])
    Wallabidi.LiveViewAware.await_liveview_connected(session)
    result
  end

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
  def find_elements(parent, query) do
    session = root_session(parent)

    case frame_stack(session) do
      [frame_object_id | _] ->
        find_elements_in_frame(parent, frame_object_id, query)

      [] ->
        delegate(:find_elements, parent, [query])
    end
  end

  defp find_elements_in_frame(parent, frame_object_id, {:css, selector}) do
    session = root_session(parent)

    {:ok, %{"result" => %{"objectId" => array_id}}} =
      CDPClient.send_cdp_command(session, "Runtime.callFunctionOn", %{
        objectId: frame_object_id,
        functionDeclaration: """
        function(sel) {
          return Array.from(this.contentDocument.querySelectorAll(sel));
        }
        """,
        arguments: [%{value: selector}],
        returnByValue: false
      })

    extract_elements_from_array(session, parent, array_id)
  end

  defp find_elements_in_frame(parent, frame_object_id, {:xpath, xpath}) do
    session = root_session(parent)

    {:ok, %{"result" => %{"objectId" => array_id}}} =
      CDPClient.send_cdp_command(session, "Runtime.callFunctionOn", %{
        objectId: frame_object_id,
        functionDeclaration: """
        function(expr) {
          var doc = this.contentDocument;
          var result = doc.evaluate(expr, doc, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
          var nodes = [];
          for (var i = 0; i < result.snapshotLength; i++) nodes.push(result.snapshotItem(i));
          return nodes;
        }
        """,
        arguments: [%{value: xpath}],
        returnByValue: false
      })

    extract_elements_from_array(session, parent, array_id)
  end

  defp extract_elements_from_array(session, parent, array_id) do
    {:ok, props} =
      CDPClient.send_cdp_command(session, "Runtime.getProperties", %{
        objectId: array_id,
        ownProperties: true
      })

    ids =
      props["result"]
      |> Enum.filter(fn p ->
        match?({_, ""}, Integer.parse(p["name"] || "")) and
          get_in(p, ["value", "subtype"]) == "node"
      end)
      |> Enum.map(fn p -> get_in(p, ["value", "objectId"]) end)

    CDPClient.send_cdp_command(session, "Runtime.releaseObject", %{objectId: array_id})

    elements =
      Enum.map(ids, fn object_id ->
        %Wallabidi.Element{
          id: object_id,
          bidi_shared_id: object_id,
          parent: parent,
          driver: __MODULE__,
          url: session.session_url
        }
      end)

    {:ok, elements}
  end

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
  def execute_script(session, script, args),
    do: delegate(:execute_script, session, [script, args])

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

    # Use Input.synthesizeScrollGesture which handles viewport resizing/clamping.
    case get_element_center(element) do
      {:ok, {x, y}} ->
        CDPClient.send_cdp_command(session, "Input.synthesizeScrollGesture", %{
          x: trunc(x),
          y: trunc(y),
          xDistance: -x_offset,
          yDistance: -y_offset
        })

        {:ok, nil}

      error ->
        error
    end
  end

  # --- Element geometry ---

  def element_size(element) do
    session = root_session(element)

    result =
      CDPClient.send_cdp_command(session, "Runtime.callFunctionOn", %{
        objectId: element.bidi_shared_id,
        functionDeclaration:
          "function() { var r = this.getBoundingClientRect(); return JSON.stringify([Math.round(r.width), Math.round(r.height)]); }",
        returnByValue: true
      })

    case extract_json_result(result) do
      {:ok, [w, h]} -> {:ok, {w, h}}
      other -> other
    end
  end

  def element_location(element) do
    session = root_session(element)

    result =
      CDPClient.send_cdp_command(session, "Runtime.callFunctionOn", %{
        objectId: element.bidi_shared_id,
        functionDeclaration:
          "function() { var r = this.getBoundingClientRect(); return JSON.stringify([Math.round(r.x), Math.round(r.y)]); }",
        returnByValue: true
      })

    case extract_json_result(result) do
      {:ok, [x, y]} -> {:ok, {x, y}}
      other -> other
    end
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
    caller = self()

    # Spawn a handler that listens for the dialog and handles it.
    # This avoids deadlocking: fun.(session) blocks until dialog is handled.
    handler =
      spawn_link(fn ->
        Wallabidi.Protocol.subscribe(session, :dialog)

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
  def window_handle(session) do
    current = current_target_id(session)
    {:ok, current}
  end

  @impl true
  def window_handles(session) do
    case CDPClient.send_cdp_command(session, "Target.getTargets", %{}) do
      {:ok, %{"targetInfos" => targets}} ->
        ctx_id = session.capabilities[:browser_context_id]

        handles =
          targets
          |> Enum.filter(fn t ->
            t["type"] == "page" && t["browserContextId"] == ctx_id
          end)
          |> Enum.map(fn t -> t["targetId"] end)

        {:ok, handles}

      _ ->
        {:ok, [current_target_id(session)]}
    end
  rescue
    _ -> {:ok, [current_target_id(session)]}
  end

  @impl true
  def focus_window(session, target_id) do
    # Attach to the target and update the session's browsing_context
    cdp_pid = session.bidi_pid

    case CDPClient.send_cdp_command(session, "Target.attachToTarget", %{
           targetId: target_id,
           flatten: true
         }) do
      {:ok, %{"sessionId" => new_session_id}} ->
        # Enable required domains on the new target
        flat_send(cdp_pid, "Page.enable", %{}, new_session_id)
        flat_send(cdp_pid, "Runtime.enable", %{}, new_session_id)
        flat_send(cdp_pid, "DOM.enable", %{}, new_session_id)

        # Store current target info in process dict
        Process.put({:cdp_current_target, session.id}, {target_id, new_session_id})
        {:ok, nil}

      error ->
        error
    end
  rescue
    _ -> {:ok, nil}
  end

  @impl true
  def close_window(session) do
    {target_id, _} = current_target(session)

    CDPClient.send_cdp_command(session, "Target.closeTarget", %{targetId: target_id})

    # Reset to default target
    Process.delete({:cdp_current_target, session.id})
    {:ok, nil}
  rescue
    _ -> {:ok, nil}
  end

  defp current_target_id(session) do
    case Process.get({:cdp_current_target, session.id}) do
      {target_id, _} -> target_id
      nil -> session.capabilities[:target_id]
    end
  end

  defp current_target(session) do
    case Process.get({:cdp_current_target, session.id}) do
      {target_id, sess_id} ->
        {target_id, sess_id}

      nil ->
        {session.capabilities[:target_id], session.browsing_context}
    end
  end

  defp flat_send(cdp_pid, method, params, session_id) do
    WebSocketClient.send_command_flat(cdp_pid, method, params, session_id)
  end

  @impl true
  def maximize_window(_), do: {:ok, nil}

  @impl true
  def get_window_position(_), do: {:ok, %{"x" => 0, "y" => 0}}

  @impl true
  def set_window_position(_, _, _), do: {:ok, nil}

  @impl true
  def focus_frame(session_or_element, %Wallabidi.Element{bidi_shared_id: object_id}) do
    session = root_session(session_or_element)

    # Get the frame's contentDocument and store the element's objectId as
    # the "frame root" in the process dictionary. Subsequent find_elements
    # will scope to this frame via JS.
    case CDPClient.send_cdp_command(session, "Runtime.callFunctionOn", %{
           objectId: object_id,
           functionDeclaration: "function() { return this.contentDocument ? true : false; }",
           returnByValue: true
         }) do
      {:ok, %{"result" => %{"value" => true}}} ->
        # Get the frame's executionContextId via DOM.describeNode + Page.getFrameTree
        push_frame_context(session, object_id)
        {:ok, nil}

      _ ->
        {:error, :no_such_frame}
    end
  end

  def focus_frame(session_or_element, nil) do
    session = root_session(session_or_element)
    clear_frame_context(session)
    {:ok, nil}
  end

  @impl true
  def focus_parent_frame(session_or_element) do
    session = root_session(session_or_element)
    pop_frame_context(session)
    {:ok, nil}
  end

  def focus_default_frame(session_or_element) do
    session = root_session(session_or_element)
    clear_frame_context(session)
    {:ok, nil}
  end

  defp push_frame_context(session, frame_element_object_id) do
    stack = Process.get({:cdp_frame_stack, session.id}, [])
    Process.put({:cdp_frame_stack, session.id}, [frame_element_object_id | stack])
  end

  defp pop_frame_context(session) do
    stack = Process.get({:cdp_frame_stack, session.id}, [])
    Process.put({:cdp_frame_stack, session.id}, tl(stack))
  rescue
    _ -> :ok
  end

  defp clear_frame_context(session) do
    Process.put({:cdp_frame_stack, session.id}, [])
  end

  @doc false
  def frame_stack(session), do: Process.get({:cdp_frame_stack, session.id}, [])

  def cleanup_stale_sessions, do: :ok

  # --- Element helpers ---

  defp root_session(%Session{} = s), do: s
  defp root_session(%Wallabidi.Element{parent: p}), do: root_session(p)

  defp get_element_topleft(%Wallabidi.Element{bidi_shared_id: object_id} = element) do
    session = root_session(element)

    case CDPClient.send_cdp_command(session, "Runtime.callFunctionOn", %{
           objectId: object_id,
           functionDeclaration:
             "function() { var r = this.getBoundingClientRect(); return JSON.stringify({x: r.x, y: r.y}); }",
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
           functionDeclaration:
             "function() { var r = this.getBoundingClientRect(); return JSON.stringify({x: r.x + r.width/2, y: r.y + r.height/2}); }",
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

  defp remote_url do
    Wallabidi.BrowserPaths.chrome_url() || config(:remote_url)
  end

  defp chrome_available? do
    match?({:ok, _}, Wallabidi.BrowserPaths.chrome_path())
  end

  defp config(key, default \\ nil) do
    Application.get_env(:wallabidi, :chrome_cdp, []) |> Keyword.get(key, default)
  end
end
