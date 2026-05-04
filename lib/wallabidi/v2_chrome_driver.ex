defmodule Wallabidi.V2ChromeDriver do
  @moduledoc false

  # Chrome driver over the V2 transport stack. Mirrors `Wallabidi.V2Driver`
  # but launches/connects to a real Chrome browser and creates one
  # `BrowserContext` + `Target` per session, multiplexed over a single
  # shared `V2.WebSocket` (matching Playwright's "one browser, many
  # contexts" model).
  #
  # Differences from V2Driver:
  #
  #   * One shared V2.WebSocket per BEAM (held by the supervisor's
  #     SharedConnection child), reused across every session.
  #   * Per-session `Target.createBrowserContext` + `Target.createTarget`
  #     + `Target.attachToTarget`, returning a `sessionId` that's used
  #     as the V2 routing key (CDP flat-session protocol).
  #   * Teardown disposes the BrowserContext rather than closing the WS.

  use Supervisor

  @behaviour Wallabidi.Driver

  alias Wallabidi.{DependencyError, Element, Metadata, Session}
  alias Wallabidi.Chrome.Server, as: ChromeServer
  alias Wallabidi.V2.CDPClient
  alias Wallabidi.V2.Session, as: V2Session
  alias Wallabidi.V2.WebSocket
  alias Wallabidi.V2Chrome.SharedConnection
  import Wallabidi.Driver.LogChecker

  @base_user_agent "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"

  # ----- Supervisor -----

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl Supervisor
  def init(_) do
    children =
      if remote_url() do
        [SharedConnection]
      else
        [{ChromeServer, [name: __MODULE__.Server]}, SharedConnection]
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def validate do
    cond do
      remote_url() -> :ok
      chrome_available?() -> :ok
      true ->
        {:error,
         DependencyError.exception(
           "Chrome not found. Run `mix wallabidi.install` or set WALLABIDI_CHROME_URL."
         )}
    end
  end

  @doc false
  def cleanup_stale_sessions, do: :ok

  # ----- Session lifecycle -----

  @impl true
  def start_session(opts \\ []) do
    ws_pid = SharedConnection.get(__MODULE__)

    with {:ok, %{"browserContextId" => ctx_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createBrowserContext", %{}),
         {:ok, %{"targetId" => target_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createTarget", %{
             url: "about:blank",
             browserContextId: ctx_id
           }),
         {:ok, %{"sessionId" => session_id}} <-
           WebSocket.send_sync(ws_pid, "Target.attachToTarget", %{
             targetId: target_id,
             flatten: true
           }) do
      user_caps = Keyword.get(opts, :capabilities, %{})

      session_struct = %Session{
        id: "v2-chrome-#{System.unique_integer([:positive])}",
        url: "about:blank",
        session_url: "about:blank",
        driver: __MODULE__,
        protocol: nil,
        bidi_pid: ws_pid,
        browsing_context: session_id,
        capabilities:
          Map.merge(user_caps, %{
            target_id: target_id,
            browser_context_id: ctx_id,
            flat_session_id: true,
            shared_connection: true
          })
      }

      teardown = fn _session -> teardown_browser_context(ws_pid, ctx_id) end

      caller = Keyword.get(opts, :owner, self())

      case V2Session.start_link(
             ws_pid: ws_pid,
             init_fun: fn -> {:ok, session_struct} end,
             teardown_fun: teardown,
             owner: caller
           ) do
        {:ok, session} ->
          :ok = CDPClient.enable_page_lifecycle_events(session)
          :ok = CDPClient.install_bootstrap(session)
          :ok = CDPClient.enable_frame_tracking(session)

          # Forward console + exception events to the test caller's
          # mailbox so LogChecker.check_logs! can drain them after each
          # operation. Subscribe at the V2.WebSocket layer so the test
          # process is the direct subscriber (V2.Session normally
          # consumes events itself, but LogChecker reads from the
          # caller's mailbox).
          _ =
            WebSocket.subscribe(
              ws_pid,
              "Runtime.consoleAPICalled",
              session_id,
              caller
            )

          _ =
            WebSocket.subscribe(
              ws_pid,
              "Runtime.exceptionThrown",
              session_id,
              caller
            )

          if metadata = Keyword.get(opts, :metadata) do
            ua = Metadata.append(@base_user_agent, metadata)
            _ = CDPClient.cdp_send(session, "Network.setUserAgentOverride", %{userAgent: ua})
          end

          if window_size = Keyword.get(opts, :window_size) do
            _ = CDPClient.set_window_size(session, window_size[:width], window_size[:height])
          end

          {:ok, session}

        error ->
          teardown_browser_context(ws_pid, ctx_id)
          error
      end
    end
  end

  @impl true
  def end_session(%Session{} = session) do
    V2Session.stop(session)
    :ok
  end

  @impl true
  def release_server_session(%Session{} = session) do
    ws_pid = session.bidi_pid
    ctx_id = get_in(session.capabilities, [:browser_context_id])
    if ws_pid && ctx_id, do: teardown_browser_context(ws_pid, ctx_id)
    :ok
  end

  defp teardown_browser_context(ws_pid, ctx_id) do
    try do
      WebSocket.send_sync(ws_pid, "Target.disposeBrowserContext", %{
        browserContextId: ctx_id
      })
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  # ----- Driver behaviour delegation (same shape as V2Driver) -----

  @impl true
  def visit(%Session{} = session, url) do
    check_logs!(session, fn ->
      result = CDPClient.visit(session, url)
      _ = await_liveview_connected_v2(session)
      result
    end)
  end

  # V2 equivalent of LiveViewAware.await_liveview_connected/2 that
  # doesn't depend on Wallabidi.Protocol (V2 sessions have
  # protocol: nil). Returns quickly when no LiveView marker is in the
  # DOM; otherwise polls liveSocket.main.joinPending up to `timeout`.
  defp await_liveview_connected_v2(%Session{} = session) do
    timeout = 5_000

    js = """
    new Promise(function(resolve) {
      var deadline = Date.now() + #{timeout};
      function check() {
        if (document.readyState === 'loading') {
          if (Date.now() > deadline) return resolve(false);
          return setTimeout(check, 20);
        }
        if (!document.querySelector('[data-phx-session]')) {
          return resolve('no-liveview');
        }
        var ls = window.liveSocket;
        if (ls && ls.main && !ls.main.joinPending) return resolve(true);
        if (Date.now() > deadline) return resolve(false);
        setTimeout(check, 30);
      }
      check();
    })
    """

    _ =
      CDPClient.cdp_send(session, "Runtime.evaluate", %{
        expression: js,
        awaitPromise: true,
        returnByValue: true
      })

    :ok
  end

  @impl true
  def current_url(%Session{} = session), do: CDPClient.current_url(session)

  @impl true
  def current_path(%Session{} = session), do: CDPClient.current_path(session)

  @impl true
  def page_source(%Session{} = session), do: CDPClient.page_source(session)

  @impl true
  def page_title(%Session{} = session), do: CDPClient.page_title(session)

  @impl true
  def cookies(%Session{} = session), do: CDPClient.cookies(session)

  @impl true
  def set_cookie(%Session{} = session, name, value),
    do: cookie_result(CDPClient.set_cookie(session, name, value))

  @impl true
  def set_cookie(%Session{} = session, name, value, attrs),
    do: cookie_result(CDPClient.set_cookie(session, name, value, Map.new(attrs)))

  defp cookie_result({:ok, _}), do: {:ok, nil}
  defp cookie_result(other), do: other

  @impl true
  def take_screenshot(%Session{} = session) do
    # Browser.take_screenshot expects a raw binary (not {:ok, binary}).
    case CDPClient.take_screenshot(session) do
      {:ok, binary} -> binary
      _ -> ""
    end
  end

  @impl true
  def get_window_size(%Session{} = parent) do
    case CDPClient.get_window_size(Element.root_session(parent)) do
      {:ok, %{width: w, height: h}} -> {:ok, %{"width" => w, "height" => h}}
      other -> other
    end
  end

  @impl true
  def set_window_size(%Session{} = parent, w, h),
    do: CDPClient.set_window_size(Element.root_session(parent), w, h)

  @impl true
  def click(%Element{} = element) do
    session = Element.root_session(element)

    check_logs!(session, fn ->
      # click_aware does pre_page_id capture + classify + click + page_ready
      # await, which is what tests like ClickButton (form submit -> nav)
      # expect. For non-navigating clicks classification is "none" and the
      # await is skipped.
      case CDPClient.click_aware(session, element) do
        {:ok, _classification} -> {:ok, nil}
        err -> err
      end
    end)
  end

  @impl true
  def text(%Element{} = element),
    do: CDPClient.text(Element.root_session(element), element)

  @impl true
  def attribute(%Element{} = element, name),
    do: CDPClient.attribute(Element.root_session(element), element, name)

  @impl true
  def displayed(%Element{} = element),
    do: CDPClient.displayed(Element.root_session(element), element)

  @impl true
  def set_value(%Element{} = element, value),
    do: CDPClient.set_value(Element.root_session(element), element, value)

  @impl true
  def clear(%Element{} = element),
    do: CDPClient.clear(Element.root_session(element), element)

  # Element.fill_in/2 calls driver.clear(element, silent: true) — the
  # silent flag suppresses input events. Implementation-wise it's a
  # plain clear; the events will get dispatched via the subsequent
  # set_value.
  def clear(%Element{} = element, _opts),
    do: CDPClient.clear(Element.root_session(element), element)

  @impl true
  def find_elements(parent, query) do
    %Wallabidi.Query{} = q = ensure_query(query)
    CDPClient.find_elements(parent, q)
  end

  @impl true
  def execute_script(%Session{} = session, script, args),
    do: CDPClient.evaluate(session, script, args || [])

  @impl true
  def execute_script_async(%Session{} = session, script, args),
    do: CDPClient.evaluate_async(session, script, args || [])

  @impl true
  def send_keys(%Session{} = session, keys) when is_list(keys),
    do: CDPClient.send_keys_to_session(session, keys)

  def send_keys(%Session{} = session, key) when is_binary(key) or is_atom(key),
    do: CDPClient.send_keys_to_session(session, [key])

  def send_keys(%Element{} = element, keys),
    do: CDPClient.send_keys(Element.root_session(element), element, keys)

  @impl true
  def selected(%Element{} = element) do
    # `selected?` semantics: true iff the input/option is currently
    # checked/selected. The browser DOM property (`.checked` or
    # `.selected`) is the source of truth; the HTML *attribute* may
    # not reflect later state changes.
    case CDPClient.cdp_send(Element.root_session(element), "Runtime.callFunctionOn", %{
           objectId: element.bidi_shared_id,
           functionDeclaration:
             "function() { return this.checked === true || this.selected === true; }",
           returnByValue: true
         }) do
      {:ok, %{"result" => %{"value" => v}}} -> {:ok, v == true}
      err -> err
    end
  end

  # ----- Mouse/touch/geometry (delegated to V2.CDPClient helpers) -----

  def hover(%Element{} = element), do: CDPClient.hover(element)

  def tap(%Element{} = element), do: CDPClient.tap(element)

  def touch_down(parent, target, x, y) do
    CDPClient.touch_down(Element.root_session(parent), target, x, y)
  end

  def touch_up(parent), do: CDPClient.touch_up(parent)

  def touch_move(parent, x, y), do: CDPClient.touch_move(parent, x, y)

  def touch_scroll(%Element{} = element, x_offset, y_offset) do
    session = Element.root_session(element)

    case CDPClient.element_location(element) do
      {:ok, _} ->
        # Reuse Input.synthesizeScrollGesture from cdp_send.
        CDPClient.cdp_send(session, "Input.synthesizeScrollGesture", %{
          x: 0,
          y: 0,
          xDistance: -x_offset,
          yDistance: -y_offset
        })

        {:ok, nil}

      err ->
        err
    end
  end

  def click(parent, button) when button in [:left, :middle, :right] do
    CDPClient.click_at_cursor(parent, button)
  end

  def double_click(parent), do: CDPClient.double_click(parent)
  def button_down(parent, button), do: CDPClient.button_down(parent, button)
  def button_up(parent, button), do: CDPClient.button_up(parent, button)

  def move_mouse_by(parent, x_offset, y_offset),
    do: CDPClient.move_mouse_by(parent, x_offset, y_offset)

  def element_size(%Element{} = element), do: CDPClient.element_size(element)

  def element_location(%Element{} = element), do: CDPClient.element_location(element)

  def blank_page?(%Session{} = session), do: CDPClient.blank_page?(session)

  # LogChecker calls driver.parse_log/1 on each drained log entry —
  # Wallabidi.Chrome.Logger raises Wallabidi.JSError on SEVERE entries
  # and prints console output, which is exactly what JSErrorsTest
  # checks for.
  defdelegate parse_log(log), to: Wallabidi.Chrome.Logger

  # ----- Dialog handling (uses Page.handleJavaScriptDialog) -----
  @impl true
  def accept_alert(%Session{} = s, fun), do: CDPClient.handle_dialog(s, fun, true)

  @impl true
  def accept_confirm(%Session{} = s, fun), do: CDPClient.handle_dialog(s, fun, true)

  @impl true
  def accept_prompt(%Session{} = s, text, fun),
    do: CDPClient.handle_dialog(s, fun, true, text)

  @impl true
  def dismiss_confirm(%Session{} = s, fun), do: CDPClient.handle_dialog(s, fun, false)

  @impl true
  def dismiss_prompt(%Session{} = s, fun), do: CDPClient.handle_dialog(s, fun, false)
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

  # ----- Internal -----

  defp ensure_query(%Wallabidi.Query{} = q), do: q

  defp ensure_query({type, selector}) when type in [:css, :xpath] and is_binary(selector) do
    Wallabidi.Query.css(selector)
  end

  @doc false
  def remote_url do
    Wallabidi.BrowserPaths.chrome_url() ||
      (Application.get_env(:wallabidi, :chrome_cdp_v2, []) |> Keyword.get(:remote_url))
  end

  defp chrome_available? do
    match?({:ok, _}, Wallabidi.BrowserPaths.chrome_path())
  end
end
