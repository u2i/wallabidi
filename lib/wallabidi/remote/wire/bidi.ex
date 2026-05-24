defmodule Wallabidi.Remote.Wire.BiDi do
  @moduledoc false

  # BiDi wire-level event decoder used by
  # `Wallabidi.Remote.Transport.BiDi.SessionActor`. BiDi events arrive
  # pre-decoded as `{:bidi_event, method, event}` messages from the
  # `BiDi.WebSocketClient`.
  #
  # `handle_event/3` is a pure function over the actor's state map.

  alias Wallabidi.Remote.Transport.Common

  @doc """
  Decodes one BiDi event for an actor's state. Returns the new state.

  Recognised events:

    * `browsingContext.load` / `browsingContext.domContentLoaded` —
      navigation milestones; either wake a matching load waiter or
      buffer the milestone (BiDi one-shot semantics).
    * `script.message` — bootstrap channel; routed to
      `Common.route_bootstrap_payload/2` when the channel name matches.

  Unknown methods are a no-op.
  """
  @spec handle_event(map(), String.t(), map()) :: map()
  def handle_event(state, method, event)

  def handle_event(state, "browsingContext.load", event) do
    record_milestone(state, event, "load")
  end

  def handle_event(state, "browsingContext.domContentLoaded", event) do
    record_milestone(state, event, "DOMContentLoaded")
  end

  def handle_event(state, "script.message", event) do
    params = Map.get(event, "params", %{})

    if params["channel"] == "__wallabidi" do
      payload = get_in(params, ["data", "value"]) || ""
      Common.route_bootstrap_payload(state, payload)
    else
      state
    end
  end

  def handle_event(state, _method, _event), do: state

  defp record_milestone(state, event, milestone) do
    nav = get_in(event, ["params", "navigation"])

    if is_binary(nav) do
      Common.record_load_or_wake_once(state, nav, milestone)
    else
      state
    end
  end
end
