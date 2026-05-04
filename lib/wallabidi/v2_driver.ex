defmodule Wallabidi.V2Driver do
  @moduledoc false

  # Parallel V2-only driver implementing the existing
  # `Wallabidi.Driver` behaviour. Backs every callback with the V2
  # transport stack: V2.WebSocket + V2.Session + V2.CDPClient.
  #
  # This is a stepping stone to migrating real drivers (Lightpanda,
  # ChromeCDP) over. Not yet integrated with `Wallabidi.Browser`'s
  # pipeline path — that path calls `Wallabidi.SessionProcess.*` and
  # `Wallabidi.CDPClient.execute_ops` directly, bypassing the Driver
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
  alias Wallabidi.V2.CDPClient
  alias Wallabidi.V2.Session, as: V2Session
  alias Wallabidi.V2.WebSocket

  # ----- Driver supervisor (no children — Lightpanda's hex package
  # supervises its own server when start_session creates it). -----

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

  @impl Supervisor
  def init(_), do: Supervisor.init([], strategy: :one_for_one)

  @doc false
  def validate, do: :ok

  @doc false
  def cleanup_stale_sessions, do: :ok

  # ----- Session lifecycle -----

  @impl true
  def start_session(opts \\ []) do
    with {:ok, ws_url, server_pid} <- ensure_server(opts),
         {:ok, ws_pid} <- WebSocket.start_link(ws_url),
         {:ok, %{"targetId" => target_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createTarget", %{url: "about:blank"}),
         {:ok, %{"sessionId" => session_id}} <-
           WebSocket.send_sync(ws_pid, "Target.attachToTarget", %{
             targetId: target_id,
             flatten: true
           }) do
      session_struct = %Session{
        id: "v2drv-#{System.unique_integer([:positive])}",
        url: "about:blank",
        session_url: "about:blank",
        driver: __MODULE__,
        protocol: nil,
        bidi_pid: ws_pid,
        browsing_context: session_id,
        capabilities: %{
          target_id: target_id,
          flat_session_id: true,
          server_pid: server_pid
        }
      }

      teardown = fn _session -> teardown_resources(ws_pid, server_pid) end

      case V2Session.start_link(
             ws_pid: ws_pid,
             init_fun: fn -> {:ok, session_struct} end,
             teardown_fun: teardown
           ) do
        {:ok, session} ->
          :ok = CDPClient.enable_page_lifecycle_events(session)
          :ok = CDPClient.install_bootstrap(session)
          :ok = CDPClient.enable_frame_tracking(session)
          {:ok, session}

        error ->
          teardown_resources(ws_pid, server_pid)
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
  def visit(%Session{} = session, url), do: CDPClient.visit(session, url)

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
  def take_screenshot(%Session{} = session), do: CDPClient.take_screenshot(session)

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
  def execute_script(%Session{} = session, script, _args) do
    CDPClient.evaluate(session, script)
  end

  @impl true
  def execute_script_async(%Session{} = session, script, _args) do
    # No native async exec in V2 yet — fall back to evaluate.
    CDPClient.evaluate(session, script)
  end

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
    case CDPClient.attribute(Element.root_session(element), element, "selected") do
      {:ok, "true"} -> {:ok, true}
      {:ok, _} -> {:ok, false}
      error -> error
    end
  end

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

  defp ensure_server(opts) do
    case Keyword.get(opts, :ws_url) do
      url when is_binary(url) ->
        {:ok, url, nil}

      _ ->
        # Default = spawn a Lightpanda server. The `lightpanda` hex
        # package is `only: :test` so resolve lazily at runtime.
        server_mod = Module.concat([Lightpanda, Server])

        unless Code.ensure_loaded?(server_mod) do
          raise "V2Driver requires either a :ws_url opt or the `lightpanda` package on the path"
        end

        {:ok, server} = apply(server_mod, :start_link, [[name: nil]])
        ws_url = apply(server_mod, :ws_url, [server])
        {:ok, ws_url, server}
    end
  end

  defp teardown_resources(ws_pid, server_pid) do
    try do
      WebSocket.close(ws_pid)
    catch
      :exit, _ -> :ok
    end

    if is_pid(server_pid) do
      try do
        GenServer.stop(server_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp ensure_query(%Wallabidi.Query{} = q), do: q

  defp ensure_query({type, selector}) when type in [:css, :xpath] and is_binary(selector) do
    Wallabidi.Query.css(selector)
  end
end
