defmodule Wallabidi.Remote.Driver.Spec do
  @moduledoc false

  # A driver-as-data: five orthogonal dimension modules plus per-driver
  # cross-cutting flags. `Driver.Generic` and the `Orchestrator` read
  # from this struct to dispatch each Driver callback to the right places.
  #
  # Stamped onto `Session.driver_spec` at start_session time; from then
  # on, the session is fully described by its Spec.

  defstruct [
    # Dimension modules — each one is a behaviour impl that varies
    # per driver.
    :browser,
    :wire_protocol,
    :dialogs,
    :windows,
    :frames,
    # Per-driver one-off: touch_scroll has three distinct implementations
    # (CDP synthesizeScrollGesture / BiDi JS scrollBy / Lightpanda no-op)
    # that don't justify their own behaviour. Function of (element, dx, dy).
    :touch_scroll,
    # ChromeCDP fallback: poll current_url after a patch-classified click
    # timeout to ride out a slow LiveView handle_event. Only ChromeCDP
    # sets this true today.
    patch_url_fallback?: false,
    # Wrap visit/click in check_logs! to drain console + exception events
    # into JSError raises. Both Chrome drivers set true; Lightpanda false.
    log_check_interactions?: false,
    # Additionally wrap simple accessors (current_url, page_title) in
    # check_logs!. Only ChromeBiDi does this today — ChromeCDP doesn't.
    # Marked separately so we don't silently change ChromeCDP's behaviour.
    log_check_accessors?: false
  ]

  @type t :: %__MODULE__{
          browser: module,
          wire_protocol: module,
          dialogs: module,
          windows: module,
          frames: module,
          touch_scroll:
            (Wallabidi.Element.t(), number, number -> {:ok, nil} | {:error, term}) | nil,
          patch_url_fallback?: boolean,
          log_check_interactions?: boolean,
          log_check_accessors?: boolean
        }
end
