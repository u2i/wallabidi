defmodule Wallabidi.Remote.Windows do
  @moduledoc false

  # Multi-window / tab management. One of the vendor-specific dimensions
  # of a driver Spec.
  #
  #   * `ChromeCDP`     — uses CDP `Target.*` against the shared WS to
  #                       enumerate / attach / close tabs in this session's
  #                       browser context.
  #   * `ChromeBiDi`    — uses BiDi `browsingContext.*` plus per-process
  #                       state for "which window am I focused on".
  #   * `SingleWindow`  — Lightpanda / no-window-management backends.
  #                       Returns "main" as the single handle.

  alias Wallabidi.{Element, Session}

  @callback window_handle(Session.t() | Element.t()) :: {:ok, String.t() | nil}
  @callback window_handles(Session.t() | Element.t()) :: {:ok, list(String.t())}
  @callback focus_window(Session.t() | Element.t(), String.t()) :: {:ok, nil} | {:error, term}
  @callback close_window(Session.t() | Element.t()) :: {:ok, nil} | {:error, term}
end
