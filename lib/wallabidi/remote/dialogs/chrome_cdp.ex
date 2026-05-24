defmodule Wallabidi.Remote.Dialogs.ChromeCDP do
  @moduledoc false

  @behaviour Wallabidi.Remote.Dialogs

  alias Wallabidi.Remote.CDP.Client, as: CDPClient

  @impl true
  def accept_alert(session, fun), do: CDPClient.handle_dialog(session, fun, true)

  @impl true
  def accept_confirm(session, fun), do: CDPClient.handle_dialog(session, fun, true)

  @impl true
  def accept_prompt(session, text, fun), do: CDPClient.handle_dialog(session, fun, true, text)

  @impl true
  def dismiss_confirm(session, fun), do: CDPClient.handle_dialog(session, fun, false)

  @impl true
  def dismiss_prompt(session, fun), do: CDPClient.handle_dialog(session, fun, false)
end
