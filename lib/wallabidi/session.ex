defmodule Wallabidi.Session do
  @moduledoc """
  Struct containing details about the webdriver session.
  """

  @typedoc """
  Deferred patch-await state, stashed when an interaction is invoked
  with `await: :defer`. Consumed by `Wallabidi.LiveView.await_patch/2`.

    * `{:page_ready_after, pre_page_id}` — the click captured a
      pre-click page id; await the next `page_ready` notification.
    * `:armed` — `prepare_patch` was called, but no pre-click id
      exists (e.g. `fill_in` deferred); resolve via the existing
      `__wallabidi_patch_promise` machinery.
  """
  @type pending_await :: nil | {:page_ready_after, String.t() | nil} | :armed

  @type t :: %__MODULE__{
          id: String.t(),
          pid: pid() | nil,
          session_url: String.t(),
          url: String.t(),
          server: pid | :none | module,
          screenshots: list,
          driver: module,
          driver_spec: struct() | nil,
          capabilities: map(),
          bidi_pid: pid() | nil,
          browsing_context: String.t() | nil,
          metadata: map() | nil,
          pending_await: pending_await
        }

  defstruct [
    :id,
    :pid,
    :url,
    :session_url,
    :driver,
    :driver_spec,
    :capabilities,
    :bidi_pid,
    :browsing_context,
    :metadata,
    server: :none,
    screenshots: [],
    pending_await: nil
  ]
end
