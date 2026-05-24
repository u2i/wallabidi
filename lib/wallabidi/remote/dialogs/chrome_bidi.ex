defmodule Wallabidi.Remote.Dialogs.ChromeBiDi do
  @moduledoc false

  # BiDi dialog handling. Uses `browsingContext.userPromptOpened`
  # events and `browsingContext.handleUserPrompt` to reply.
  # Orchestration lives in Dialogs.Flow; this module supplies the
  # 3 protocol primitives.

  @behaviour Wallabidi.Remote.Dialogs

  alias Wallabidi.Remote.BiDi.{Commands, ResponseParser, WebSocketClient}
  alias Wallabidi.Remote.Dialogs.Flow
  alias Wallabidi.Session

  @impl true
  def accept_alert(session, fun), do: run(session, fun, true, nil)

  @impl true
  def accept_confirm(session, fun), do: run(session, fun, true, nil)

  @impl true
  def accept_prompt(session, text, fun), do: run(session, fun, true, text)

  @impl true
  def dismiss_confirm(session, fun), do: run(session, fun, false, nil)

  @impl true
  def dismiss_prompt(session, fun), do: run(session, fun, false, nil)

  defp run(session, fun, accept, prompt_text),
    do: Flow.run(flow(), session, accept, prompt_text, fun)

  defp flow do
    %Flow{
      subscribe: &subscribe/1,
      await_event: &await_event/2,
      reply: &reply/3
    }
  end

  defp subscribe(%Session{bidi_pid: ws_pid, browsing_context: ctx}) do
    # Scope to the session's browsing context so a sibling test's
    # dialog can't land in our handler. chromium-bidi makes the
    # session.subscribe call idempotent.
    {sub_method, sub_params} =
      Commands.subscribe(["browsingContext.userPromptOpened"], [ctx])

    WebSocketClient.send_command(ws_pid, sub_method, sub_params)
    WebSocketClient.subscribe(ws_pid, "browsingContext.userPromptOpened", self(), ctx)
  end

  defp await_event(%Session{}, timeout_ms) do
    receive do
      {:bidi_event, "browsingContext.userPromptOpened", event} ->
        msg = get_in(event, ["params", "message"]) || ""
        default = get_in(event, ["params", "defaultValue"])
        {msg, default}
    after
      timeout_ms -> {"", nil}
    end
  end

  defp reply(%Session{bidi_pid: ws_pid, browsing_context: ctx}, accept, effective_text) do
    {m, p} = Commands.handle_user_prompt(ctx, accept, effective_text)
    WebSocketClient.send_command(ws_pid, m, p) |> ResponseParser.check_error()
  end
end
