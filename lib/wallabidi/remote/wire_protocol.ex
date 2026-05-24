defmodule Wallabidi.Remote.WireProtocol do
  @moduledoc false

  # One of the three dimensions of a driver Spec: the wire protocol
  # (CDP vs BiDi). Owns the answers to "how do I encode/decode RPCs"
  # questions.
  #
  # Implementations are thin behaviour-shaped wrappers around the
  # existing per-protocol client modules (Wallabidi.Remote.CDP.Client,
  # Wallabidi.Remote.BiDi.Client) — those remain the source of truth
  # for the actual wire shapes.
  #
  # Eventually this should absorb / replace `Wallabidi.Remote.Protocol`
  # (which is the existing hand-rolled `case driver do` dispatcher for
  # eval/eval_async/current_url). For the spike, kept separate.
  #
  # SPIKE SCOPE: only the RPCs needed by Orchestrator.click.

  alias Wallabidi.{Element, Session}

  @doc """
  Simple click RPC — no classification, no page-ready await.
  """
  @callback simple_click(Session.t(), Element.t()) :: {:ok, term} | {:error, term}

  @doc """
  Classified click — captures pre_page_id, classifies the target
  (navigate/full_page/patch/none), issues the click, awaits page_ready
  with a 5s timeout. Returns `{:ok, classification, :ready | :timeout}`
  or `{:error, term}`.
  """
  @callback classified_click(Session.t(), Element.t()) ::
              {:ok, String.t(), :ready | :timeout} | {:error, term}

  @doc "Current URL — used by the patch-fallback URL polling loop."
  @callback current_url(Session.t()) :: {:ok, String.t()} | {:error, term}
end
