defmodule Wallabidi.Remote.Dialogs.ChromeBiDi do
  @moduledoc false

  @behaviour Wallabidi.Remote.Dialogs

  alias Wallabidi.Remote.BiDi.Client, as: BiDiClient

  @impl true
  def accept_alert(session, fun), do: BiDiClient.accept_alert(session, fun)

  @impl true
  def accept_confirm(session, fun), do: BiDiClient.accept_confirm(session, fun)

  @impl true
  def accept_prompt(session, text, fun), do: BiDiClient.accept_prompt(session, text, fun)

  @impl true
  def dismiss_confirm(session, fun), do: BiDiClient.dismiss_confirm(session, fun)

  @impl true
  def dismiss_prompt(session, fun), do: BiDiClient.dismiss_prompt(session, fun)
end
