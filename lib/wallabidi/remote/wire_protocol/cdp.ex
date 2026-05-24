defmodule Wallabidi.Remote.WireProtocol.CDP do
  @moduledoc false

  @behaviour Wallabidi.Remote.WireProtocol

  alias Wallabidi.Remote.CDP.Client, as: CDPClient

  @impl true
  def visit(session, url), do: CDPClient.visit(session, url)

  @impl true
  def current_url(session), do: CDPClient.current_url(session)

  @impl true
  def current_path(session), do: CDPClient.current_path(session)

  @impl true
  def page_source(session), do: CDPClient.page_source(session)

  @impl true
  def page_title(session), do: CDPClient.page_title(session)

  @impl true
  def take_screenshot(session), do: CDPClient.take_screenshot(session)

  @impl true
  def cookies(session), do: CDPClient.cookies(session)

  @impl true
  def set_cookie(session, name, value), do: CDPClient.set_cookie(session, name, value)

  @impl true
  def set_cookie(session, name, value, attrs),
    do: CDPClient.set_cookie(session, name, value, attrs)

  @impl true
  def get_window_size(session), do: CDPClient.get_window_size(session)

  @impl true
  def set_window_size(session, w, h), do: CDPClient.set_window_size(session, w, h)

  @impl true
  def execute_script(session, script, args), do: CDPClient.evaluate(session, script, args)

  @impl true
  def execute_script_async(session, script, args),
    do: CDPClient.evaluate_async(session, script, args)

  @impl true
  def simple_click(session, element), do: CDPClient.click(session, element)

  @impl true
  def classified_click(session, element),
    do: CDPClient.click_aware_with_classification(session, element)

  @impl true
  def text(session, element), do: CDPClient.text(session, element)

  @impl true
  def attribute(session, element, name), do: CDPClient.attribute(session, element, name)

  @impl true
  def displayed(session, element), do: CDPClient.displayed(session, element)

  @impl true
  def set_value(session, element, value), do: CDPClient.set_value(session, element, value)

  @impl true
  def clear(session, element), do: CDPClient.clear(session, element)

  @impl true
  def find_elements(parent, query), do: CDPClient.find_elements(parent, query)

  @impl true
  def send_keys(session, element, keys), do: CDPClient.send_keys(session, element, keys)

  @impl true
  def selected(session, element) do
    case CDPClient.call_on_element(
           session,
           element,
           Wallabidi.Remote.OpsShared.dispatch_fn(),
           [[["is_selected"]]]
         ) do
      {:ok, v} -> {:ok, v == true}
      err -> err
    end
  end

  @impl true
  def hover(element), do: CDPClient.hover(element)
  @impl true
  def tap(element), do: CDPClient.tap(element)
  @impl true
  def touch_down(parent, target, x, y), do: CDPClient.touch_down(parent, target, x, y)
  @impl true
  def touch_up(parent), do: CDPClient.touch_up(parent)
  @impl true
  def touch_move(parent, x, y), do: CDPClient.touch_move(parent, x, y)
  @impl true
  def click_at_cursor(parent, button), do: CDPClient.click_at_cursor(parent, button)
  @impl true
  def double_click(parent), do: CDPClient.double_click(parent)
  @impl true
  def button_down(parent, button), do: CDPClient.button_down(parent, button)
  @impl true
  def button_up(parent, button), do: CDPClient.button_up(parent, button)
  @impl true
  def move_mouse_by(parent, x_offset, y_offset),
    do: CDPClient.move_mouse_by(parent, x_offset, y_offset)

  @impl true
  def element_size(element), do: CDPClient.element_size(element)
  @impl true
  def element_location(element), do: CDPClient.element_location(element)
  @impl true
  def blank_page?(session), do: CDPClient.blank_page?(session)
end
