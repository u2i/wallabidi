defmodule Wallabidi.Remote.Driver.Orchestrator do
  @moduledoc false

  # Generic Driver-callback flows parameterised by a `Driver.Spec`.
  #
  # Each function takes the spec + the same args the Driver-behaviour
  # callback would, and consults the spec's dimension modules
  # (`spec.browser`, `spec.wire_protocol`) and cross-cutting flags
  # (`spec.log_check_interactions?`, etc.) for the variable bits.
  #
  # Owns the flow for ~30 Driver callbacks across all 3 drivers
  # (ChromeCDP / ChromeBiDi / LightpandaCDP). Per-driver vendor bits
  # — start_session, dialogs, window/frame management — stay in the
  # driver module.

  import Wallabidi.Driver.LogChecker

  alias Wallabidi.{Element, Session}
  alias Wallabidi.Remote.Driver.Spec
  alias Wallabidi.Remote.LiveViewAware

  @doc """
  Arm and await a LiveView patch — wraps `LiveViewAware.arm_and_await`.
  Protocol-agnostic (uses Wallabidi.Remote.Protocol.eval_async under the
  hood).
  """
  @spec await_patch(Spec.t(), Session.t(), keyword) :: :ok
  def await_patch(_spec, %Session{} = session, opts) do
    LiveViewAware.arm_and_await(session, Keyword.get(opts, :timeout, 5_000))
  end

  @doc """
  Visit `url` in the session's top-level browsing context. Wraps the
  navigation + the subsequent LiveView-connect await in log-check when
  the driver opts in via `log_check_interactions?`.
  """
  @spec visit(Spec.t(), Session.t(), String.t()) :: {:ok, term} | {:error, term}
  def visit(%Spec{} = spec, %Session{} = session, url) do
    flow = fn ->
      result = spec.wire_protocol.visit(session, url)
      _ = LiveViewAware.await_liveview_connected(session)
      result
    end

    maybe_log_check(spec.log_check_interactions?, session, flow)
  end

  @doc """
  Click an element. Consults `spec.browser.click_strategy/0` for the
  flow shape, wraps in log-check when `spec.log_check_interactions?`,
  and respects `spec.patch_url_fallback?` for patch-classified timeouts.
  """
  @spec click(Spec.t(), Element.t()) :: {:ok, term} | {:error, term}
  def click(%Spec{} = spec, %Element{} = element) do
    session = Element.root_session(element)

    maybe_log_check(spec.log_check_interactions?, session, fn ->
      do_click(spec, session, element)
    end)
  end

  @doc "Current URL of the session. Log-checked when the driver opts in via `log_check_accessors?`."
  @spec current_url(Spec.t(), Session.t()) :: {:ok, String.t()} | {:error, term}
  def current_url(%Spec{} = spec, %Session{} = session) do
    maybe_log_check(spec.log_check_accessors?, session, fn ->
      spec.wire_protocol.current_url(session)
    end)
  end

  @doc "Current path of the session — bare delegation, no log-check."
  @spec current_path(Spec.t(), Session.t()) :: {:ok, String.t()} | {:error, term}
  def current_path(%Spec{} = spec, %Session{} = session) do
    spec.wire_protocol.current_path(session)
  end

  @doc "Outer HTML of the session — bare delegation, no log-check."
  @spec page_source(Spec.t(), Session.t()) :: {:ok, String.t()} | {:error, term}
  def page_source(%Spec{} = spec, %Session{} = session) do
    spec.wire_protocol.page_source(session)
  end

  @doc "<title> of the session. Log-checked when the driver opts in via `log_check_accessors?`."
  @spec page_title(Spec.t(), Session.t()) :: {:ok, String.t()} | {:error, term}
  def page_title(%Spec{} = spec, %Session{} = session) do
    maybe_log_check(spec.log_check_accessors?, session, fn ->
      spec.wire_protocol.page_title(session)
    end)
  end

  @doc """
  Take a full-page screenshot. Returns the raw binary so the Driver
  contract is satisfied (callers expect a binary, not `{:ok, binary}`).
  Returns the empty binary on error rather than raising.
  """
  @spec take_screenshot(Spec.t(), Session.t() | Element.t()) :: binary
  def take_screenshot(%Spec{} = spec, %Session{} = session) do
    case spec.wire_protocol.take_screenshot(session) do
      {:ok, binary} -> binary
      _ -> ""
    end
  end

  def take_screenshot(%Spec{} = spec, %Element{} = element) do
    take_screenshot(spec, Element.root_session(element))
  end

  @doc "List cookies for the session's current origin."
  @spec cookies(Spec.t(), Session.t()) :: {:ok, list(map)} | {:error, term}
  def cookies(%Spec{} = spec, %Session{} = session), do: spec.wire_protocol.cookies(session)

  @doc "Set a cookie. Normalises `{:ok, _}` from the underlying RPC to `{:ok, nil}`."
  @spec set_cookie(Spec.t(), Session.t(), String.t(), String.t()) ::
          {:ok, nil} | {:error, term}
  def set_cookie(%Spec{} = spec, %Session{} = session, name, value) do
    spec.wire_protocol.set_cookie(session, name, value) |> normalise_cookie_result()
  end

  @doc "Set a cookie with attributes."
  @spec set_cookie(Spec.t(), Session.t(), String.t(), String.t(), keyword | map) ::
          {:ok, nil} | {:error, term}
  def set_cookie(%Spec{} = spec, %Session{} = session, name, value, attrs) do
    spec.wire_protocol.set_cookie(session, name, value, Map.new(attrs))
    |> normalise_cookie_result()
  end

  defp normalise_cookie_result({:ok, _}), do: {:ok, nil}
  defp normalise_cookie_result(other), do: other

  @doc """
  Window viewport size. Normalises the wire shape (atom keys) to the
  string-keyed map the Wallaby Driver contract expects.
  """
  @spec get_window_size(Spec.t(), Session.t() | Element.t()) ::
          {:ok, %{required(String.t()) => integer}} | {:error, term}
  def get_window_size(%Spec{} = spec, parent) do
    session = Element.root_session(parent)

    case spec.wire_protocol.get_window_size(session) do
      {:ok, %{width: w, height: h}} -> {:ok, %{"width" => w, "height" => h}}
      other -> other
    end
  end

  @doc "Resize the viewport."
  @spec set_window_size(Spec.t(), Session.t() | Element.t(), integer, integer) ::
          {:ok, nil} | {:error, term}
  def set_window_size(%Spec{} = spec, parent, w, h) do
    spec.wire_protocol.set_window_size(Element.root_session(parent), w, h)
  end

  @doc "Evaluate a JS expression. `args` defaults to []."
  @spec execute_script(Spec.t(), Session.t(), String.t(), list | nil) ::
          {:ok, term} | {:error, term}
  def execute_script(%Spec{} = spec, %Session{} = session, script, args) do
    spec.wire_protocol.evaluate(session, script, args || [])
  end

  @doc "Evaluate a JS expression that returns a promise; awaits resolution."
  @spec execute_script_async(Spec.t(), Session.t(), String.t(), list | nil) ::
          {:ok, term} | {:error, term}
  def execute_script_async(%Spec{} = spec, %Session{} = session, script, args) do
    spec.wire_protocol.evaluate_async(session, script, args || [])
  end

  @doc "Text content of an element."
  @spec text(Spec.t(), Element.t()) :: {:ok, String.t()} | {:error, term}
  def text(%Spec{} = spec, %Element{} = element) do
    spec.wire_protocol.text(Element.root_session(element), element)
  end

  @doc "Attribute value (or nil) for an element."
  @spec attribute(Spec.t(), Element.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term}
  def attribute(%Spec{} = spec, %Element{} = element, name) do
    spec.wire_protocol.attribute(Element.root_session(element), element, name)
  end

  @doc "Is the element visible / non-hidden?"
  @spec displayed(Spec.t(), Element.t()) :: {:ok, boolean} | {:error, term}
  def displayed(%Spec{} = spec, %Element{} = element) do
    spec.wire_protocol.displayed(Element.root_session(element), element)
  end

  @doc "Set the value of an input/textarea."
  @spec set_value(Spec.t(), Element.t(), term) :: {:ok, nil} | {:error, term}
  def set_value(%Spec{} = spec, %Element{} = element, value) do
    spec.wire_protocol.set_value(Element.root_session(element), element, value)
  end

  @doc "Clear an input/textarea."
  @spec clear(Spec.t(), Element.t()) :: {:ok, nil} | {:error, term}
  def clear(%Spec{} = spec, %Element{} = element) do
    spec.wire_protocol.clear(Element.root_session(element), element)
  end

  @doc "Find elements matching the query."
  @spec find_elements(Spec.t(), Session.t() | Element.t(), term) ::
          {:ok, list(Element.t())} | {:error, term}
  def find_elements(%Spec{} = spec, parent, query) do
    %Wallabidi.Query{} = q = ensure_query(query)
    spec.wire_protocol.find_elements(parent, q)
  end

  @doc "Send keys to an element."
  @spec send_keys(Spec.t(), Element.t(), list) :: {:ok, nil} | {:error, term}
  def send_keys(%Spec{} = spec, %Element{} = element, keys) do
    spec.wire_protocol.send_keys(Element.root_session(element), element, keys)
  end

  @doc "Is the element checked / selected?"
  @spec selected(Spec.t(), Element.t()) :: {:ok, boolean} | {:error, term}
  def selected(%Spec{} = spec, %Element{} = element) do
    spec.wire_protocol.selected(Element.root_session(element), element)
  end

  # ----- Mouse / touch / geometry — bare delegates -----

  def hover(%Spec{} = spec, element), do: spec.wire_protocol.hover(element)
  def tap(%Spec{} = spec, element), do: spec.wire_protocol.tap(element)

  def touch_down(%Spec{} = spec, parent, target, x, y),
    do: spec.wire_protocol.touch_down(Element.root_session(parent), target, x, y)

  def touch_up(%Spec{} = spec, parent), do: spec.wire_protocol.touch_up(parent)
  def touch_move(%Spec{} = spec, parent, x, y), do: spec.wire_protocol.touch_move(parent, x, y)

  def click_at_cursor(%Spec{} = spec, parent, button)
      when button in [:left, :middle, :right],
      do: spec.wire_protocol.click_at_cursor(parent, button)

  def double_click(%Spec{} = spec, parent), do: spec.wire_protocol.double_click(parent)

  def button_down(%Spec{} = spec, parent, button),
    do: spec.wire_protocol.button_down(parent, button)

  def button_up(%Spec{} = spec, parent, button), do: spec.wire_protocol.button_up(parent, button)

  def move_mouse_by(%Spec{} = spec, parent, x_offset, y_offset),
    do: spec.wire_protocol.move_mouse_by(parent, x_offset, y_offset)

  def element_size(%Spec{} = spec, element), do: spec.wire_protocol.element_size(element)
  def element_location(%Spec{} = spec, element), do: spec.wire_protocol.element_location(element)
  def blank_page?(%Spec{} = spec, session), do: spec.wire_protocol.blank_page?(session)

  defp ensure_query(%Wallabidi.Query{} = q), do: q

  defp ensure_query({type, selector}) when type in [:css, :xpath] and is_binary(selector) do
    Wallabidi.Query.css(selector)
  end

  defp maybe_log_check(true, session, flow), do: check_logs!(session, flow)
  defp maybe_log_check(false, _session, flow), do: flow.()

  defp do_click(%Spec{browser: browser} = spec, session, element) do
    case browser.click_strategy() do
      :simple ->
        spec.wire_protocol.click(session, element)

      :classified ->
        case spec.wire_protocol.click_aware_with_classification(session, element) do
          {:ok, _classification, :ready} ->
            {:ok, nil}

          {:ok, classification, :timeout} when classification in ["navigate", "full_page"] ->
            # data-phx-link=redirect / JS.navigate-classified clicks raise
            # NavigationTimeoutError on page_ready timeout — those tests
            # explicitly catch the error.
            raise_navigation_timeout(spec, session, 5_000)

          {:ok, "patch", :timeout} ->
            # Patch-classified timeout: caller's assert_has retries will
            # take it from here. ChromeCDP additionally polls current_url
            # to ride out a slow LV handle_event before returning.
            if spec.patch_url_fallback? do
              _ = await_url_change_or_load(spec, session, 10_000)
            end

            {:ok, nil}

          {:ok, _classification, :timeout} ->
            {:ok, nil}

          err ->
            err
        end
    end
  end

  defp raise_navigation_timeout(%Spec{} = spec, session, timeout_ms) do
    post =
      case spec.wire_protocol.current_url(session) do
        {:ok, url} -> url
        _ -> nil
      end

    raise Wallabidi.NavigationTimeoutError, %{
      from: nil,
      to: post,
      timeout_ms: timeout_ms,
      page_state: :unknown,
      page_state_history: []
    }
  end

  defp await_url_change_or_load(%Spec{} = spec, %Session{} = session, timeout_ms) do
    pre_url =
      case spec.wire_protocol.current_url(session) do
        {:ok, url} -> url
        _ -> nil
      end

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_url(spec, session, pre_url, deadline)
  end

  defp poll_url(%Spec{} = spec, session, pre_url, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :timeout
    else
      case spec.wire_protocol.current_url(session) do
        {:ok, url} when url != pre_url and url != "" ->
          :ok

        _ ->
          Process.sleep(50)
          poll_url(spec, session, pre_url, deadline)
      end
    end
  end
end
