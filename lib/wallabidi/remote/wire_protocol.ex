defmodule Wallabidi.Remote.WireProtocol do
  @moduledoc false

  # One of the three dimensions of a driver Spec: the wire protocol
  # (CDP vs BiDi). Owns the answers to "how do I encode/decode RPCs"
  # questions.
  #
  # Implementations are thin behaviour-shaped wrappers around the
  # existing per-protocol client modules (Wallabidi.Remote.CDP.Client,
  # Wallabidi.Remote.BiDi.Client) — those remain the source of truth
  # for the actual wire shapes.
  #
  # Eventually this should absorb / replace `Wallabidi.Remote.Protocol`
  # (which is the existing hand-rolled `case driver do` dispatcher for
  # eval/eval_async/current_url). For now kept separate; consolidation
  # is a follow-up once Orchestrator absorbs more callbacks.

  alias Wallabidi.{Element, Session}

  @doc "Navigate the session's top-level browsing context to `url`."
  @callback visit(Session.t(), String.t()) :: {:ok, term} | {:error, term}

  @doc "Current URL of the session's top-level browsing context."
  @callback current_url(Session.t()) :: {:ok, String.t()} | {:error, term}

  @doc "Current path (URL minus host) of the session."
  @callback current_path(Session.t()) :: {:ok, String.t()} | {:error, term}

  @doc "Outer HTML of the session's current document."
  @callback page_source(Session.t()) :: {:ok, String.t()} | {:error, term}

  @doc "<title> of the session's current document."
  @callback page_title(Session.t()) :: {:ok, String.t()} | {:error, term}

  @doc "Take a full-page screenshot. Returns raw bytes or {:error, _}."
  @callback take_screenshot(Session.t()) :: {:ok, binary} | {:error, term}

  @doc "List all cookies for the session's current origin."
  @callback cookies(Session.t()) :: {:ok, list(map)} | {:error, term}

  @doc "Set a cookie. Returns the raw RPC result; orchestrator normalises."
  @callback set_cookie(Session.t(), String.t(), String.t()) :: {:ok, term} | {:error, term}

  @doc "Set a cookie with attributes."
  @callback set_cookie(Session.t(), String.t(), String.t(), map) ::
              {:ok, term} | {:error, term}

  @doc "Window viewport size as a map with :width / :height (atom keys)."
  @callback get_window_size(Session.t()) ::
              {:ok, %{width: integer, height: integer}} | {:error, term}

  @doc "Resize the window viewport."
  @callback set_window_size(Session.t(), integer, integer) :: {:ok, nil} | {:error, term}

  @doc "Evaluate JS. Returns the value."
  @callback execute_script(Session.t(), String.t(), list) :: {:ok, term} | {:error, term}

  @doc "Evaluate JS that returns a promise; awaits resolution."
  @callback execute_script_async(Session.t(), String.t(), list) :: {:ok, term} | {:error, term}

  @doc """
  Simple click RPC — no classification, no page-ready await.
  """
  @callback simple_click(Session.t(), Element.t()) :: {:ok, term} | {:error, term}

  @doc """
  Classified click — captures pre_page_id, classifies the target
  (navigate/full_page/patch/none), issues the click, awaits page_ready
  with a 5s timeout. Returns `{:ok, classification, :ready | :timeout}`
  or `{:error, term}`.
  """
  @callback classified_click(Session.t(), Element.t()) ::
              {:ok, String.t(), :ready | :timeout} | {:error, term}

  @doc "Text content of an element."
  @callback text(Session.t(), Element.t()) :: {:ok, String.t()} | {:error, term}

  @doc "Attribute value (or nil) for an element."
  @callback attribute(Session.t(), Element.t(), String.t()) ::
              {:ok, String.t() | nil} | {:error, term}

  @doc "Is the element visible / non-hidden?"
  @callback displayed(Session.t(), Element.t()) :: {:ok, boolean} | {:error, term}

  @doc "Set the value of an input/textarea."
  @callback set_value(Session.t(), Element.t(), term) :: {:ok, nil} | {:error, term}

  @doc "Clear an input/textarea."
  @callback clear(Session.t(), Element.t()) :: {:ok, nil} | {:error, term}

  @doc "Find elements matching the query."
  @callback find_elements(Session.t() | Element.t(), term) ::
              {:ok, list(Element.t())} | {:error, term}

  @doc "Send keys to an element."
  @callback send_keys(Session.t(), Element.t(), list) :: {:ok, nil} | {:error, term}

  @doc "Is the element checked (checkbox / radio) or selected (option)?"
  @callback selected(Session.t(), Element.t()) :: {:ok, boolean} | {:error, term}

  # ----- Mouse / touch / geometry -----

  @callback hover(Element.t()) :: {:ok, nil} | {:error, term}
  @callback tap(Element.t()) :: {:ok, nil} | {:error, term}
  @callback touch_down(Session.t() | Element.t(), term, number, number) ::
              {:ok, nil} | {:error, term}
  @callback touch_up(Session.t() | Element.t()) :: {:ok, nil} | {:error, term}
  @callback touch_move(Session.t() | Element.t(), number, number) ::
              {:ok, nil} | {:error, term}
  @callback click_at_cursor(Session.t() | Element.t(), :left | :middle | :right) ::
              {:ok, nil} | {:error, term}
  @callback double_click(Session.t() | Element.t()) :: {:ok, nil} | {:error, term}
  @callback button_down(Session.t() | Element.t(), atom) :: {:ok, nil} | {:error, term}
  @callback button_up(Session.t() | Element.t(), atom) :: {:ok, nil} | {:error, term}
  @callback move_mouse_by(Session.t() | Element.t(), number, number) ::
              {:ok, nil} | {:error, term}
  @callback element_size(Element.t()) :: {:ok, map} | {:error, term}
  @callback element_location(Element.t()) :: {:ok, map} | {:error, term}
  @callback blank_page?(Session.t()) :: boolean
end
