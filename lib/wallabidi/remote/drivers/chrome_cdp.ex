defmodule Wallabidi.Remote.Drivers.ChromeCDP do
  @moduledoc false

  # Chrome driver over the transport stack. Mirrors `Wallabidi.Remote.Drivers.LightpandaCDP`
  # but launches/connects to a real Chrome browser and creates one
  # `BrowserContext` + `Target` per session, multiplexed over a single
  # shared `WebSocket` (matching Playwright's "one browser, many
  # contexts" model).
  #
  # Differences from V2Driver:
  #
  #   * One shared WebSocket per BEAM (held by the supervisor's
  #     SharedConnection child), reused across every session.
  #   * Per-session `Target.createBrowserContext` + `Target.createTarget`
  #     + `Target.attachToTarget`, returning a `sessionId` that's used
  #     as the routing key (CDP flat-session protocol).
  #   * Teardown disposes the BrowserContext rather than closing the WS.

  use Supervisor

  @behaviour Wallabidi.Driver

  alias Wallabidi.{DependencyError, Element, Metadata, Session}
  alias Wallabidi.Remote.Browser
  alias Wallabidi.Remote.CDP.Client, as: CDPClient
  alias Wallabidi.Remote.Chrome.Server, as: ChromeServer
  alias Wallabidi.Remote.Chrome.SharedConnection
  alias Wallabidi.Remote.Driver.{Orchestrator, Spec}
  alias Wallabidi.Remote.{Transport, WebSocket}
  alias Wallabidi.Remote.Transport.Protocol
  alias Wallabidi.Remote.WireProtocol

  @driver_spec %Spec{
    browser: Browser.Chrome,
    wire_protocol: WireProtocol.CDP,
    patch_url_fallback?: true,
    log_check_interactions?: true,
    log_check_accessors?: false
  }

  @doc false
  def driver_spec, do: @driver_spec

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

  @doc false
  def cleanup_stale_sessions, do: :ok

  # ----- Session lifecycle -----

  @impl true
  def start_session(opts \\ []) do
    caller = Keyword.get(opts, :owner, self())

    with {:ok, acquired} <-
           Transport.SharedWS.acquire(connection: SharedConnection, driver: __MODULE__) do
      user_caps = Keyword.get(opts, :capabilities, %{})

      session_struct = %Session{
        id: "v2-chrome-#{System.unique_integer([:positive])}",
        url: "about:blank",
        session_url: "about:blank",
        driver: __MODULE__,
        bidi_pid: acquired.ws_pid,
        browsing_context: acquired.session_id,
        capabilities: Map.merge(user_caps, acquired.capabilities)
      }

      with {:ok, session} <-
             Transport.start_session_from(acquired, session_struct, owner: caller) do
        # Forward console + exception events to the test caller's
        # mailbox so LogChecker.check_logs! can drain them after each
        # operation. Subscribe at the WebSocket layer so the test
        # process is the direct subscriber (Session normally
        # consumes events itself, but LogChecker reads from the
        # caller's mailbox).
        _ =
          WebSocket.subscribe(
            acquired.ws_pid,
            "Runtime.consoleAPICalled",
            acquired.session_id,
            caller
          )

        _ =
          WebSocket.subscribe(
            acquired.ws_pid,
            "Runtime.exceptionThrown",
            acquired.session_id,
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
      end
    end
  end

  @impl true
  def end_session(%Session{} = session) do
    Protocol.stop(session)
    :ok
  end

  # ----- Driver behaviour delegation (same shape as V2Driver) -----

  @impl true
  def visit(%Session{} = session, url), do: Orchestrator.visit(@driver_spec, session, url)

  @impl true
  def await_patch(%Session{} = session, opts),
    do: Orchestrator.await_patch(@driver_spec, session, opts)

  @impl true
  def current_url(%Session{} = session), do: Orchestrator.current_url(@driver_spec, session)

  @impl true
  def current_path(%Session{} = session), do: Orchestrator.current_path(@driver_spec, session)

  @impl true
  def page_source(%Session{} = session), do: Orchestrator.page_source(@driver_spec, session)

  @impl true
  def page_title(%Session{} = session), do: Orchestrator.page_title(@driver_spec, session)

  @impl true
  def cookies(%Session{} = session), do: Orchestrator.cookies(@driver_spec, session)

  @impl true
  def set_cookie(%Session{} = session, name, value),
    do: Orchestrator.set_cookie(@driver_spec, session, name, value)

  @impl true
  def set_cookie(%Session{} = session, name, value, attrs),
    do: Orchestrator.set_cookie(@driver_spec, session, name, value, attrs)

  @impl true
  def take_screenshot(%Session{} = session), do: Orchestrator.take_screenshot(@driver_spec, session)

  def take_screenshot(%Element{} = element),
    do: Orchestrator.take_screenshot(@driver_spec, element)

  @impl true
  def get_window_size(parent), do: Orchestrator.get_window_size(@driver_spec, parent)

  @impl true
  def set_window_size(parent, w, h),
    do: Orchestrator.set_window_size(@driver_spec, parent, w, h)

  @impl true
  def click(%Element{} = element), do: Orchestrator.click(@driver_spec, element)

  @impl true
  def text(%Element{} = element), do: Orchestrator.text(@driver_spec, element)

  @impl true
  def attribute(%Element{} = element, name),
    do: Orchestrator.attribute(@driver_spec, element, name)

  @impl true
  def displayed(%Element{} = element), do: Orchestrator.displayed(@driver_spec, element)

  @impl true
  def set_value(%Element{} = element, value),
    do: Orchestrator.set_value(@driver_spec, element, value)

  @impl true
  def clear(%Element{} = element), do: Orchestrator.clear(@driver_spec, element)

  def clear(%Element{} = element, _opts), do: Orchestrator.clear(@driver_spec, element)

  @impl true
  def find_elements(parent, query),
    do: Orchestrator.find_elements(@driver_spec, parent, query)

  @impl true
  def execute_script(%Session{} = session, script, args),
    do: Orchestrator.execute_script(@driver_spec, session, script, args)

  @impl true
  def execute_script_async(%Session{} = session, script, args),
    do: Orchestrator.execute_script_async(@driver_spec, session, script, args)

  @impl true
  def send_keys(%Session{} = session, keys) when is_list(keys),
    do: CDPClient.send_keys_to_session(session, keys)

  def send_keys(%Session{} = session, key) when is_binary(key) or is_atom(key),
    do: CDPClient.send_keys_to_session(session, [key])

  def send_keys(%Element{} = element, keys),
    do: Orchestrator.send_keys(@driver_spec, element, keys)

  @impl true
  def selected(%Element{} = element), do: Orchestrator.selected(@driver_spec, element)

  # ----- Mouse/touch/geometry (delegated through Orchestrator) -----

  def hover(%Element{} = element), do: Orchestrator.hover(@driver_spec, element)
  def tap(%Element{} = element), do: Orchestrator.tap(@driver_spec, element)
  def touch_down(parent, target, x, y),
    do: Orchestrator.touch_down(@driver_spec, parent, target, x, y)
  def touch_up(parent), do: Orchestrator.touch_up(@driver_spec, parent)
  def touch_move(parent, x, y), do: Orchestrator.touch_move(@driver_spec, parent, x, y)

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

  def click(parent, button) when button in [:left, :middle, :right],
    do: Orchestrator.click_at_cursor(@driver_spec, parent, button)

  def double_click(parent), do: Orchestrator.double_click(@driver_spec, parent)
  def button_down(parent, button), do: Orchestrator.button_down(@driver_spec, parent, button)
  def button_up(parent, button), do: Orchestrator.button_up(@driver_spec, parent, button)
  def move_mouse_by(parent, x_offset, y_offset),
    do: Orchestrator.move_mouse_by(@driver_spec, parent, x_offset, y_offset)
  def element_size(%Element{} = element), do: Orchestrator.element_size(@driver_spec, element)
  def element_location(%Element{} = element),
    do: Orchestrator.element_location(@driver_spec, element)
  def blank_page?(%Session{} = session), do: Orchestrator.blank_page?(@driver_spec, session)

  # LogChecker calls driver.parse_log/1 on each drained log entry —
  # Wallabidi.Remote.Chrome.Logger raises Wallabidi.JSError on SEVERE entries
  # and prints console output, which is exactly what JSErrorsTest
  # checks for.
  defdelegate parse_log(log), to: Wallabidi.Remote.Chrome.Logger

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
  def window_handle(%Session{pid: pid} = session) when is_pid(pid) do
    # The session struct in the caller's hand may carry a stale
    # target_id (focus_window/2 mutates the live state in the
    # GenServer). Re-fetch the current state.
    case GenServer.call(pid, :get_session) do
      %Session{capabilities: caps} -> {:ok, caps[:target_id]}
      _ -> {:ok, get_in(session.capabilities, [:target_id])}
    end
  catch
    :exit, _ -> {:ok, get_in(session.capabilities, [:target_id])}
  end

  def window_handle(%Session{} = session) do
    {:ok, get_in(session.capabilities, [:target_id])}
  end

  def window_handle(%Element{} = element) do
    window_handle(Element.root_session(element))
  end

  @impl true
  def window_handles(parent) do
    session = Element.root_session(parent)
    ws_pid = session.bidi_pid
    ctx_id = get_in(session.capabilities, [:browser_context_id])

    case WebSocket.send_sync(ws_pid, "Target.getTargets", %{}) do
      {:ok, %{"targetInfos" => targets}} ->
        handles =
          targets
          |> Enum.filter(fn t ->
            t["type"] == "page" && t["browserContextId"] == ctx_id
          end)
          |> Enum.map(fn t -> t["targetId"] end)

        {:ok, handles}

      _ ->
        {:ok, [get_in(session.capabilities, [:target_id])]}
    end
  end

  @impl true
  def focus_window(parent, target_id) when is_binary(target_id) do
    session = Element.root_session(parent)
    ws_pid = session.bidi_pid

    # Switch the Session's CDP target by re-attaching to the new
    # one (gets a new sessionId). Update session.browsing_context so
    # subsequent cdp_send opts route there.
    case WebSocket.send_sync(ws_pid, "Target.attachToTarget", %{
           targetId: target_id,
           flatten: true
         }) do
      {:ok, %{"sessionId" => session_id}} ->
        # Update session struct in the GenServer (the caller's struct
        # may be stale; window_handle/1 re-fetches via :get_session).
        if session.pid do
          GenServer.call(session.pid, {:update_browsing_context, session_id, target_id})
        end

        new_session = %{
          session
          | browsing_context: session_id,
            capabilities: Map.put(session.capabilities, :target_id, target_id)
        }

        # All four setup commands fire-and-forget so they pipeline on
        # the wire instead of round-tripping in series. CDPClient's
        # enable_page_lifecycle_events / install_bootstrap already use
        # cdp_cast internally; the inline IIFE was the last sync send,
        # so cast it too. Subsequent cdp_send calls (e.g. visit) will
        # naturally barrier until all four land.
        _ = CDPClient.enable_page_lifecycle_events(new_session)
        _ = CDPClient.install_bootstrap(new_session)

        # The new tab may have loaded its document BEFORE we attached.
        # Page.addScriptToEvaluateOnNewDocument (queued by
        # install_bootstrap) only fires for *future* documents, so the
        # bootstrap won't be present until the next nav. Run the IIFE
        # inline against the current document so subsequent finds
        # work without needing a reload.
        CDPClient.cdp_cast(new_session, "Runtime.evaluate", %{
          expression: Wallabidi.Remote.Bootstrap.cdp_iife(),
          returnByValue: true
        })

        {:ok, nil}

      err ->
        err
    end
  end

  @impl true
  def close_window(%Session{pid: pid} = session) when is_pid(pid) do
    # The caller's session struct may carry a stale target_id —
    # focus_window/2 mutates the live state in the GenServer. Re-fetch
    # so close_window closes the *currently focused* target, not the
    # one the caller's struct was first built with.
    current =
      try do
        GenServer.call(pid, :get_session)
      catch
        :exit, _ -> session
      end

    target_id = get_in(current.capabilities, [:target_id])
    ws_pid = session.bidi_pid
    _ = WebSocket.send_sync(ws_pid, "Target.closeTarget", %{targetId: target_id})
    {:ok, nil}
  end

  def close_window(%Session{} = session) do
    target_id = get_in(session.capabilities, [:target_id])
    ws_pid = session.bidi_pid
    _ = WebSocket.send_sync(ws_pid, "Target.closeTarget", %{targetId: target_id})
    {:ok, nil}
  end

  def close_window(%Element{} = element), do: close_window(Element.root_session(element))
  @impl true
  def maximize_window(_), do: {:ok, nil}
  @impl true
  def get_window_position(_), do: {:ok, %{"x" => 0, "y" => 0}}
  @impl true
  def set_window_position(_, _, _), do: {:ok, nil}
  @impl true
  def focus_frame(%Session{} = session, %Element{handle: object_id})
      when is_binary(object_id) do
    # Resolve the iframe element's frameId via DOM.describeNode, then
    # ask Session to push the frame's executionContextId so all
    # subsequent script evals target it.
    case CDPClient.cdp_send(session, "DOM.describeNode", %{objectId: object_id}) do
      {:ok, %{"node" => %{"frameId" => frame_id}}} when is_binary(frame_id) ->
        case CDPClient.focus_frame_by_id(session, frame_id) do
          :ok -> {:ok, nil}
          err -> err
        end

      _ ->
        {:ok, nil}
    end
  end

  # Browser.focus_default_frame/1 calls driver.focus_frame(session, nil)
  # to escape all the way out. Reset the frame stack.
  def focus_frame(%Session{pid: pid}, nil) when is_pid(pid) do
    GenServer.call(pid, :reset_frame_stack)
    {:ok, nil}
  end

  def focus_frame(_, _), do: {:ok, nil}

  @impl true
  def focus_parent_frame(%Session{} = session) do
    :ok = CDPClient.focus_parent_frame(session)
    {:ok, nil}
  end

  def focus_parent_frame(_), do: {:ok, nil}

  # ----- Internal -----

  @doc false
  def remote_url do
    Wallabidi.BrowserPaths.chrome_url() ||
      Application.get_env(:wallabidi, :chrome_cdp_v2, []) |> Keyword.get(:remote_url)
  end

  defp chrome_available? do
    match?({:ok, _}, Wallabidi.BrowserPaths.chrome_path())
  end
end
