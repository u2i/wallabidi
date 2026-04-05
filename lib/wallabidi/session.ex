defmodule Wallabidi.Session do
  @moduledoc """
  Struct containing details about the webdriver session.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          pid: pid() | nil,
          session_url: String.t(),
          url: String.t(),
          server: pid | :none,
          screenshots: list,
          driver: module,
          protocol: module | nil,
          capabilities: map(),
          bidi_pid: pid() | nil,
          browsing_context: String.t() | nil
        }

  defstruct [
    :id,
    :pid,
    :url,
    :session_url,
    :driver,
    :protocol,
    :capabilities,
    :bidi_pid,
    :browsing_context,
    :metadata,
    server: :none,
    screenshots: []
  ]
end
