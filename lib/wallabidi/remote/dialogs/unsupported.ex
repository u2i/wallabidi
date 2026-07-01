defmodule Wallabidi.Remote.Dialogs.Unsupported do
  @moduledoc false

  # Stub used by drivers whose underlying browser doesn't surface JS
  # dialogs (currently just Lightpanda). Calls the user's fun against
  # the session and returns the empty string — matches the
  # `:browser`-tagged dialog tests' "if dialogs aren't supported just
  # don't raise" contract.

  @behaviour Wallabidi.Remote.Dialogs

  @impl true
  def accept_alert(session, fun) do
    fun.(session)
    ""
  end

  @impl true
  def accept_confirm(session, fun) do
    fun.(session)
    ""
  end

  @impl true
  def accept_prompt(session, _text, fun) do
    fun.(session)
    ""
  end

  @impl true
  def dismiss_confirm(session, fun) do
    fun.(session)
    ""
  end

  @impl true
  def dismiss_prompt(session, fun) do
    fun.(session)
    ""
  end
end
