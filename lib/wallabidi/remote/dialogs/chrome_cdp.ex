defmodule Wallabidi.Remote.Dialogs.ChromeCDP do
  @moduledoc false

  # CDP dialog handling. Uses `Page.javascriptDialogOpening` events
  # and `Page.handleJavaScriptDialog` to reply. The orchestration
  # (spawn handler, await event, run user fun, reply) lives in
  # Dialogs.Flow; this module just supplies the 3 protocol primitives.

  @behaviour Wallabidi.Remote.Dialogs

  alias Wallabidi.Remote.CDP.Client, as: CDPClient
  alias Wallabidi.Remote.Dialogs.Flow
  alias Wallabidi.Remote.WebSocket
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
      reply: &reply/3,
      # CDP's subscribe is synchronous (Page.enable + WS.subscribe),
      # so no handler-ready sync needed.
      sync_handler_ready?: false
    }
  end

  defp subscribe(%Session{} = session) do
    # Page domain must be enabled for javascriptDialogOpening to fire.
    _ = CDPClient.cdp_send(session, "Page.enable", %{})
    ctx = session.browsing_context || :global
    :ok = WebSocket.subscribe(session.bidi_pid, "Page.javascriptDialogOpening", ctx, self())
  end

  defp await_event(%Session{}, timeout_ms) do
    receive do
      {:v2_event, "Page.javascriptDialogOpening", event} ->
        msg = get_in(event, ["params", "message"]) || ""
        default = get_in(event, ["params", "defaultPrompt"])
        {msg, default}
    after
      timeout_ms -> {"", nil}
    end
  end

  defp reply(%Session{} = session, accept, effective_text) do
    params = %{accept: accept}

    params =
      if is_binary(effective_text),
        do: Map.put(params, :promptText, effective_text),
        else: params

    CDPClient.cdp_send(session, "Page.handleJavaScriptDialog", params)
  end
end
