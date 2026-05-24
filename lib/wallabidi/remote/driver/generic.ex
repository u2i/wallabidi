defmodule Wallabidi.Remote.Driver.Generic do
  @moduledoc false

  # The fully data-driven Driver. Implements every Wallabidi.Driver
  # callback by reading `session.driver_spec` (or the equivalent on the
  # passed Element) and dispatching to the spec's dimension modules
  # (browser, wire_protocol, dialogs, windows, frames) and the
  # Orchestrator for flow logic.
  #
  # Each concrete driver module (ChromeCDP, LightpandaCDP, ChromeBiDi)
  # `use`s Generic to inherit all the non-lifecycle callback delegations,
  # then provides:
  #
  #   * `start_session/1` — vendor-specific WS / transport acquisition,
  #     post-acquire setup, then stamps `session.driver_spec` and
  #     `session.driver = Generic` so subsequent calls dispatch through
  #     here.
  #   * `end_session/1`   — vendor-specific teardown.
  #
  # `start_session` is the only place that knows which Spec applies to
  # this driver. After it returns, the session is "generic" — Wallaby
  # internals call `Generic.click(elem)`, `Generic.visit(s, url)`, etc.,
  # and we route via `spec(element_or_session)`.

  alias Wallabidi.{Element, Session}
  alias Wallabidi.Remote.Driver.{Orchestrator, Spec}

  # ----- The __using__ macro -----
  #
  # Concrete drivers `use Wallabidi.Remote.Driver.Generic` to inherit
  # every non-lifecycle Driver callback as a defdelegate to this module.
  # The driver still owns `start_session/1` (vendor-specific) and stamps
  # `session.driver_spec` so subsequent calls dispatch via spec.

  # Driver-behaviour callbacks delegated through the Generic macro.
  # Defined as a single source of truth here so the macro stays compact.
  @generic_callbacks [
    # {name, arity, is_driver_behaviour_callback?}
    {:await_patch, 2, true},
    {:visit, 2, true},
    {:current_url, 1, true},
    {:current_path, 1, true},
    {:page_source, 1, true},
    {:page_title, 1, true},
    {:cookies, 1, true},
    {:set_cookie, 3, true},
    {:set_cookie, 4, true},
    {:take_screenshot, 1, true},
    {:get_window_size, 1, true},
    {:set_window_size, 3, true},
    {:click, 1, true},
    {:text, 1, true},
    {:attribute, 2, true},
    {:displayed, 1, true},
    {:set_value, 2, true},
    {:clear, 1, true},
    {:clear, 2, false},
    {:find_elements, 2, true},
    {:execute_script, 3, true},
    {:execute_script_async, 3, true},
    {:send_keys, 2, true},
    {:selected, 1, true},
    {:accept_alert, 2, true},
    {:accept_confirm, 2, true},
    {:accept_prompt, 3, true},
    {:dismiss_confirm, 2, true},
    {:dismiss_prompt, 2, true},
    {:window_handle, 1, true},
    {:window_handles, 1, true},
    {:focus_window, 2, true},
    {:close_window, 1, true},
    {:maximize_window, 1, true},
    {:get_window_position, 1, true},
    {:set_window_position, 3, true},
    {:focus_frame, 2, true},
    {:focus_parent_frame, 1, true},
    {:hover, 1, false},
    {:tap, 1, false},
    {:touch_down, 4, false},
    {:touch_up, 1, false},
    {:touch_move, 3, false},
    {:touch_scroll, 3, false},
    {:click, 2, false},
    {:double_click, 1, false},
    {:button_down, 2, false},
    {:button_up, 2, false},
    {:move_mouse_by, 3, false},
    {:element_size, 1, false},
    {:element_location, 1, false},
    {:blank_page?, 1, false},
    {:parse_log, 1, false}
  ]

  @doc false
  def __generic_callbacks__, do: @generic_callbacks

  defmacro __using__(_opts) do
    delegates =
      for {name, arity, is_callback} <- Wallabidi.Remote.Driver.Generic.__generic_callbacks__() do
        args = Macro.generate_arguments(arity, __MODULE__)

        impl_attr =
          if is_callback do
            quote do: @impl(Wallabidi.Driver)
          end

        quote do
          unquote(impl_attr)
          defdelegate unquote(name)(unquote_splicing(args)), to: Wallabidi.Remote.Driver.Generic
        end
      end

    overridable =
      for {name, arity, _is_callback} <- Wallabidi.Remote.Driver.Generic.__generic_callbacks__() do
        {name, arity}
      end

    quote do
      @behaviour Wallabidi.Driver
      unquote_splicing(delegates)
      defoverridable unquote(overridable)
    end
  end

  # ----- Implementation: every callback dispatches via session.driver_spec -----

  # ----- Flow callbacks routed through Orchestrator -----

  def visit(%Session{} = session, url), do: Orchestrator.visit(spec(session), session, url)

  def await_patch(%Session{} = session, opts),
    do: Orchestrator.await_patch(spec(session), session, opts)

  def current_url(%Session{} = session), do: Orchestrator.current_url(spec(session), session)

  def current_path(%Session{} = session), do: Orchestrator.current_path(spec(session), session)

  def page_source(%Session{} = session), do: Orchestrator.page_source(spec(session), session)

  def page_title(%Session{} = session), do: Orchestrator.page_title(spec(session), session)

  def cookies(%Session{} = session), do: Orchestrator.cookies(spec(session), session)

  def set_cookie(%Session{} = session, name, value),
    do: Orchestrator.set_cookie(spec(session), session, name, value)

  def set_cookie(%Session{} = session, name, value, attrs),
    do: Orchestrator.set_cookie(spec(session), session, name, value, attrs)

  def take_screenshot(%Session{} = session),
    do: Orchestrator.take_screenshot(spec(session), session)

  def take_screenshot(%Element{} = element),
    do: Orchestrator.take_screenshot(spec(element), element)

  def get_window_size(parent), do: Orchestrator.get_window_size(spec(parent), parent)

  def set_window_size(parent, w, h),
    do: Orchestrator.set_window_size(spec(parent), parent, w, h)

  def click(%Element{} = element), do: Orchestrator.click(spec(element), element)

  def text(%Element{} = element), do: Orchestrator.text(spec(element), element)

  def attribute(%Element{} = element, name),
    do: Orchestrator.attribute(spec(element), element, name)

  def displayed(%Element{} = element), do: Orchestrator.displayed(spec(element), element)

  def set_value(%Element{} = element, value),
    do: Orchestrator.set_value(spec(element), element, value)

  def clear(%Element{} = element), do: Orchestrator.clear(spec(element), element)

  def clear(%Element{} = element, opts) do
    # Per-driver opt: some drivers (ChromeBiDi) consume the opts; CDP
    # drivers ignore. The spec carries a flag if needed; for now always
    # call the bare clear so behaviour matches the CDP impls. If
    # ChromeBiDi's silent path needs the opts, we add a Spec.clear_with_opts?
    # flag later.
    _ = opts
    Orchestrator.clear(spec(element), element)
  end

  def find_elements(parent, query), do: Orchestrator.find_elements(spec(parent), parent, query)

  def execute_script(%Session{} = session, script, args),
    do: Orchestrator.execute_script(spec(session), session, script, args)

  def execute_script_async(%Session{} = session, script, args),
    do: Orchestrator.execute_script_async(spec(session), session, script, args)

  def send_keys(%Session{} = session, keys) when is_list(keys) do
    # Session-scoped send_keys: each driver has its own behaviour
    # (Chrome sends real keystrokes; Lightpanda returns :not_implemented).
    # Route through the wire_protocol's send_keys_to_session if it has
    # one, else through the spec's send_keys_session_unsupported flag.
    case spec(session).wire_protocol do
      mod when mod != nil ->
        if function_exported?(mod, :send_keys_to_session, 2) do
          mod.send_keys_to_session(session, keys)
        else
          {:error, :not_implemented}
        end
    end
  end

  def send_keys(%Session{} = session, key) when is_binary(key) or is_atom(key) do
    send_keys(session, [key])
  end

  def send_keys(%Element{} = element, keys),
    do: Orchestrator.send_keys(spec(element), element, keys)

  def selected(%Element{} = element), do: Orchestrator.selected(spec(element), element)

  # ----- Vendor-specific dimensions routed through dimension behaviours -----

  def accept_alert(%Session{} = session, fun),
    do: spec(session).dialogs.accept_alert(session, fun)

  def accept_confirm(%Session{} = session, fun),
    do: spec(session).dialogs.accept_confirm(session, fun)

  def accept_prompt(%Session{} = session, text, fun),
    do: spec(session).dialogs.accept_prompt(session, text, fun)

  def dismiss_confirm(%Session{} = session, fun),
    do: spec(session).dialogs.dismiss_confirm(session, fun)

  def dismiss_prompt(%Session{} = session, fun),
    do: spec(session).dialogs.dismiss_prompt(session, fun)

  def window_handle(parent), do: spec(parent).windows.window_handle(parent)

  def window_handles(parent), do: spec(parent).windows.window_handles(parent)

  def focus_window(parent, handle), do: spec(parent).windows.focus_window(parent, handle)

  def close_window(parent), do: spec(parent).windows.close_window(parent)

  def maximize_window(_), do: {:ok, nil}

  def get_window_position(_), do: {:ok, %{"x" => 0, "y" => 0}}

  def set_window_position(_, _, _), do: {:ok, nil}

  def focus_frame(%Session{} = session, iframe),
    do: spec(session).frames.focus_frame(session, iframe)

  def focus_parent_frame(parent), do: spec(parent).frames.focus_parent_frame(parent)

  # ----- Mouse / touch / geometry (Orchestrator-routed; vendor stub via Spec
  # for touch_scroll which has 3 distinct impls) -----

  def hover(%Element{} = element), do: Orchestrator.hover(spec(element), element)
  def tap(%Element{} = element), do: Orchestrator.tap(spec(element), element)

  def touch_down(parent, target, x, y),
    do: Orchestrator.touch_down(spec(parent), parent, target, x, y)

  def touch_up(parent), do: Orchestrator.touch_up(spec(parent), parent)
  def touch_move(parent, x, y), do: Orchestrator.touch_move(spec(parent), parent, x, y)

  # touch_scroll varies per driver:
  #   ChromeCDP — Input.synthesizeScrollGesture
  #   ChromeBiDi — JS scrollBy
  #   Lightpanda — no-op
  # The Spec carries a function for it (a clean way to handle a 1-off
  # driver-specific override that doesn't justify its own behaviour).
  def touch_scroll(%Element{} = element, x_offset, y_offset) do
    fun = spec(element).touch_scroll || fn _e, _x, _y -> {:ok, nil} end
    fun.(element, x_offset, y_offset)
  end

  def click(parent, button) when button in [:left, :middle, :right],
    do: Orchestrator.click_at_cursor(spec(parent), parent, button)

  def double_click(parent), do: Orchestrator.double_click(spec(parent), parent)
  def button_down(parent, button), do: Orchestrator.button_down(spec(parent), parent, button)
  def button_up(parent, button), do: Orchestrator.button_up(spec(parent), parent, button)

  def move_mouse_by(parent, x_offset, y_offset),
    do: Orchestrator.move_mouse_by(spec(parent), parent, x_offset, y_offset)

  def element_size(%Element{} = element), do: Orchestrator.element_size(spec(element), element)

  def element_location(%Element{} = element),
    do: Orchestrator.element_location(spec(element), element)

  def blank_page?(%Session{} = session), do: Orchestrator.blank_page?(spec(session), session)

  # ----- Log parsing -----

  def parse_log(log) do
    # parse_log is called per log entry; the caller (LogChecker) doesn't
    # have a session in scope. The Spec's log_parser module is consulted
    # via a process-dict shim set during start_session.
    # For now, delegate to the Chrome.Logger by default since that's
    # what both Chrome drivers used.
    Wallabidi.Remote.Chrome.Logger.parse_log(log)
  end

  # ----- Spec lookup -----

  @doc false
  @spec spec(Session.t() | Element.t()) :: Spec.t()
  def spec(%Session{driver_spec: %Spec{} = spec}), do: spec
  def spec(%Element{} = element), do: spec(Element.root_session(element))
end
