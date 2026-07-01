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
      {:ok, true} ->
        {:ok, :connected}

      {:ok, "no-liveview"} ->
        {:ok, :no_liveview}

      {:ok, "no-livesocket"} ->
        # LiveView markup was served but window.liveSocket never appeared:
        # the app's JS bundle isn't loaded in the test env. Surface the
        # cause loudly (once per session) — otherwise this manifests as a
        # baffling "dynamic content never renders" assertion timeout far
        # downstream, even though the page looks fine when loaded manually
        # in dev (where Phoenix's watchers build assets live).
        warn_no_livesocket_once(session)
        {:error, :timeout}

      _ ->
        {:error, :timeout}
    end
  end

  @no_livesocket_flag {__MODULE__, :warned_no_livesocket}

  defp warn_no_livesocket_once(%Session{id: id}) do
    key = {@no_livesocket_flag, id}

    unless Process.get(key) do
      Process.put(key, true)

      require Logger

      Logger.warning("""
      [wallabidi] LiveView page served, but window.liveSocket never \
      initialized — the page's JavaScript bundle does not appear to be \
      loaded in the test environment.

      LiveView interactivity (WebSocket connect, phx-* events, \
      stream_insert, async updates) is driven by your app's own JS. In \
      :dev Phoenix's watchers build assets live, so this works when you \
      load the page manually; under `mix test` nothing builds them, so \
      the LiveView client never boots and dynamic content never appears.

      Build your assets for the test run — e.g. add `assets.build` to your \
      `test` alias in mix.exs:

          test: ["assets.build", "test"]

      or run `MIX_ENV=test mix assets.build` before the suite. See the \
      wallabidi Setup guide ("Phoenix").\
      """)
    end

    :ok
  end
end
