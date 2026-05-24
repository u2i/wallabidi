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

  alias Wallabidi.{Element, Session}
  alias Wallabidi.Remote.BiDi.Client, as: BiDiClient
  alias Wallabidi.Remote.BiDi.WebSocketClient
  alias Wallabidi.Remote.Browser
  alias Wallabidi.Remote.Driver.{Orchestrator, Spec}
  alias Wallabidi.Remote.Transport.BiDi
  alias Wallabidi.Remote.Transport.Protocol
  alias Wallabidi.Remote.WireProtocol

  @driver_spec %Spec{
    browser: Browser.Chrome,
    wire_protocol: WireProtocol.BiDi,
    patch_url_fallback?: false,
    log_check_interactions?: true,
    log_check_accessors?: true
  }

  @doc false
  def driver_spec, do: @driver_spec

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
  def execute_script(%Session{} = session, script, args),
    do: Orchestrator.execute_script(@driver_spec, session, script, args)

  @impl true
  def execute_script_async(%Session{} = session, script, args),
    do: Orchestrator.execute_script_async(@driver_spec, session, script, args)

  # ----- Element-scoped callbacks -----

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

  # ChromeBiDi historically passed `opts` through to BiDiClient.clear/3
  # whereas CDP drivers ignore it. Preserve that here by going through
  # BiDiClient directly for the silent path.
  def clear(%Element{} = element, opts) do
    BiDiClient.clear(Element.root_session(element), element, opts)
  end

  @impl true
  def find_elements(parent, query),
    do: Orchestrator.find_elements(@driver_spec, parent, query)

  @impl true
  def send_keys(%Session{} = session, keys) when is_list(keys) do
    BiDiClient.send_keys_to_session(session, keys)
  end

  def send_keys(%Element{} = element, keys),
    do: Orchestrator.send_keys(@driver_spec, element, keys)

  @impl true
  def selected(%Element{} = element), do: Orchestrator.selected(@driver_spec, element)

  # ----- Mouse / touch / geometry -----

  def hover(%Element{} = element), do: Orchestrator.hover(@driver_spec, element)
  def tap(%Element{} = element), do: Orchestrator.tap(@driver_spec, element)

  def touch_down(parent, target, x, y),
    do: Orchestrator.touch_down(@driver_spec, parent, target, x, y)

  def touch_up(parent), do: Orchestrator.touch_up(@driver_spec, parent)
  def touch_move(parent, x, y), do: Orchestrator.touch_move(@driver_spec, parent, x, y)

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

  # LogChecker calls driver.parse_log/1 on each drained log entry.
  # Wallabidi.Remote.Chrome.Logger raises Wallabidi.JSError on SEVERE entries
  # and prints console output — same shape both BiDi and Chrome
  # CDP need.
  defdelegate parse_log(log), to: Wallabidi.Remote.Chrome.Logger

  # ----- Cookies / screenshot / window — not implemented yet -----

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

end
