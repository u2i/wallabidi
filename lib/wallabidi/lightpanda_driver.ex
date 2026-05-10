defmodule Wallabidi.LightpandaDriver do
  @moduledoc false

  # Parallel V2-only driver implementing the existing
  # `Wallabidi.Driver` behaviour. Backs every callback with the V2
  # transport stack: V2.WebSocket + V2.Session + V2.CDPClient.
  #
  # This is a stepping stone to migrating real drivers (Lightpanda,
  # ChromeCDP) over. Not yet integrated with `Wallabidi.Browser`'s
  # pipeline path — that path calls `Wallabidi.SessionProcess.*` and
  # `Wallabidi.Remote.CDP.Client.execute_ops` directly, bypassing the Driver
  # behaviour. Those couplings need their own surgery before any
  # driver flips fully.
  #
  # Targets Lightpanda by default — `start_session/1` brings up a
  # `Lightpanda.Server`, opens a `V2.WebSocket` to it, attaches a
  # CDP target, and boots a `V2.Session`. Pass
  # `:ws_url` in opts to point at a different CDP-speaking browser.

  use Supervisor

  @behaviour Wallabidi.Driver

  alias Wallabidi.{Element, Session}
  alias Wallabidi.Remote.CDP.Client, as: CDPClient
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
        # per CDP call. See V2.Transport.PerSession.
        start_per_session(opts, ws_url)

      {transport_mod, transport_opts} ->
        # Two-actor shape: separate V2.WebSocket (acquired by the
        # transport) + V2.Session linked to it. SharedWS / IsolatedProcess.
        start_legacy(opts, transport_mod, transport_opts)
    end
  end

  defp start_per_session(opts, ws_url) do
    session_struct = %Session{
      id: "v2drv-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      driver: __MODULE__,
      protocol: nil,
      browsing_context: nil,
      capabilities: %{
        flat_session_id: true,
        # Lightpanda's JS engine doesn't ship a real document.evaluate
        # — V2.CDPClient.visit injects wgxpath after each page load.
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
        protocol: nil,
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
      # — V2.CDPClient.visit injects wgxpath after each page load.
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
        ws_url = apply(@lightpanda_server, :ws_url, [@lightpanda_server_name])
        {:per_session, ws_url}

      Code.ensure_loaded?(@lightpanda_server) ->
        {Transport.IsolatedProcess,
         [
           spawn_fun: fn -> apply(@lightpanda_server, :start_link, [[name: nil]]) end,
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
    _ = await_liveview_connected_v2(session)
    result
  end

  # Mirrors V2ChromeDriver.await_liveview_connected_v2/1: after a navigation,
  # if the page has [data-phx-session], block until liveSocket.main.joinPending
  # is false (or 5s deadline). Without this, post-visit interactions like
  # fill_in / click can land before the LV channel finishes joining and the
  # phx-change/phx-click event is dropped, surfacing as a flaky failure.
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
  rescue
    _ -> :ok
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

  # ----- Element-scoped callbacks (`session` derived via parent chain) -----

  @impl true
  def click(%Element{} = element) do
    CDPClient.click(Element.root_session(element), element)
  end

  @impl true
  def text(%Element{} = element) do
    CDPClient.text(Element.root_session(element), element)
  end

  @impl true
  def attribute(%Element{} = element, name) do
    CDPClient.attribute(Element.root_session(element), element, name)
  end

  @impl true
  def displayed(%Element{} = element) do
    CDPClient.displayed(Element.root_session(element), element)
  end

  @impl true
  def set_value(%Element{} = element, value) do
    CDPClient.set_value(Element.root_session(element), element, value)
  end

  @impl true
  def clear(%Element{} = element) do
    CDPClient.clear(Element.root_session(element), element)
  end

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
  def send_keys(%Session{}, _keys) do
    {:error, :not_implemented}
  end

  def send_keys(%Element{} = element, keys) do
    CDPClient.send_keys(Element.root_session(element), element, keys)
  end

  # ----- Stubs / unimplemented for now -----

  @impl true
  def selected(%Element{} = element) do
    case CDPClient.call_on_element(
           Element.root_session(element),
           element,
           Wallabidi.Remote.OpsShared.dispatch_fn(),
           ["is_selected", []]
         ) do
      {:ok, v} -> {:ok, v == true}
      err -> err
    end
  end

  # Element.fill_in/2 calls driver.clear(element, silent: true).
  def clear(%Element{} = element, _opts),
    do: CDPClient.clear(Element.root_session(element), element)

  # ----- Mouse/touch/geometry (Lightpanda may not implement many of
  # these CDP domains; they're here for Driver-behaviour compatibility
  # and silently no-op when unsupported). -----

  def hover(%Element{} = element), do: CDPClient.hover(element)
  def tap(%Element{} = element), do: CDPClient.tap(element)

  def touch_down(parent, target, x, y),
    do: CDPClient.touch_down(Element.root_session(parent), target, x, y)

  def touch_up(parent), do: CDPClient.touch_up(parent)
  def touch_move(parent, x, y), do: CDPClient.touch_move(parent, x, y)

  def touch_scroll(%Element{} = _element, _x_offset, _y_offset) do
    # Lightpanda doesn't implement Input.synthesizeScrollGesture.
    {:ok, nil}
  end

  def click(parent, button) when button in [:left, :middle, :right],
    do: CDPClient.click_at_cursor(parent, button)

  def double_click(parent), do: CDPClient.double_click(parent)
  def button_down(parent, button), do: CDPClient.button_down(parent, button)
  def button_up(parent, button), do: CDPClient.button_up(parent, button)

  def move_mouse_by(parent, x_offset, y_offset),
    do: CDPClient.move_mouse_by(parent, x_offset, y_offset)

  def element_size(%Element{} = element), do: CDPClient.element_size(element)
  def element_location(%Element{} = element), do: CDPClient.element_location(element)
  def blank_page?(%Session{} = session), do: CDPClient.blank_page?(session)

  @impl true
  def accept_alert(session, fun) do
    result = fun.(session)
    {:ok, [result]}
  end

  @impl true
  def accept_confirm(session, fun) do
    result = fun.(session)
    {:ok, [result]}
  end

  @impl true
  def accept_prompt(session, _text, fun) do
    result = fun.(session)
    {:ok, [result]}
  end

  @impl true
  def dismiss_confirm(session, fun) do
    result = fun.(session)
    {:ok, [result]}
  end

  @impl true
  def dismiss_prompt(session, fun) do
    result = fun.(session)
    {:ok, [result]}
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

  # ----- Internal -----

  defp ensure_query(%Wallabidi.Query{} = q), do: q

  defp ensure_query({type, selector}) when type in [:css, :xpath] and is_binary(selector) do
    Wallabidi.Query.css(selector)
  end
end
