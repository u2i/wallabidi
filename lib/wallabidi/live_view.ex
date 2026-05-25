defmodule Wallabidi.LiveView do
  @moduledoc """
  Helpers for testing LiveView pages where you need to observe state
  *during* a server round-trip — not just after it completes.

  The default Wallabidi interaction primitives (`click/2`, `fill_in/3`,
  etc.) auto-await the LiveView patch resulting from each action.
  That's the right behavior for ordinary tests: you don't have to
  think about timing, and your assertions see the post-reconciliation
  DOM.

  But some LiveView features — optimistic UI, client-side hooks that
  patch the DOM before the server reply lands, multi-step animations
  — have observable intermediate states. To test those, you need to:

    1. Slow down the server reply so the optimistic phase is reliably
       observable (this module's `set_latency/2` / `with_latency/3`).
    2. Skip the auto-await on the triggering interaction so the test
       can assert on the optimistic-phase DOM (`await: :defer` opt on
       interaction primitives).
    3. Explicitly await the patch later, before the post-reconcile
       assertions (`Wallabidi.LiveView.await_patch/2`).

  ## Example

      session
      |> visit("/counter")
      |> Wallabidi.LiveView.with_latency(500, fn s ->
        s
        |> click(Query.button("Increment"), await: :defer)
        |> assert_has(Query.css("#count", text: "1"))   # optimistic
        |> Wallabidi.LiveView.await_patch()
        |> assert_has(Query.css("#count", text: "1"))   # reconciled
      end)

  ## Driver compatibility

  All three remote drivers (Chrome BiDi, Chrome CDP, Lightpanda CDP)
  support latency simulation and deferred awaits.

  The in-process LiveView driver renders synchronously — there's no
  network round-trip to delay, and no patch lifecycle to defer. On
  that driver, latency helpers are no-ops and `await: :defer` is
  treated as `await: :auto` (the interaction completes synchronously
  and the patch has already landed by the time the call returns).
  Tests that depend on observing the optimistic phase should run on
  a remote driver.
  """

  alias Wallabidi.Browser
  alias Wallabidi.Remote.LiveViewAware
  alias Wallabidi.Remote.Protocol
  alias Wallabidi.Remote.Transport.Protocol, as: TransportProtocol
  alias Wallabidi.Session

  # ----- Latency simulation -----

  @doc """
  Enables LiveView's built-in latency simulator. Every push and every
  receive callback is wrapped in `setTimeout(cb, latency)`, stretching
  the round-trip to `latency_ms`.

  Useful for making the optimistic-UI phase reliably observable. A
  latency of 300–500 ms is usually plenty: long enough that an
  `assert_has` between the click and the `await_patch/2` is virtually
  certain to land during the in-flight phase.

  No-op on the in-process LiveView driver.

  Pair with `clear_latency/1` or use `with_latency/3` to scope the
  simulation to a block.
  """
  @spec set_latency(Session.t(), non_neg_integer()) :: Session.t()
  def set_latency(%Session{} = session, latency_ms)
      when is_integer(latency_ms) and latency_ms >= 0 do
    if remote?(session) do
      _ = eval_silent(session, "window.liveSocket && window.liveSocket.enableLatencySim(#{latency_ms})")
    end

    session
  end

  @doc """
  Disables the LiveView latency simulator. No-op on the in-process
  driver, or if the simulator wasn't enabled.
  """
  @spec clear_latency(Session.t()) :: Session.t()
  def clear_latency(%Session{} = session) do
    if remote?(session) do
      _ = eval_silent(session, "window.liveSocket && window.liveSocket.disableLatencySim()")
    end

    session
  end

  @doc """
  Runs `fun` with the latency simulator enabled at `latency_ms`, then
  clears it. The block receives the session, and its return value is
  used as the session that gets latency-cleared on exit.

  Raises propagate after the simulator is cleared, so a failing
  assertion inside the block doesn't leave latency enabled for the
  rest of the test process.
  """
  @spec with_latency(Session.t(), non_neg_integer(), (Session.t() -> Session.t())) :: Session.t()
  def with_latency(%Session{} = session, latency_ms, fun)
      when is_integer(latency_ms) and latency_ms >= 0 and is_function(fun, 1) do
    session = set_latency(session, latency_ms)

    try do
      fun.(session)
    after
      clear_latency(session)
    end
  end

  # ----- Deferred patch awaits -----

  @doc """
  Awaits the patch deferred by the most recent `await: :defer`
  interaction.

  If `session.pending_await` holds a `{:page_ready_after, id}` stash
  (a deferred click), waits for the next `page_ready` push from the
  bootstrap with that pre-click id. If it holds `:armed` (a deferred
  fill_in/clear/set_value/send_keys), waits for the patch promise
  installed by `prepare_patch`. If neither — no prior `:defer` —
  falls back to arm-and-await for the next patch, matching
  `Browser.await_patch/2`.

  ## Options

  * `:timeout` — max wait in ms (default: `5_000`).
  """
  @spec await_patch(Session.t(), keyword()) :: Session.t()
  def await_patch(%Session{} = session, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    case session.pending_await do
      {:page_ready_after, pre_page_id} ->
        _ = TransportProtocol.await_page_ready_after(session, pre_page_id, timeout)
        %{session | pending_await: nil}

      :armed ->
        _ = LiveViewAware.await_patch(session, timeout)
        %{session | pending_await: nil}

      nil ->
        # No deferred wait: behave like Browser.await_patch — arm a
        # fresh promise and wait for the next patch.
        Browser.await_patch(session, opts)
        session
    end
  end

  @doc """
  Snapshots the current bootstrap `pageId` and stashes it on the
  session as a deferred page-ready wait.

  Used internally by `click(query, await: :defer)`. Exposed publicly
  so tests can defer awaits around non-click triggers (e.g. a custom
  JS-driven action) and then drain them with `await_patch/2`.

  No-op on the in-process driver and on non-LiveView pages.
  """
  @spec defer_next_patch(Session.t()) :: Session.t()
  def defer_next_patch(%Session{} = session) do
    if remote?(session) do
      pre_page_id =
        case eval_silent(session, "window.__w && window.__w.pageId") do
          {:ok, id} when is_binary(id) -> id
          _ -> nil
        end

      %{session | pending_await: {:page_ready_after, pre_page_id}}
    else
      session
    end
  end

  @doc """
  Arms a patch promise via `prepare_patch` and stashes the session
  as `:armed`. Used by deferred `fill_in/clear/send_keys/set_value`.

  Public so tests that need to observe a phx-change between fire and
  reconcile can wire the same pattern manually.
  """
  @spec arm_next_patch(Session.t()) :: Session.t()
  def arm_next_patch(%Session{} = session) do
    if remote?(session) do
      case LiveViewAware.prepare_patch(session) do
        :prepared -> %{session | pending_await: :armed}
        :no_liveview -> session
      end
    else
      session
    end
  end

  # ----- Private -----

  defp remote?(%Session{driver: Wallabidi.Remote.Drivers.ChromeBiDi}), do: true
  defp remote?(%Session{driver: Wallabidi.Remote.Drivers.ChromeCDP}), do: true
  defp remote?(%Session{driver: Wallabidi.Remote.Drivers.LightpandaCDP}), do: true
  defp remote?(_), do: false

  defp eval_silent(session, js) do
    Protocol.eval(session, js)
  rescue
    _ -> {:error, :eval_failed}
  end
end
