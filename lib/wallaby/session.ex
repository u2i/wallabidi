defmodule Wallaby.Session do
  @moduledoc """
  Struct containing details about the webdriver session.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          session_url: String.t(),
          url: String.t(),
          server: pid | :none,
          screenshots: list,
          driver: module,
          capabilities: map(),
          bidi_pid: pid() | nil,
          browsing_context: String.t() | nil
        }

  defstruct [
    :id,
    :url,
    :session_url,
    :driver,
    :capabilities,
    :bidi_pid,
    :browsing_context,
    server: :none,
    screenshots: []
  ]
end
