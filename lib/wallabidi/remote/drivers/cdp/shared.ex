defmodule Wallabidi.Remote.Drivers.CDP.Shared do
  @moduledoc false

  # Shared `Wallabidi.Driver` callback implementations used by both
  # CDP drivers (ChromeCDP and LightpandaCDP).
  #
  # Each driver `defdelegate`s the callbacks below from this module and
  # keeps its own implementations for the vendor-specific bits — Chrome's
  # elaborate `click` flow, Lightpanda's stubbed `send_keys`, browser
  # lifecycle (`start_session`, dialogs, window/frame management), etc.
  #
  # The functions here are plain functions (not Driver-behaviour-bound)
  # so they're independently testable and don't carry @impl annotations
  # — the @impl on the delegating driver covers the contract.

  alias Wallabidi.Element
  alias Wallabidi.Remote.CDP.Client, as: CDPClient
  alias Wallabidi.Remote.LiveViewAware
  alias Wallabidi.Session

  # ----- Lifecycle / navigation -----

  @spec await_patch(Session.t(), keyword()) :: :ok
  def await_patch(%Session{} = session, opts) do
    LiveViewAware.arm_and_await(session, Keyword.get(opts, :timeout, 5_000))
  end

  @spec current_url(Session.t()) :: {:ok, String.t()} | {:error, term()}
  def current_url(%Session{} = session), do: CDPClient.current_url(session)

  @spec current_path(Session.t()) :: {:ok, String.t()} | {:error, term()}
  def current_path(%Session{} = session), do: CDPClient.current_path(session)

  @spec page_source(Session.t()) :: {:ok, String.t()} | {:error, term()}
  def page_source(%Session{} = session), do: CDPClient.page_source(session)

  @spec page_title(Session.t()) :: {:ok, String.t()} | {:error, term()}
  def page_title(%Session{} = session), do: CDPClient.page_title(session)

  # ----- Cookies -----

  @spec cookies(Session.t()) :: {:ok, list(map())} | {:error, term()}
  def cookies(%Session{} = session), do: CDPClient.cookies(session)

  @spec set_cookie(Session.t(), String.t(), String.t()) :: {:ok, nil} | {:error, term()}
  def set_cookie(%Session{} = session, name, value),
    do: cookie_result(CDPClient.set_cookie(session, name, value))

  @spec set_cookie(Session.t(), String.t(), String.t(), keyword() | map()) ::
          {:ok, nil} | {:error, term()}
  def set_cookie(%Session{} = session, name, value, attrs),
    do: cookie_result(CDPClient.set_cookie(session, name, value, Map.new(attrs)))

  defp cookie_result({:ok, _}), do: {:ok, nil}
  defp cookie_result(other), do: other

  # ----- Screenshots / window geometry -----

  @spec take_screenshot(Session.t()) :: binary()
  def take_screenshot(%Session{} = session) do
    case CDPClient.take_screenshot(session) do
      {:ok, binary} -> binary
      _ -> ""
    end
  end

  @spec get_window_size(Session.t()) :: {:ok, map()} | {:error, term()}
  def get_window_size(%Session{} = parent) do
    case CDPClient.get_window_size(Element.root_session(parent)) do
      {:ok, %{width: w, height: h}} -> {:ok, %{"width" => w, "height" => h}}
      other -> other
    end
  end

  @spec set_window_size(Session.t(), integer(), integer()) :: {:ok, nil} | {:error, term()}
  def set_window_size(%Session{} = parent, w, h),
    do: CDPClient.set_window_size(Element.root_session(parent), w, h)

  # ----- Element-scoped accessors -----

  @spec text(Element.t()) :: {:ok, String.t()} | {:error, term()}
  def text(%Element{} = element),
    do: CDPClient.text(Element.root_session(element), element)

  @spec attribute(Element.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def attribute(%Element{} = element, name),
    do: CDPClient.attribute(Element.root_session(element), element, name)

  @spec displayed(Element.t()) :: {:ok, boolean()} | {:error, term()}
  def displayed(%Element{} = element),
    do: CDPClient.displayed(Element.root_session(element), element)

  @spec set_value(Element.t(), term()) :: {:ok, nil} | {:error, term()}
  def set_value(%Element{} = element, value),
    do: CDPClient.set_value(Element.root_session(element), element, value)

  @spec clear(Element.t()) :: {:ok, nil} | {:error, term()}
  def clear(%Element{} = element),
    do: CDPClient.clear(Element.root_session(element), element)

  # Element.fill_in/2 calls driver.clear(element, silent: true) — the
  # silent flag suppresses input events. Plain clear; events will get
  # dispatched via the subsequent set_value.
  @spec clear(Element.t(), keyword()) :: {:ok, nil} | {:error, term()}
  def clear(%Element{} = element, _opts),
    do: CDPClient.clear(Element.root_session(element), element)

  @spec selected(Element.t()) :: {:ok, boolean()} | {:error, term()}
  def selected(%Element{} = element) do
    case CDPClient.call_on_element(
           Element.root_session(element),
           element,
           Wallabidi.Remote.OpsShared.dispatch_fn(),
           [[["is_selected"]]]
         ) do
      {:ok, v} -> {:ok, v == true}
      err -> err
    end
  end

  # ----- Find / scripting -----

  @spec find_elements(Session.t() | Element.t(), term()) ::
          {:ok, list(Element.t())} | {:error, term()}
  def find_elements(parent, query) do
    %Wallabidi.Query{} = q = ensure_query(query)
    CDPClient.find_elements(parent, q)
  end

  @spec execute_script(Session.t(), String.t(), list() | nil) ::
          {:ok, term()} | {:error, term()}
  def execute_script(%Session{} = session, script, args),
    do: CDPClient.evaluate(session, script, args || [])

  @spec execute_script_async(Session.t(), String.t(), list() | nil) ::
          {:ok, term()} | {:error, term()}
  def execute_script_async(%Session{} = session, script, args),
    do: CDPClient.evaluate_async(session, script, args || [])

  # Element-scoped send_keys is shared (Session-scoped diverges between
  # Chrome — real keystrokes — and Lightpanda — :not_implemented).
  @spec send_keys(Element.t(), list()) :: {:ok, nil} | {:error, term()}
  def send_keys(%Element{} = element, keys),
    do: CDPClient.send_keys(Element.root_session(element), element, keys)

  # ----- Mouse / touch / geometry (most are simple delegates) -----

  @spec hover(Element.t()) :: {:ok, nil} | {:error, term()}
  def hover(%Element{} = element), do: CDPClient.hover(element)

  @spec tap(Element.t()) :: {:ok, nil} | {:error, term()}
  def tap(%Element{} = element), do: CDPClient.tap(element)

  @spec touch_down(Session.t() | Element.t(), term(), number(), number()) ::
          {:ok, nil} | {:error, term()}
  def touch_down(parent, target, x, y),
    do: CDPClient.touch_down(Element.root_session(parent), target, x, y)

  @spec touch_up(Session.t() | Element.t()) :: {:ok, nil} | {:error, term()}
  def touch_up(parent), do: CDPClient.touch_up(parent)

  @spec touch_move(Session.t() | Element.t(), number(), number()) ::
          {:ok, nil} | {:error, term()}
  def touch_move(parent, x, y), do: CDPClient.touch_move(parent, x, y)

  @spec click_at_cursor(Session.t() | Element.t(), :left | :middle | :right) ::
          {:ok, nil} | {:error, term()}
  def click_at_cursor(parent, button) when button in [:left, :middle, :right],
    do: CDPClient.click_at_cursor(parent, button)

  @spec double_click(Session.t() | Element.t()) :: {:ok, nil} | {:error, term()}
  def double_click(parent), do: CDPClient.double_click(parent)

  @spec button_down(Session.t() | Element.t(), atom()) :: {:ok, nil} | {:error, term()}
  def button_down(parent, button), do: CDPClient.button_down(parent, button)

  @spec button_up(Session.t() | Element.t(), atom()) :: {:ok, nil} | {:error, term()}
  def button_up(parent, button), do: CDPClient.button_up(parent, button)

  @spec move_mouse_by(Session.t() | Element.t(), number(), number()) ::
          {:ok, nil} | {:error, term()}
  def move_mouse_by(parent, x_offset, y_offset),
    do: CDPClient.move_mouse_by(parent, x_offset, y_offset)

  @spec element_size(Element.t()) :: {:ok, map()} | {:error, term()}
  def element_size(%Element{} = element), do: CDPClient.element_size(element)

  @spec element_location(Element.t()) :: {:ok, map()} | {:error, term()}
  def element_location(%Element{} = element), do: CDPClient.element_location(element)

  @spec blank_page?(Session.t()) :: boolean()
  def blank_page?(%Session{} = session), do: CDPClient.blank_page?(session)

  # ----- Internal -----

  defp ensure_query(%Wallabidi.Query{} = q), do: q

  defp ensure_query({type, selector}) when type in [:css, :xpath] and is_binary(selector) do
    Wallabidi.Query.css(selector)
  end
end
