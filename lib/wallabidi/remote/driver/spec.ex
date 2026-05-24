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
    patch_url_fallback?: false
  ]

  @type t :: %__MODULE__{
          browser: module,
          wire_protocol: module,
          patch_url_fallback?: boolean
        }
end
