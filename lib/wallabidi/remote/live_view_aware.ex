defmodule Wallabidi.Remote.LiveViewAware do
  @moduledoc false

  # LiveView-aware operations that work across all BiDi/CDP drivers.
  #
  # All page-side logic lives in priv/wallabidi.js as `W.preparePatch`,
  # `W.awaitPatch`, `W.drainPatches`, `W.awaitAck`, `W.awaitSelector`,
  # `W.liveViewConnected`, and `W.awaitLiveViewConnected`. This module
  # is a thin BEAM-side adapter that invokes them via Protocol.eval /
  # Protocol.eval_async — same dispatch shape for CDP and BiDi.
  #
  # Centralising the JS here means: one source of truth, smaller wire
  # payload (a stable `window.__w.X()` invocation rather than a fresh
  # multi-line script per call), and the JS is testable in isolation
  # against priv/wallabidi.js.

  alias Wallabidi.Remote.Protocol
  alias Wallabidi.Session

  @doc """
  Installs a one-shot promise on `window.__wallabidi_patch_promise` that
  resolves after the next LiveView patch is applied. Returns `:prepared`
  if a LiveSocket exists, `:no_liveview` otherwise.
  """
  @spec prepare_patch(Session.t()) :: :prepared | :no_liveview
  def prepare_patch(%Session{} = session) do
    case Protocol.eval(session, "window.__w.run([['prepare_patch']])") do
      {:ok, true} -> :prepared
      _ -> :no_liveview
    end
  end

  @doc """
  Waits until the LV view has acknowledged every event with ref < pre_ref_next.

  `pre_ref_next` is the value of `liveSocket.main.ref` snapshotted BEFORE
  the click that should have dispatched an event. The counter increments on
  each push; the server replies with the same ref, updating `lastAckRef`.
  So once `lastAckRef >= pre_ref_next` we know the server has finished
  processing the event our click triggered — regardless of whether the reply
  was a diff, a redirect, or nothing at all.

  Returns `{:ok, :acked}`, `{:ok, :no_liveview}`, `{:ok, :page_navigated}`
  (JS context destroyed mid-wait → a full nav happened), or
  `{:error, :timeout}`.
  """
  @spec await_ack(Session.t(), non_neg_integer(), timeout()) ::
          {:ok, :acked | :no_liveview | :page_navigated} | {:error, :timeout}
  def await_ack(%Session{} = session, pre_ref_next, timeout \\ 5_000) do
    js = "window.__w.run([['await_ack', #{pre_ref_next}, #{timeout}]])"

    case Protocol.eval_async(session, js, timeout + 1_000) do
      {:ok, "acked"} -> {:ok, :acked}
      {:ok, "no-liveview"} -> {:ok, :no_liveview}
      {:ok, "navigated"} -> {:ok, :page_navigated}
      {:ok, false} -> {:error, :timeout}
      _ -> {:error, :timeout}
    end
  end

  @doc """
  Awaits the patch promise installed by `prepare_patch/1`. Returns:

    * `:ok` — the patch was applied
    * `:page_navigated` — a full navigation intervened (beforeunload fired
      in JS, signalling navigation, OR the JS context was destroyed and
      the patch promise is gone)
    * `:timeout` — neither happened within the deadline

  Note: a stray `{:error, _}` from eval_async (Elixir-side outer timeout)
  is treated as `:timeout`, not `:page_navigated`. Conflating the two
  hides cases where the server is still processing — the caller should
  fall through to ack-based / page-ready waits rather than assume the
  page navigated.
  """
  @spec await_patch(Session.t(), timeout()) :: :ok | :page_navigated | :timeout
  def await_patch(%Session{} = session, timeout \\ 5_000) do
    js = "window.__w.run([['await_patch', #{timeout}]])"

    case Protocol.eval_async(session, js, timeout) do
      {:ok, "navigated"} ->
        :page_navigated

      {:ok, "no-promise"} ->
        :page_navigated

      {:ok, true} ->
        :ok

      {:ok, false} ->
        :timeout

      {:ok, _} ->
        :ok

      # BiDi: chromium-bidi raises "Cannot find context with specified id"
      # when we evaluate against a browsing context whose document was
      # destroyed by a navigation mid-flight. Treat that as :page_navigated
      # — the patch promise is gone with the old context, but we know
      # navigation happened.
      {:error, {_, msg}} when is_binary(msg) ->
        if msg =~ "Cannot find context", do: :page_navigated, else: :timeout

      {:error, _} ->
        :timeout
    end
  end

  @doc """
  One-shot: arm a fresh patch promise, then await it. Returns `:ok`
  whether the patch arrives, the page navigates, the timer elapses,
  or there's no LiveView on the page — callers of this helper want
  "best-effort wait for the next patch" semantics.

  Used by `Wallabidi.Browser.await_patch/2` via the driver behaviour.
  """
  @spec arm_and_await(Session.t(), timeout()) :: :ok
  def arm_and_await(%Session{} = session, timeout) do
    case prepare_patch(session) do
      :prepared -> _ = await_patch(session, timeout)
      :no_liveview -> :ok
    end

    :ok
  end

  @doc """
  Waits until no LiveView patch has arrived for `idle_ms` ms, or the
  overall `timeout` elapses. Used after `fill_in` where multiple
  phx-change events fire and we want to wait for the final one.
  """
  @spec drain_patches(Session.t(), timeout()) :: :ok
  def drain_patches(%Session{} = session, timeout \\ 5_000) do
    _ = Protocol.eval_async(session, "window.__w.run([['drain_patches']])", timeout)
    :ok
  end

  @doc """
  Waits until a CSS selector matches in the live DOM, using MutationObserver
  (and LiveView `onPatchEnd`) for event-driven re-checking. Returns `:found`
  as soon as the selector matches, `:not_found` on timeout, or `:navigated`
  if the page navigated mid-wait.

  This is the page-ready barrier that sits between `visit` returning and the
  caller polling `find_elements`. It works across BiDi and CDP transports
  because the JS is evaluated via `Protocol.eval_async` with
  `awaitPromise: true` — the browser pushes us the answer the moment the
  DOM matches, instead of Elixir polling via round-trip RPCs.

  ## Options

  - `:timeout` — max wait in ms (default: 5000)
  - `:text`    — also require matching element's `textContent` to include this
  - `:retries` — internal, used to bound navigation retries
  """
  @spec await_selector(Session.t(), String.t(), keyword()) ::
          :found | :not_found | :navigated
  def await_selector(%Session{} = session, css_selector, opts \\ []) do
    # Short default: this is a fast pre-check that resolves immediately when
    # the selector is already in the DOM (most common case after visit), or
    # catches a mutation that arrives within a tight window (LiveView patch,
    # JS toggle). If nothing matches within 200ms we fall through to the
    # caller's own retry loop — which has the full max_wait_time budget.
    timeout = Keyword.get(opts, :timeout, 200)
    text = Keyword.get(opts, :text)

    js_opts =
      Jason.encode!(%{
        "timeoutMs" => timeout,
        "text" => text
      })

    js =
      "window.__w.run([['await_selector', #{Jason.encode!(css_selector)}, #{js_opts}]])"

    result =
      case Protocol.eval_async(session, js, timeout + 1_000) do
        {:ok, true} -> :found
        {:ok, "navigated"} -> :navigated
        _ -> :not_found
      end

    case result do
      :navigated ->
        retries = Keyword.get(opts, :retries, 0)

        if retries < 2 do
          await_liveview_connected(session)
          opts = opts |> Keyword.put(:timeout, timeout) |> Keyword.put(:retries, retries + 1)
          await_selector(session, css_selector, opts)
        else
          :not_found
        end

      other ->
        other
    end
  end

  @doc """
  Returns true if the session's LiveSocket is connected.
  """
  @spec live_view_connected?(Session.t()) :: boolean
  def live_view_connected?(%Session{} = session) do
    case Protocol.eval(session, "window.__w.run([['live_view_connected']])") do
      {:ok, true} -> true
      _ -> false
    end
  end

  @doc """
  Waits until the current LiveSocket is connected, or returns immediately
  if the page is not a LiveView page (no `data-phx-session` attribute in
  the server-rendered HTML).

  Returns `{:ok, :connected}` when the LiveView mounted, `{:ok, :no_liveview}`
  when the page isn't a LiveView, or `{:error, :timeout}` when the deadline
  elapsed without either condition being met. Previously this function
  discarded the result and always returned `:ok`, which let navigation
  timeouts silently succeed and surface as confusing downstream assertion
  failures. See NavigationTimeoutError for the caller-facing mapping.

  ## Options

  - `:timeout` — maximum wait in ms (default: 5000)
  - `:pre_url` — when waiting post-navigation, poll until URL changes

  """
  @spec await_liveview_connected(Session.t(), keyword()) ::
          {:ok, :connected | :no_liveview} | {:error, :timeout}
  def await_liveview_connected(%Session{} = session, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    pre_url = Keyword.get(opts, :pre_url)
    pre_url_js = if pre_url, do: Jason.encode!(pre_url), else: "null"

    js = "window.__w.run([['await_lv_connected', #{pre_url_js}, #{timeout}]])"

    case Protocol.eval_async(session, js, timeout + 1_000) do
      {:ok, true} -> {:ok, :connected}
      {:ok, "no-liveview"} -> {:ok, :no_liveview}
      _ -> {:error, :timeout}
    end
  end
end
