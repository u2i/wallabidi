defmodule Wallabidi.Remote.Dialogs.Flow do
  @moduledoc false

  # Protocol-agnostic dialog orchestration. Both Page.javascriptDialogOpening
  # (CDP) and browsingContext.userPromptOpened (BiDi) follow the same
  # shape:
  #
  #   1. Pre-subscribe to the dialog event.
  #   2. Spawn a handler process.
  #   3. The handler installs its own subscription, signals ready (BiDi
  #      only — CDP's subscription is already in place), and waits for
  #      the dialog event.
  #   4. The caller triggers the dialog via `fun.(session)`.
  #   5. The handler decodes the event, computes the effective reply
  #      text (user-supplied or browser default), and fires the reply
  #      RPC.
  #   6. The handler sends `{:dialog_handled, message}` to the caller.
  #   7. The caller returns the message string.
  #
  # The protocol differences (pre-subscribe mechanism, event envelope,
  # default-text key, reply RPC, subscription-sync requirement) are
  # captured in a small `t()` of callbacks passed in by the protocol's
  # Dialogs.X impl.

  alias Wallabidi.Session

  @type t :: %__MODULE__{
          # Set up the dialog-event subscription before `fun` fires.
          # Called from the caller's process. Idempotent.
          subscribe: (Session.t() -> any),
          # Receive the dialog event in the handler process, decode it.
          # Returns `{message, default_text}` or `{"", nil}` on timeout.
          await_event: (Session.t(), pos_integer -> {String.t(), String.t() | nil}),
          # Fire the reply RPC. Called from the handler process.
          reply: (Session.t(), boolean, String.t() | nil -> any),
          # If true, the caller waits for the handler to signal `:ready`
          # before invoking `fun`. BiDi needs this because the WSC
          # subscription is async; CDP's per-protocol subscribe is
          # synchronous.
          sync_handler_ready?: boolean
        }
  defstruct subscribe: nil, await_event: nil, reply: nil, sync_handler_ready?: false

  @doc """
  Run the dialog flow. Returns the dialog message string.

  `accept` selects accept-vs-dismiss. `prompt_text` is the optional
  text for prompts (nil = use the browser default / no text for non-prompts).
  """
  @spec run(t(), Session.t(), boolean, String.t() | nil, (Session.t() -> any)) :: String.t()
  def run(%__MODULE__{} = flow, %Session{} = session, accept, prompt_text, fun)
      when is_boolean(accept) and is_function(fun, 1) do
    caller = self()

    flow.subscribe.(session)

    handler =
      spawn_link(fn ->
        if flow.sync_handler_ready? do
          flow.subscribe.(session)
          send(caller, {:ready, self()})
        end

        {message, default_value} = flow.await_event.(session, 5_000)
        effective_text = prompt_text || default_value
        flow.reply.(session, accept, effective_text)
        send(caller, {:dialog_handled, message})
      end)

    if flow.sync_handler_ready? do
      receive do
        {:ready, ^handler} -> :ok
      after
        1_000 -> :ok
      end
    end

    fun.(session)

    message =
      receive do
        {:dialog_handled, msg} -> msg
      after
        10_000 -> ""
      end

    Process.unlink(handler)
    message
  end
end
