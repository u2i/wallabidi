defmodule Wallabidi.Remote.Frames do
  @moduledoc false

  # IFrame focus management. One of the vendor-specific dimensions of
  # a driver Spec.
  #
  #   * `ChromeCDP`     — CDP DOM.describeNode + focus_frame_by_id
  #                       (tracks frame executionContextIds on the actor)
  #   * `ChromeBiDi`    — BiDi child_context_for_iframe + per-process
  #                       state for "current focused context"
  #   * `Unsupported`   — Lightpanda (no iframe support)

  alias Wallabidi.{Element, Session}

  @callback focus_frame(Session.t(), Element.t() | nil) :: {:ok, nil} | {:error, term}
  @callback focus_parent_frame(Session.t()) :: {:ok, nil} | {:error, term}
end
