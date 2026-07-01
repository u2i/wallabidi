defmodule Wallabidi.Remote.Wire.CDP do
  @moduledoc false

  # CDP wire-level event decoder shared by the two CDP transport actors:
  #
  #   * `Wallabidi.Remote.Transport.Session` (Chrome CDP, shared WS)
  #   * `Wallabidi.Remote.Transport.PerSession.Actor` (Lightpanda, per-session WS)
  #
  # Both subscribe to the same handful of CDP events and translate them
  # into state-machine updates handled by `Wallabidi.Remote.Transport.Common`.
  # Decoding the events lives here so the two actors stop carrying
  # byte-identical clauses.
  #
  # `handle_event/3` is a pure function over the actor's state map; the
  # actor wraps the return value in `{:noreply, state}` (Session) or
  # threads it through its WS-frame loop (PerSession.Actor).

  alias Wallabidi.Remote.Transport.Common

  @doc """
  Decodes one CDP event for an actor's state. Returns the new state.

  Recognised events:

    * `Page.lifecycleEvent` — record `(loaderId, milestone)` so any
      matching load waiter wakes immediately (or the milestone buffers
      for a later caller).
    * `Runtime.bindingCalled` — bootstrap channel; routed to
      `Common.route_bootstrap_payload/2` when the binding name matches.
    * `Runtime.executionContextCreated` — record `frameId → contextId`.
    * `Runtime.executionContextDestroyed` — purge the destroyed context.

  Unknown methods are a no-op.
  """
  @spec handle_event(map(), String.t(), map()) :: map()
  def handle_event(state, method, event)

  def handle_event(state, "Page.lifecycleEvent", event) do
    params = Map.get(event, "params", %{})
    loader_id = params["loaderId"]
    name = params["name"]

    if is_binary(loader_id) and name in ["load", "DOMContentLoaded"] do
      Common.record_load_milestone(state, loader_id, name)
    else
      state
    end
  end

  def handle_event(state, "Runtime.bindingCalled", event) do
    params = Map.get(event, "params", %{})

    if params["name"] == "__wallabidi" and is_binary(params["payload"]) do
      Common.route_bootstrap_payload(state, params["payload"])
    else
      state
    end
  end

  def handle_event(state, "Runtime.executionContextCreated", event) do
    ctx = get_in(event, ["params", "context"]) || %{}
    aux = Map.get(ctx, "auxData", %{})
    context_id = ctx["id"]
    frame_id = aux["frameId"]

    if is_integer(context_id) and is_binary(frame_id) do
      %{state | frame_contexts: Map.put(state.frame_contexts, frame_id, context_id)}
    else
      state
    end
  end

  def handle_event(state, "Runtime.executionContextDestroyed", event) do
    destroyed = get_in(event, ["params", "executionContextId"])

    if is_integer(destroyed) do
      contexts =
        state.frame_contexts
        |> Enum.reject(fn {_frame_id, ctx_id} -> ctx_id == destroyed end)
        |> Map.new()

      %{state | frame_contexts: contexts}
    else
      state
    end
  end

  def handle_event(state, _method, _event), do: state
end
