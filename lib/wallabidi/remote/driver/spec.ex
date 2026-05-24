defmodule Wallabidi.Remote.Driver.Spec do
  @moduledoc false

  # A driver-as-data: the three orthogonal dimension modules plus any
  # per-driver cross-cutting flags. The Orchestrator reads from this
  # struct to dispatch each Driver callback to the right places.
  #
  # SPIKE SCOPE: only the fields needed by Orchestrator.click.
  # The `patch_url_fallback?` flag exists because the patch-classified
  # timeout polling behaviour belongs to ChromeCDP specifically, not
  # to all of Chrome (ChromeBiDi doesn't do it).

  defstruct [
    :browser,
    :wire_protocol,
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
          patch_url_fallback?: boolean,
          log_check_interactions?: boolean,
          log_check_accessors?: boolean
        }
end
