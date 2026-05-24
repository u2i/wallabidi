defmodule Wallabidi.Remote.WireProtocol.BiDi do
  @moduledoc false

  @behaviour Wallabidi.Remote.WireProtocol

  alias Wallabidi.Remote.BiDi.Client, as: BiDiClient

  @impl true
  def visit(session, url), do: BiDiClient.visit(session, url)

  @impl true
  def current_url(session), do: BiDiClient.current_url(session)

  @impl true
  def current_path(session), do: BiDiClient.current_path(session)

  @impl true
  def page_source(session), do: BiDiClient.page_source(session)

  @impl true
  def page_title(session), do: BiDiClient.page_title(session)

  @impl true
  def take_screenshot(session), do: BiDiClient.take_screenshot(session)

  @impl true
  def cookies(session), do: BiDiClient.cookies(session)

  @impl true
  def set_cookie(session, name, value), do: BiDiClient.set_cookie(session, name, value)

  @impl true
  def set_cookie(session, name, value, attrs),
    do: BiDiClient.set_cookie(session, name, value, attrs)

  # BiDi uses set_viewport / get_viewport rather than CDP's window-size APIs,
  # but the orchestrator-facing shape is the same.
  @impl true
  def get_window_size(session), do: BiDiClient.get_viewport(session)

  @impl true
  def set_window_size(session, w, h), do: BiDiClient.set_viewport(session, w, h)

  @impl true
  def execute_script(session, script, args), do: BiDiClient.evaluate(session, script, args)

  @impl true
  def execute_script_async(session, script, args),
    do: BiDiClient.evaluate_async(session, script, args)

  @impl true
  def simple_click(session, element), do: BiDiClient.click(session, element)

  @impl true
  def classified_click(session, element),
    do: BiDiClient.click_aware_with_classification(session, element)

  @impl true
  def text(session, element), do: BiDiClient.text(session, element)

  @impl true
  def attribute(session, element, name), do: BiDiClient.attribute(session, element, name)

  @impl true
  def displayed(session, element), do: BiDiClient.displayed(session, element)

  @impl true
  def set_value(session, element, value), do: BiDiClient.set_value(session, element, value)

  @impl true
  def clear(session, element), do: BiDiClient.clear(session, element)

  @impl true
  def find_elements(parent, query), do: BiDiClient.find_elements(parent, query)

  @impl true
  def send_keys(session, element, keys), do: BiDiClient.send_keys(session, element, keys)

  # ChromeBiDi historically returned the raw selected result without the
  # boolean coercion that CDP applies. Keeping that here so behaviour is
  # preserved; if integration tests prefer the CDP shape we can normalise.
  @impl true
  def selected(session, element) do
    BiDiClient.call_on_element(
      session,
      element,
      Wallabidi.Remote.OpsShared.dispatch_fn(),
      [[["is_selected"]]]
    )
  end

  @impl true
  def hover(element), do: BiDiClient.hover(element)
  @impl true
  def tap(element), do: BiDiClient.tap(element)
  @impl true
  def touch_down(parent, target, x, y), do: BiDiClient.touch_down(parent, target, x, y)
  @impl true
  def touch_up(parent), do: BiDiClient.touch_up(parent)
  @impl true
  def touch_move(parent, x, y), do: BiDiClient.touch_move(parent, x, y)
  @impl true
  def click_at_cursor(parent, button), do: BiDiClient.click_at_cursor(parent, button)
  @impl true
  def double_click(parent), do: BiDiClient.double_click(parent)
  @impl true
  def button_down(parent, button), do: BiDiClient.button_down(parent, button)
  @impl true
  def button_up(parent, button), do: BiDiClient.button_up(parent, button)
  @impl true
  def move_mouse_by(parent, x_offset, y_offset),
    do: BiDiClient.move_mouse_by(parent, x_offset, y_offset)

  @impl true
  def element_size(element), do: BiDiClient.element_size(element)
  @impl true
  def element_location(element), do: BiDiClient.element_location(element)

  # ChromeBiDi has a richer blank_page? — checks for "about:blank" or "".
  @impl true
  def blank_page?(session) do
    case BiDiClient.current_url(session) do
      {:ok, url} -> url in ["about:blank", ""]
      _ -> false
    end
  end
end
