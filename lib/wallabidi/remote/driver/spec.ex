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
    # Wrap visit/click in check_logs! to drain console + exception events
    # into JSError raises. Both Chrome drivers set true; Lightpanda false.
    log_check_interactions?: false
  ]

  @type t :: %__MODULE__{
          browser: module,
          wire_protocol: module,
          dialogs: module,
          windows: module,
          frames: module,
          touch_scroll:
            (Wallabidi.Element.t(), number, number -> {:ok, nil} | {:error, term}) | nil,
          log_check_interactions?: boolean
        }
end
