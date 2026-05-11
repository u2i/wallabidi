defmodule Wallabidi.Remote.Drivers.ChromeBiDi do
  @moduledoc false

  # driver speaking WebDriver-BiDi against a chromium-bidi server.
  #
  # ## Topology
  #
  # The supervisor starts a single chromium-bidi Node server
  # (`Wallabidi.Remote.ChromiumBiDi.Server`) — same singleton model used by
  # `V2Driver` for Lightpanda. Each test session does its own HTTP
  # `POST /session` against that server, then opens the per-session
  # WebSocket the server returns. chromium-bidi spawns a fresh
  # Chrome+Mapper per WS connection, so sessions are isolated by
  # construction — no userContext multiplexing needed.
  #
  # `start_session/1` delegates the bring-up dance (POST + WS upgrade
  # + `browsingContext.create` + bootstrap preload install) to
  # `Transport.BiDi.start_session/1`. Driver callbacks are thin
  # wrappers around `BiDiClient` — same surface as `V2Driver`'s
  # delegation to `CDPClient`, just BiDi-flavored.

  use Supervisor

  @behaviour Wallabidi.Driver

  import Wallabidi.Driver.LogChecker

  alias Wallabidi.{Element, Session}
  alias Wallabidi.Remote.BiDi.Client, as: BiDiClient
  alias Wallabidi.Remote.BiDi.WebSocketClient
  alias Wallabidi.Remote.Transport.BiDi
  alias Wallabidi.Remote.Transport.Protocol

  # ----- Driver supervisor -----

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @bidi_server_name __MODULE__.BidiServer

  @impl Supervisor
  def init(_) do
    children = [
      {Wallabidi.Remote.ChromiumBiDi.Server, [name: @bidi_server_name]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def validate, do: :ok

  @doc false
  def cleanup_stale_sessions, do: :ok

  @doc """
  Default capabilities passed when starting a Chrome session via BiDi.
  """
  def default_capabilities do
    %{
      browserName: "chrome",
      unhandledPromptBehavior: "ignore"
    }
  end

  # ----- Session lifecycle -----

  @impl true
  def start_session(opts \\ []) do
    base_url = resolve_base_url(opts)

    session_struct = %Session{
      id: "v2bidi-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      driver: __MODULE__,
      protocol: nil,
      browsing_context: nil,
      capabilities: Keyword.get(opts, :capabilities, %{}) |> Map.new()
    }

    with {:ok, session} <-
           BiDi.start_session(
             base_url: base_url,
             session_struct: session_struct,
             owner: Keyword.get(opts, :owner, self())
           ) do
      # Forward log.entryAdded events to the test process's mailbox
      # so LogChecker.check_logs! can drain them after operations.
      # The server-side session.subscribe is set up by SessionActor;
      # we just register the test process as an additional WSC-side
      # subscriber so the events fan out to the test mailbox too.
      caller = Keyword.get(opts, :owner, self())
      _ = WebSocketClient.subscribe(session.bidi_pid, "log.entryAdded", caller, :global)

      if window_size = Keyword.get(opts, :window_size) do
        _ = BiDiClient.set_viewport(session, window_size[:width], window_size[:height])
      end

      {:ok, session}
    end
  end

  defp resolve_base_url(opts) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) ->
        url

      _ ->
        # Convert the BidiServer's WS URL to its HTTP equivalent —
        # they share the host/port; chromium-bidi serves both.
        ws_url = bidi_ws_url_with_retry(5)

        ws_url
        |> URI.parse()
        |> Map.put(:scheme, "http")
        |> Map.put(:path, nil)
        |> URI.to_string()
    end
  end

  # The supervised BidiServer process can crash mid-suite (chromium-bidi
  # Node process exits non-zero; OOM on CI runners is the most common
  # cause). The one_for_one Supervisor restarts it, but there's a
  # short window where GenServer.call(@bidi_server_name, _) exits with
  # :noproc or {:bidi_server_exit, _} before the new pid registers
  # under the name. Retry with a small backoff to ride out the gap.
  defp bidi_ws_url_with_retry(0) do
    Wallabidi.Remote.ChromiumBiDi.Server.ws_url(@bidi_server_name)
  end

  defp bidi_ws_url_with_retry(retries_left) do
    Wallabidi.Remote.ChromiumBiDi.Server.ws_url(@bidi_server_name)
  catch
    :exit, _ ->
      Process.sleep(500)
      bidi_ws_url_with_retry(retries_left - 1)
  end

  @impl true
  def end_session(%Session{} = session) do
    Protocol.stop(session)
    :ok
  end

  # ----- Session-scoped callbacks -----

  @impl true
  def visit(%Session{} = session, url) do
    result = check_logs!(session, fn -> BiDiClient.visit(session, url) end)
    _ = await_liveview_connected_v2(session)
    result
  end

  # Mirrors V2ChromeDriver.await_liveview_connected_v2/1 and
  # V2Driver.await_liveview_connected_v2/1 — wait up to 5s for
  # liveSocket.main.joinPending === false on LV pages. Without this,
  # post-visit interactions can race the channel-join.
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

    _ = Wallabidi.Remote.BiDi.Client.evaluate_async(session, js)
    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def current_url(%Session{} = session) do
    check_logs!(session, fn -> BiDiClient.current_url(session) end)
  end

  @impl true
  def current_path(%Session{} = session), do: BiDiClient.current_path(session)

  @impl true
  def page_source(%Session{} = session), do: BiDiClient.page_source(session)

  @impl true
  def page_title(%Session{} = session) do
    check_logs!(session, fn -> BiDiClient.page_title(session) end)
  end

  @impl true
  def execute_script(%Session{} = session, script, args),
    do: BiDiClient.evaluate(session, script, args || [])

  @impl true
  def execute_script_async(%Session{} = session, script, args),
    do: BiDiClient.evaluate_async(session, script, args || [])

  # ----- Element-scoped callbacks -----

  @impl true
  def click(%Element{} = element) do
    session = Element.root_session(element)

    check_logs!(session, fn ->
      case BiDiClient.click_aware_with_classification(session, element) do
        {:ok, _classification, :ready} ->
          {:ok, nil}

        {:ok, "navigate", :timeout} ->
          # data-phx-link=redirect / JS.navigate-classified clicks raise
          # NavigationTimeoutError on page_ready timeout — those tests
          # explicitly catch the error.
          raise_navigation_timeout(session, 5_000)

        {:ok, "full_page", :timeout} ->
          raise_navigation_timeout(session, 5_000)

        {:ok, _classification, :timeout} ->
          # patch / none — silent fallback. Caller's assert_has retries
          # handle the slow case via max_wait_time polling.
          {:ok, nil}

        err ->
          err
      end
    end)
  end

  defp raise_navigation_timeout(%Session{} = session, timeout_ms) do
    post =
      case BiDiClient.current_url(session) do
        {:ok, url} -> url
        _ -> nil
      end

    raise Wallabidi.NavigationTimeoutError, %{
      from: nil,
      to: post,
      timeout_ms: timeout_ms,
      page_state: :unknown,
      page_state_history: []
    }
  end

  @impl true
  def text(%Element{} = element) do
    BiDiClient.text(Element.root_session(element), element)
  end

  @impl true
  def attribute(%Element{} = element, name) do
    BiDiClient.attribute(Element.root_session(element), element, name)
  end

  @impl true
  def displayed(%Element{} = element) do
    BiDiClient.displayed(Element.root_session(element), element)
  end

  @impl true
  def set_value(%Element{} = element, value) do
    BiDiClient.set_value(Element.root_session(element), element, value)
  end

  @impl true
  def clear(%Element{} = element) do
    BiDiClient.clear(Element.root_session(element), element)
  end

  def clear(%Element{} = element, opts) do
    BiDiClient.clear(Element.root_session(element), element, opts)
  end

  @impl true
  def find_elements(parent, query) do
    %Wallabidi.Query{} = q = ensure_query(query)
    BiDiClient.find_elements(parent, q)
  end

  @impl true
  def send_keys(%Session{} = session, keys) when is_list(keys) do
    BiDiClient.send_keys_to_session(session, keys)
  end

  def send_keys(%Element{} = element, keys) do
    BiDiClient.send_keys(Element.root_session(element), element, keys)
  end

  @impl true
  def selected(%Element{} = element) do
    BiDiClient.call_on_element(
      Element.root_session(element),
      element,
      Wallabidi.Remote.OpsShared.dispatch_fn(),
      [[["is_selected"]]]
    )
  end

  # ----- Mouse / touch / geometry -----

  def hover(%Element{} = element), do: BiDiClient.hover(element)
  def tap(%Element{} = element), do: BiDiClient.tap(element)

  def touch_down(parent, target, x, y),
    do: BiDiClient.touch_down(Element.root_session(parent), target, x, y)

  def touch_up(parent), do: BiDiClient.touch_up(parent)
  def touch_move(parent, x, y), do: BiDiClient.touch_move(parent, x, y)

  def touch_scroll(%Element{} = element, x_offset, y_offset) do
    # Use JS scrollBy — touch pointer actions don't reliably trigger
    # scroll in headless Chrome. Same workaround the legacy driver uses.
    case BiDiClient.call_on_element(
           Element.root_session(element),
           element,
           "function(dx, dy) { this.scrollIntoView(); window.scrollBy(dx, dy); return null; }",
           [x_offset, y_offset]
         ) do
      {:ok, _} -> {:ok, nil}
      err -> err
    end
  end

  def click(parent, button) when button in [:left, :middle, :right],
    do: BiDiClient.click_at_cursor(parent, button)

  def double_click(parent), do: BiDiClient.double_click(parent)
  def button_down(parent, button), do: BiDiClient.button_down(parent, button)
  def button_up(parent, button), do: BiDiClient.button_up(parent, button)

  def move_mouse_by(parent, x_offset, y_offset),
    do: BiDiClient.move_mouse_by(parent, x_offset, y_offset)

  def element_size(%Element{} = element), do: BiDiClient.element_size(element)
  def element_location(%Element{} = element), do: BiDiClient.element_location(element)

  def blank_page?(%Session{} = session) do
    case BiDiClient.current_url(session) do
      {:ok, url} -> url in ["about:blank", ""]
      _ -> false
    end
  end

  # LogChecker calls driver.parse_log/1 on each drained log entry.
  # Wallabidi.Remote.Chrome.Logger raises Wallabidi.JSError on SEVERE entries
  # and prints console output — same shape both BiDi and Chrome
  # CDP need.
  defdelegate parse_log(log), to: Wallabidi.Remote.Chrome.Logger

  # ----- Cookies / screenshot / window — not implemented yet -----

  @impl true
  def cookies(%Session{} = session), do: BiDiClient.cookies(session)

  @impl true
  def set_cookie(%Session{} = session, name, value),
    do: cookie_result(BiDiClient.set_cookie(session, name, value))

  @impl true
  def set_cookie(%Session{} = session, name, value, attrs),
    do: cookie_result(BiDiClient.set_cookie(session, name, value, Map.new(attrs)))

  defp cookie_result({:ok, _}), do: {:ok, nil}
  defp cookie_result(other), do: other

  @impl true
  def take_screenshot(%Session{} = session) do
    case BiDiClient.take_screenshot(session) do
      {:ok, binary} -> binary
      _ -> ""
    end
  end

  def take_screenshot(%Element{} = element) do
    take_screenshot(Element.root_session(element))
  end

  @impl true
  def get_window_size(%Session{} = session) do
    case BiDiClient.get_viewport(session) do
      {:ok, %{width: w, height: h}} -> {:ok, %{"width" => w, "height" => h}}
      other -> other
    end
  end

  @impl true
  def set_window_size(%Session{} = session, w, h),
    do: BiDiClient.set_viewport(session, w, h)

  # ----- Dialog stubs -----

  @impl true
  def accept_alert(%Session{} = session, fun), do: BiDiClient.accept_alert(session, fun)

  @impl true
  def accept_confirm(%Session{} = session, fun), do: BiDiClient.accept_confirm(session, fun)

  @impl true
  def accept_prompt(%Session{} = session, text, fun),
    do: BiDiClient.accept_prompt(session, text, fun)

  @impl true
  def dismiss_confirm(%Session{} = session, fun), do: BiDiClient.dismiss_confirm(session, fun)

  @impl true
  def dismiss_prompt(%Session{} = session, fun), do: BiDiClient.dismiss_prompt(session, fun)

  # ----- Window / frame stubs -----

  # The "handle" in BiDi is just the top-level browsing-context id.
  # Tracking which one is "focused" is a per-test concern handled
  # via the same process-dictionary override frames use.

  @impl true
  def window_handle(%Session{} = session) do
    {:ok, current_window(session)}
  end

  @impl true
  def window_handles(%Session{} = session) do
    BiDiClient.window_handles(session)
  end

  @impl true
  def focus_window(%Session{} = session, handle) when is_binary(handle) do
    Process.put({:wallabidi_bidi_v2_window, session.id}, handle)
    # Reset frame state: switching tabs invalidates iframe focus.
    Process.delete({:wallabidi_bidi_v2_frame_stack, session.id})
    Process.put({:wallabidi_bidi_v2_frame, session.id}, handle)
    {:ok, nil}
  end

  @impl true
  def close_window(%Session{} = session) do
    handle = current_window(session)

    case BiDiClient.close_window(session, handle) do
      :ok ->
        Process.delete({:wallabidi_bidi_v2_window, session.id})
        Process.delete({:wallabidi_bidi_v2_frame, session.id})
        Process.delete({:wallabidi_bidi_v2_frame_stack, session.id})
        {:ok, nil}

      err ->
        err
    end
  end

  defp current_window(%Session{id: id, browsing_context: root}) do
    Process.get({:wallabidi_bidi_v2_window, id}, root)
  end

  @impl true
  def maximize_window(_), do: {:ok, nil}

  @impl true
  def get_window_position(_), do: {:ok, %{"x" => 0, "y" => 0}}

  @impl true
  def set_window_position(_, _, _), do: {:ok, nil}

  @impl true
  def focus_frame(%Session{} = session, %Element{} = iframe) do
    case BiDiClient.child_context_for_iframe(session, iframe) do
      {:ok, child_ctx} ->
        # Push the current context onto the per-test frame stack so
        # focus_parent_frame can pop back. The override is read by
        # BiDiClient.ctx/1 on every BiDi op — find/click/evaluate
        # all retarget to the focused iframe automatically.
        stack = Process.get({:wallabidi_bidi_v2_frame_stack, session.id}, [])
        current = current_ctx(session)
        Process.put({:wallabidi_bidi_v2_frame_stack, session.id}, [current | stack])
        Process.put({:wallabidi_bidi_v2_frame, session.id}, child_ctx)
        # Browser.in_frame? checks for this proc-dict key to skip the
        # click_aware fast path (legacy behavior — frame-scoped
        # clicks don't go through bootstrap).
        Process.put({:wallabidi_frame_context, session.id}, child_ctx)
        {:ok, nil}

      _ ->
        {:ok, nil}
    end
  end

  # Browser.focus_default_frame/1 calls driver.focus_frame(session, nil)
  # to escape all the way out — clear the frame stack + override.
  def focus_frame(%Session{} = session, nil) do
    Process.delete({:wallabidi_bidi_v2_frame_stack, session.id})
    Process.delete({:wallabidi_bidi_v2_frame, session.id})
    Process.delete({:wallabidi_frame_context, session.id})
    {:ok, nil}
  end

  def focus_frame(_, _), do: {:ok, nil}

  @impl true
  def focus_parent_frame(%Session{} = session) do
    case Process.get({:wallabidi_bidi_v2_frame_stack, session.id}, []) do
      [] ->
        # Already at root.
        {:ok, nil}

      [parent_ctx | rest] ->
        Process.put({:wallabidi_bidi_v2_frame_stack, session.id}, rest)

        if rest == [] and parent_ctx == session.browsing_context do
          Process.delete({:wallabidi_bidi_v2_frame, session.id})
          Process.delete({:wallabidi_frame_context, session.id})
        else
          Process.put({:wallabidi_bidi_v2_frame, session.id}, parent_ctx)
          Process.put({:wallabidi_frame_context, session.id}, parent_ctx)
        end

        {:ok, nil}
    end
  end

  def focus_parent_frame(_), do: {:ok, nil}

  defp current_ctx(%Session{id: id, browsing_context: root}) do
    Process.get({:wallabidi_bidi_v2_frame, id}, root)
  end

  # ----- Internal -----

  defp ensure_query(%Wallabidi.Query{} = q), do: q

  defp ensure_query({type, selector}) when type in [:css, :xpath] and is_binary(selector) do
    Wallabidi.Query.css(selector)
  end
end
