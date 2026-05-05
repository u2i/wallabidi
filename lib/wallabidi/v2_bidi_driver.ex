defmodule Wallabidi.V2BiDiDriver do
  @moduledoc false

  # V2 driver speaking WebDriver-BiDi against a chromium-bidi server.
  #
  # ## Topology
  #
  # The supervisor starts a single chromium-bidi Node server
  # (`Wallabidi.Chrome.BidiServer`) — same singleton model used by
  # `V2Driver` for Lightpanda. Each test session does its own HTTP
  # `POST /session` against that server, then opens the per-session
  # WebSocket the server returns. chromium-bidi spawns a fresh
  # Chrome+Mapper per WS connection, so sessions are isolated by
  # construction — no userContext multiplexing needed.
  #
  # `start_session/1` delegates the bring-up dance (POST + WS upgrade
  # + `browsingContext.create` + bootstrap preload install) to
  # `V2.Transport.BiDi.start_session/1`. Driver callbacks are thin
  # wrappers around `V2.BiDiClient` — same surface as `V2Driver`'s
  # delegation to `V2.CDPClient`, just BiDi-flavored.

  use Supervisor

  @behaviour Wallabidi.Driver

  alias Wallabidi.{Element, Session}
  alias Wallabidi.V2.BiDiClient
  alias Wallabidi.V2.Transport.BiDi
  alias Wallabidi.V2.Transport.Protocol

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
      {Wallabidi.Chrome.BidiServer, [name: @bidi_server_name]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def validate, do: :ok

  @doc false
  def cleanup_stale_sessions, do: :ok

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
      capabilities: %{}
    }

    BiDi.start_session(
      base_url: base_url,
      session_struct: session_struct,
      owner: Keyword.get(opts, :owner, self())
    )
  end

  defp resolve_base_url(opts) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) ->
        url

      _ ->
        # Convert the BidiServer's WS URL to its HTTP equivalent —
        # they share the host/port; chromium-bidi serves both.
        ws_url = Wallabidi.Chrome.BidiServer.ws_url(@bidi_server_name)

        ws_url
        |> URI.parse()
        |> Map.put(:scheme, "http")
        |> Map.put(:path, nil)
        |> URI.to_string()
    end
  end

  @impl true
  def end_session(%Session{} = session) do
    Protocol.stop(session)
    :ok
  end

  # ----- Session-scoped callbacks -----

  @impl true
  def visit(%Session{} = session, url), do: BiDiClient.visit(session, url)

  @impl true
  def current_url(%Session{} = session), do: BiDiClient.current_url(session)

  @impl true
  def current_path(%Session{} = session), do: BiDiClient.current_path(session)

  @impl true
  def page_source(%Session{} = session), do: BiDiClient.page_source(session)

  @impl true
  def page_title(%Session{} = session), do: BiDiClient.page_title(session)

  @impl true
  def execute_script(%Session{} = session, script, args),
    do: BiDiClient.evaluate(session, script, args || [])

  @impl true
  def execute_script_async(%Session{} = _session, _script, _args),
    do: {:error, :not_implemented}

  # ----- Element-scoped callbacks -----

  @impl true
  def click(%Element{} = element) do
    BiDiClient.click(Element.root_session(element), element)
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
      "function() { return this.checked === true || this.selected === true; }"
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

  # ----- Cookies / screenshot / window — not implemented yet -----

  @impl true
  def cookies(%Session{}), do: {:error, :not_implemented}

  @impl true
  def set_cookie(%Session{}, _name, _value), do: {:error, :not_implemented}

  @impl true
  def set_cookie(%Session{}, _name, _value, _attrs), do: {:error, :not_implemented}

  @impl true
  def take_screenshot(%Session{}), do: ""

  @impl true
  def get_window_size(%Session{}), do: {:ok, %{"width" => 1024, "height" => 768}}

  @impl true
  def set_window_size(%Session{}, _w, _h), do: {:ok, nil}

  # ----- Dialog stubs -----

  @impl true
  def accept_alert(session, fun) do
    {:ok, [fun.(session)]}
  end

  @impl true
  def accept_confirm(session, fun) do
    {:ok, [fun.(session)]}
  end

  @impl true
  def accept_prompt(session, _text, fun) do
    {:ok, [fun.(session)]}
  end

  @impl true
  def dismiss_confirm(session, fun) do
    {:ok, [fun.(session)]}
  end

  @impl true
  def dismiss_prompt(session, fun) do
    {:ok, [fun.(session)]}
  end

  # ----- Window / frame stubs -----

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
