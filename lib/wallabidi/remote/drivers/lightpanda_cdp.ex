defmodule Wallabidi.Remote.Drivers.LightpandaCDP do
  @moduledoc false

  # Lightpanda driver speaking CDP over the wallabidi transport stack
  # (WebSocket + Session + CDPClient).
  #
  # `start_session/1` brings up a `Lightpanda.Server`, opens a
  # `WebSocket` to it, attaches a CDP target, and boots a `Session`.
  # Pass `:ws_url` in opts to point at a different CDP-speaking
  # browser.

  use Supervisor

  @behaviour Wallabidi.Driver

  alias Wallabidi.{Element, Session}
  alias Wallabidi.Remote.Browser
  alias Wallabidi.Remote.CDP.Client, as: CDPClient
  alias Wallabidi.Remote.Driver.{Orchestrator, Spec}
  alias Wallabidi.Remote.Transport
  alias Wallabidi.Remote.Transport.Protocol
  alias Wallabidi.Remote.WireProtocol

  @driver_spec %Spec{
    browser: Browser.Lightpanda,
    wire_protocol: WireProtocol.CDP,
    patch_url_fallback?: false,
    log_check_interactions?: false,
    log_check_accessors?: false
  }

  @doc false
  def driver_spec, do: @driver_spec

  # ----- Driver supervisor —
  #
  # Starts a single shared Lightpanda binary if the package is on
  # the load path. Sessions multiplex over this binary by opening
  # their own WebSocket against its URL — the `Transport.PerSession`
  # model, where each session's WS lives inside a `PerSession.Actor`.
  #
  # Falls back to per-session binary spawn (`Transport.IsolatedProcess`)
  # if no shared server is running. Useful for ad-hoc tests that hit
  # the driver directly without going through the application supervisor.
  # -----

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

  @lightpanda_server Module.concat([Lightpanda, Server])
  @lightpanda_server_name __MODULE__.LightpandaServer

  # Lightpanda's --cdp-max-connections defaults to 16, which gets hit
  # at mc=16 plus a few session-isolation tests creating extra
  # sessions. Bump it so the shared-binary PerSession model can run
  # safely at peak ExUnit concurrency. Higher values (e.g. 64) caused
  # measurable per-session slowdown in benchmarks, so we keep this
  # as low as it can go while still passing the suite.
  @cdp_max_connections 24

  @impl Supervisor
  def init(_) do
    children =
      if Code.ensure_loaded?(@lightpanda_server) do
        opts = [
          name: @lightpanda_server_name,
          extra_args: [
            "--cdp-max-connections",
            Integer.to_string(@cdp_max_connections)
          ]
        ]

        [{@lightpanda_server, opts}]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def validate, do: :ok

  @doc false
  def cleanup_stale_sessions, do: :ok

  # ----- Session lifecycle -----

  @impl true
  def start_session(opts \\ []) do
    case pick_transport(opts) do
      {:per_session, ws_url} ->
        # Single-actor-per-session — actor IS the WebSocket. One hop
        # per CDP call. See Transport.PerSession.
        start_per_session(opts, ws_url)

      {transport_mod, transport_opts} ->
        # Two-actor shape: separate WebSocket (acquired by the
        # transport) + Session linked to it. SharedWS / IsolatedProcess.
        start_legacy(opts, transport_mod, transport_opts)
    end
  end

  defp start_per_session(opts, ws_url) do
    session_struct = %Session{
      id: "v2drv-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      driver: __MODULE__,
      browsing_context: nil,
      capabilities: %{
        flat_session_id: true,
        # Lightpanda's JS engine doesn't ship a real document.evaluate
        # — CDPClient.visit injects wgxpath after each page load.
        needs_xpath_polyfill: true
      }
    }

    with {:ok, session} <-
           Transport.PerSession.start_session(
             ws_url: ws_url,
             session_struct: session_struct,
             owner: Keyword.get(opts, :owner, self())
           ) do
      if window_size = Keyword.get(opts, :window_size) do
        _ =
          CDPClient.set_window_size(
            session,
            window_size[:width],
            window_size[:height]
          )
      end

      {:ok, session}
    end
  end

  defp start_legacy(opts, transport_mod, transport_opts) do
    with {:ok, acquired} <- transport_mod.acquire(transport_opts) do
      session_struct = %Session{
        id: "v2drv-#{System.unique_integer([:positive])}",
        url: "about:blank",
        session_url: "about:blank",
        driver: __MODULE__,
        bidi_pid: acquired.ws_pid,
        browsing_context: acquired.session_id,
        capabilities: acquired.capabilities
      }

      with {:ok, session} <- Transport.start_session_from(acquired, session_struct, opts) do
        if window_size = Keyword.get(opts, :window_size) do
          _ =
            CDPClient.set_window_size(
              session,
              window_size[:width],
              window_size[:height]
            )
        end

        {:ok, session}
      end
    end
  end

  # Pick the transport based on what's running:
  #
  #   * shared LP server → PerSession (single-actor model — fast path)
  #   * `:ws_url` opt    → IsolatedProcess fallback
  #   * lightpanda dep   → IsolatedProcess (spawn a fresh binary)
  defp pick_transport(opts) do
    base_caps = %{
      # Lightpanda's JS engine doesn't ship a real document.evaluate
      # — CDPClient.visit injects wgxpath after each page load.
      needs_xpath_polyfill: true
    }

    cond do
      url = Keyword.get(opts, :ws_url) ->
        # Caller-supplied URL: ad-hoc test or external Lightpanda. Use
        # IsolatedProcess (pre-existing two-actor shape) — it's the
        # safe choice when we don't own the binary.
        {Transport.IsolatedProcess, [ws_url: url, extra_capabilities: base_caps]}

      Process.whereis(@lightpanda_server_name) ->
        # Shared singleton spawned by the supervisor — fast path.
        # apply/3 used so the compiler doesn't require @lightpanda_server
        # to exist (test-only dep).
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        ws_url = apply(@lightpanda_server, :ws_url, [@lightpanda_server_name])
        {:per_session, ws_url}

      Code.ensure_loaded?(@lightpanda_server) ->
        {Transport.IsolatedProcess,
         [
           # credo:disable-for-next-line Credo.Check.Refactor.Apply
           spawn_fun: fn -> apply(@lightpanda_server, :start_link, [[name: nil]]) end,
           # credo:disable-for-next-line Credo.Check.Refactor.Apply
           url_fun: fn server -> apply(@lightpanda_server, :ws_url, [server]) end,
           extra_capabilities: base_caps
         ]}

      true ->
        raise "V2Driver requires either a :ws_url opt or the `lightpanda` package on the path"
    end
  end

  @impl true
  def end_session(%Session{} = session) do
    Protocol.stop(session)
    :ok
  end

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

  @impl true
  def get_window_size(parent), do: Orchestrator.get_window_size(@driver_spec, parent)

  @impl true
  def set_window_size(parent, w, h),
    do: Orchestrator.set_window_size(@driver_spec, parent, w, h)

  # ----- Element-scoped callbacks (`session` derived via parent chain) -----

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
  def send_keys(%Session{}, _keys) do
    {:error, :not_implemented}
  end

  def send_keys(%Element{} = element, keys),
    do: Orchestrator.send_keys(@driver_spec, element, keys)

  # ----- Stubs / unimplemented for now -----

  @impl true
  def selected(%Element{} = element), do: Orchestrator.selected(@driver_spec, element)

  # Element.fill_in/2 calls driver.clear(element, silent: true).
  def clear(%Element{} = element, _opts), do: Orchestrator.clear(@driver_spec, element)

  # ----- Mouse/touch/geometry (Lightpanda may not implement many of
  # these CDP domains; they're here for Driver-behaviour compatibility
  # and silently no-op when unsupported). -----

  def hover(%Element{} = element), do: Orchestrator.hover(@driver_spec, element)
  def tap(%Element{} = element), do: Orchestrator.tap(@driver_spec, element)
  def touch_down(parent, target, x, y),
    do: Orchestrator.touch_down(@driver_spec, parent, target, x, y)
  def touch_up(parent), do: Orchestrator.touch_up(@driver_spec, parent)
  def touch_move(parent, x, y), do: Orchestrator.touch_move(@driver_spec, parent, x, y)

  def touch_scroll(%Element{} = _element, _x_offset, _y_offset) do
    # Lightpanda doesn't implement Input.synthesizeScrollGesture.
    {:ok, nil}
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

  # Dialog support is a stub on Lightpanda — its JS engine doesn't
  # surface window.alert/confirm/prompt to CDP yet, so all `:browser`-
  # tagged dialog tests are excluded on this driver. The implementations
  # below exist only to satisfy the Driver behaviour.

  @impl true
  def accept_alert(session, fun) do
    fun.(session)
    ""
  end

  @impl true
  def accept_confirm(session, fun) do
    fun.(session)
    ""
  end

  @impl true
  def accept_prompt(session, _text, fun) do
    fun.(session)
    ""
  end

  @impl true
  def dismiss_confirm(session, fun) do
    fun.(session)
    ""
  end

  @impl true
  def dismiss_prompt(session, fun) do
    fun.(session)
    ""
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
end
