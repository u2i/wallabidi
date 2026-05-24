defmodule Wallabidi.Remote.Browser do
  @moduledoc false

  # One of the three dimensions of a driver Spec: the vendor (Chrome,
  # Lightpanda). Owns the answers to "how does this browser behave"
  # questions that aren't determined by the protocol (CDP vs BiDi) or
  # the WS topology (shared vs per-session).
  #
  # SPIKE SCOPE: only the knobs needed by Orchestrator.click. We'll
  # grow this as we route more callbacks through Orchestrator.

  @doc """
  Click strategy:

    * `:classified` — capture pre_page_id, classify the click target
      (navigate/full_page/patch/none), issue the click, await
      page_ready. Used by Chrome (CDP and BiDi).
    * `:simple` — single click RPC, no flow. Used by Lightpanda.
  """
  @callback click_strategy() :: :classified | :simple
end
