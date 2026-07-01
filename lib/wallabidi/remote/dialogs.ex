defmodule Wallabidi.Remote.Dialogs do
  @moduledoc false

  # JavaScript dialog handling (alert/confirm/prompt). One of the
  # vendor-specific dimensions of a driver Spec. Three impls today:
  # ChromeCDP (uses CDP Page.handleJavaScriptDialog), ChromeBiDi (uses
  # BiDi browsingContext.handleUserPrompt), Unsupported (Lightpanda —
  # the JS engine doesn't surface dialogs to CDP; calls the fun and
  # returns empty text).

  alias Wallabidi.Session

  @callback accept_alert(Session.t(), (Session.t() -> any)) :: String.t() | {:ok, term}
  @callback accept_confirm(Session.t(), (Session.t() -> any)) :: String.t() | {:ok, term}
  @callback accept_prompt(Session.t(), String.t() | nil, (Session.t() -> any)) ::
              String.t() | {:ok, term}
  @callback dismiss_confirm(Session.t(), (Session.t() -> any)) :: String.t() | {:ok, term}
  @callback dismiss_prompt(Session.t(), (Session.t() -> any)) :: String.t() | {:ok, term}
end
