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
  alias Wallabidi.Remote.CDP.Client, as: CDPClient
  alias Wallabidi.Remote.Drivers.CDP.Shared, as: CDPShared
  alias Wallabidi.Remote.LiveViewAware
  alias Wallabidi.Remote.Transport
  alias Wallabidi.Remote.Transport.Protocol

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
  def visit(%Session{} = session, url) do
    result = CDPClient.visit(session, url)
    _ = LiveViewAware.await_liveview_connected(session)
    result
  end

  @impl true
  defdelegate await_patch(session, opts), to: CDPShared

  @impl true
  defdelegate current_url(session), to: CDPShared

  @impl true
  defdelegate current_path(session), to: CDPShared

  @impl true
  defdelegate page_source(session), to: CDPShared

  @impl true
  defdelegate page_title(session), to: CDPShared

  @impl true
  defdelegate cookies(session), to: CDPShared

  @impl true
  defdelegate set_cookie(session, name, value), to: CDPShared

  @impl true
  defdelegate set_cookie(session, name, value, attrs), to: CDPShared

  @impl true
  defdelegate take_screenshot(session), to: CDPShared

  @impl true
  defdelegate get_window_size(parent), to: CDPShared

  @impl true
  defdelegate set_window_size(parent, w, h), to: CDPShared

  # ----- Element-scoped callbacks (`session` derived via parent chain) -----

  @impl true
  def click(%Element{} = element) do
    CDPClient.click(Element.root_session(element), element)
  end

  @impl true
  defdelegate text(element), to: CDPShared

  @impl true
  defdelegate attribute(element, name), to: CDPShared

  @impl true
  defdelegate displayed(element), to: CDPShared

  @impl true
  defdelegate set_value(element, value), to: CDPShared

  @impl true
  defdelegate clear(element), to: CDPShared

  @impl true
  defdelegate find_elements(parent, query), to: CDPShared

  @impl true
  defdelegate execute_script(session, script, args), to: CDPShared

  @impl true
  defdelegate execute_script_async(session, script, args), to: CDPShared

  @impl true
  def send_keys(%Session{}, _keys) do
    {:error, :not_implemented}
  end

  defdelegate send_keys(element, keys), to: CDPShared

  # ----- Stubs / unimplemented for now -----

  @impl true
  defdelegate selected(element), to: CDPShared

  # Element.fill_in/2 calls driver.clear(element, silent: true).
  defdelegate clear(element, opts), to: CDPShared

  # ----- Mouse/touch/geometry (Lightpanda may not implement many of
  # these CDP domains; they're here for Driver-behaviour compatibility
  # and silently no-op when unsupported). -----

  defdelegate hover(element), to: CDPShared
  defdelegate tap(element), to: CDPShared
  defdelegate touch_down(parent, target, x, y), to: CDPShared
  defdelegate touch_up(parent), to: CDPShared
  defdelegate touch_move(parent, x, y), to: CDPShared

  def touch_scroll(%Element{} = _element, _x_offset, _y_offset) do
    # Lightpanda doesn't implement Input.synthesizeScrollGesture.
    {:ok, nil}
  end

  def click(parent, button) when button in [:left, :middle, :right],
    do: CDPShared.click_at_cursor(parent, button)

  defdelegate double_click(parent), to: CDPShared
  defdelegate button_down(parent, button), to: CDPShared
  defdelegate button_up(parent, button), to: CDPShared
  defdelegate move_mouse_by(parent, x_offset, y_offset), to: CDPShared
  defdelegate element_size(element), to: CDPShared
  defdelegate element_location(element), to: CDPShared
  defdelegate blank_page?(session), to: CDPShared

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
