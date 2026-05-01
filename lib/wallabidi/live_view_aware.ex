defmodule Wallabidi.LiveViewAware do
  @moduledoc false

  # LiveView-aware operations that work across all BiDi/CDP drivers.
  #
  # The JS payloads are identical regardless of protocol — the only thing
  # that differs is HOW the JS gets evaluated. This module uses
  # `Wallabidi.Protocol` to dispatch to the appropriate adapter (BiDi or
  # CDP), so the same LiveView integration works for all drivers.
  #
  # These operations were originally in `Wallabidi.BiDiClient`, tying them
  # to the BiDi protocol. Now they live here and are protocol-agnostic.

  alias Wallabidi.Protocol
  alias Wallabidi.Session

  @prepare_patch_js """
  (() => {
    const ls = window.liveSocket;
    if (!ls || !ls.main) return false;

    // Install the onPatchEnd hook once (preserves any existing callback)
    if (!window.__wallabidi_patch_hooked) {
      const orig = ls.domCallbacks.onPatchEnd;
      ls.domCallbacks.onPatchEnd = function(container) {
        orig(container);
        if (window.__wallabidi_patch_resolve) {
          let r = window.__wallabidi_patch_resolve;
          window.__wallabidi_patch_resolve = null;
          r(true);
        }
      };
      window.__wallabidi_patch_hooked = true;
    }

    // Set up the one-shot promise for the NEXT patch.
    // Also listen for beforeunload — if the action causes a redirect
    // instead of a patch, resolve immediately with "navigated".
    window.__wallabidi_patch_promise = new Promise(resolve => {
      window.__wallabidi_patch_resolve = resolve;
      window.addEventListener('beforeunload', () => {
        if (window.__wallabidi_patch_resolve) {
          window.__wallabidi_patch_resolve = null;
          resolve("navigated");
        }
      }, {once: true});
    });
    return true;
  })()
  """

  @await_patch_js """
  (() => {
    // Promise missing means either prepare_patch wasn't called, OR
    // the page navigated and we're now in a fresh JS context. Tell
    // Elixir which so it can skip the slow await_ack path on nav.
    if (!window.__wallabidi_patch_promise) return Promise.resolve('no-promise');
    const p = window.__wallabidi_patch_promise;
    window.__wallabidi_patch_promise = null;
    return Promise.race([
      p,
      new Promise(resolve => {
        setTimeout(() => resolve(false), 5000);
      })
    ]);
  })()
  """

  @drain_patches_js """
  (() => {
    const ls = window.liveSocket;
    if (!ls || !ls.domCallbacks) return Promise.resolve(true);

    return new Promise(resolve => {
      let timer = null;
      const idle = 300;
      const orig = ls.domCallbacks.onPatchEnd;

      function done() {
        ls.domCallbacks.onPatchEnd = orig;
        resolve(true);
      }

      function resetTimer() {
        if (timer) clearTimeout(timer);
        timer = setTimeout(done, idle);
      }

      ls.domCallbacks.onPatchEnd = function(container) {
        orig(container);
        resetTimer();
      };

      resetTimer();
    });
  })()
  """

  @doc """
  Installs a one-shot promise on `window.__wallabidi_patch_promise` that
  resolves after the next LiveView patch is applied. Returns `:prepared`
  if a LiveSocket exists, `:no_liveview` otherwise.
  """
  @spec prepare_patch(Session.t()) :: :prepared | :no_liveview
  def prepare_patch(%Session{} = session) do
    case Protocol.eval(session, @prepare_patch_js) do
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
    js = """
    new Promise(resolve => {
      var deadline = Date.now() + #{timeout};
      var target = #{pre_ref_next};

      function check() {
        var ls = window.liveSocket;
        if (!ls || !ls.main) return resolve('no-liveview');

        // `ref` here is the NEXT ref the view will issue. Before the
        // click we snapshotted it as `target`. The server acks with
        // the ref it received; lastAckRef is the highest so far. Our
        // click triggered an event with ref === target, so we wait for
        // lastAckRef >= target.
        if (ls.main.lastAckRef !== null && ls.main.lastAckRef >= target) {
          return resolve('acked');
        }

        if (Date.now() > deadline) return resolve(false);
        setTimeout(check, 20);
      }

      window.addEventListener('beforeunload', function() {
        resolve('navigated');
      }, {once: true});

      check();
    })
    """

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
    case Protocol.eval_async(session, @await_patch_js, timeout) do
      {:ok, "navigated"} -> :page_navigated
      {:ok, "no-promise"} -> :page_navigated
      {:ok, true} -> :ok
      {:ok, false} -> :timeout
      {:ok, _} -> :ok
      {:error, _} -> :timeout
    end
  end

  @doc """
  Waits until no LiveView patch has arrived for `idle_ms` ms, or the
  overall `timeout` elapses. Used after `fill_in` where multiple
  phx-change events fire and we want to wait for the final one.
  """
  @spec drain_patches(Session.t(), timeout()) :: :ok
  def drain_patches(%Session{} = session, timeout \\ 5_000) do
    _ = Protocol.eval_async(session, @drain_patches_js, timeout)
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

    text_js = if text, do: Jason.encode!(text), else: "null"

    js = """
    (() => {
      const selector = #{Jason.encode!(css_selector)};
      const text = #{text_js};

      function matches() {
        if (!text) return !!document.querySelector(selector);
        var els = document.querySelectorAll(selector);
        for (var i = 0; i < els.length; i++) {
          if (els[i].textContent.includes(text)) return true;
        }
        return false;
      }

      // Already present?
      if (matches()) return Promise.resolve(true);

      return new Promise((resolve) => {
        let timer = setTimeout(() => { cleanup(); resolve(false); }, #{timeout});

        // LiveView: check after each complete patch
        let origOnPatchEnd;
        const ls = window.liveSocket;
        if (ls && ls.domCallbacks) {
          origOnPatchEnd = ls.domCallbacks.onPatchEnd;
          ls.domCallbacks.onPatchEnd = function(container) {
            if (origOnPatchEnd) origOnPatchEnd(container);
            if (matches()) { cleanup(); resolve(true); }
          };
        }

        // Fallback: MutationObserver for JS-driven changes
        const observer = new MutationObserver(() => {
          requestAnimationFrame(() => {
            if (matches()) { cleanup(); resolve(true); }
          });
        });
        observer.observe(document.body, {
          childList: true, subtree: true,
          attributes: true, characterData: true
        });

        // Detect navigation — resolve with "navigated" so Elixir can
        // wait for the new page and re-run await_selector.
        var startUrl = window.location.href;
        function onNav() { cleanup(); resolve("navigated"); }
        window.addEventListener('beforeunload', onNav, {once: true});

        // Poll URL for LiveView push_navigate (no beforeunload for SPA nav)
        var navCheck = setInterval(function() {
          if (window.location.href !== startUrl) {
            // URL changed — wait for new DOM to be ready, then check
            requestAnimationFrame(function() {
              if (matches()) { cleanup(); resolve(true); }
              else { cleanup(); resolve("navigated"); }
            });
          }
        }, 50);

        function cleanup() {
          clearTimeout(timer);
          clearInterval(navCheck);
          observer.disconnect();
          window.removeEventListener('beforeunload', onNav);
          if (origOnPatchEnd && ls && ls.domCallbacks) {
            ls.domCallbacks.onPatchEnd = origOnPatchEnd;
          }
        }
      });
    })()
    """

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
    js = """
    (() => {
      const ls = window.liveSocket;
      if (!ls || !ls.main) return false;
      return !ls.main.joinPending;
    })()
    """

    case Protocol.eval(session, js) do
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

    js = """
    new Promise(resolve => {
      const preUrl = #{pre_url_js};
      const deadline = Date.now() + #{timeout};

      function check() {
        // Waiting for a NEW LV (post-navigation) — keep polling until
        // URL changes or deadline hits.
        if (preUrl && window.location.href === preUrl) {
          if (Date.now() > deadline) return resolve(false);
          return setTimeout(check, 30);
        }

        // Wait for the DOM to finish parsing before checking for the
        // server-rendered LiveView marker.
        if (document.readyState === 'loading') {
          if (Date.now() > deadline) return resolve(false);
          return setTimeout(check, 20);
        }

        // Not a LiveView page (no server-rendered [data-phx-session]).
        if (!document.querySelector('[data-phx-session]')) {
          return resolve('no-liveview');
        }

        const ls = window.liveSocket;
        if (ls && ls.main && !ls.main.joinPending) return resolve(true);
        if (Date.now() > deadline) return resolve(false);
        setTimeout(check, 30);
      }

      check();
    })
    """

    case Protocol.eval_async(session, js, timeout + 1_000) do
      {:ok, true} -> {:ok, :connected}
      {:ok, "no-liveview"} -> {:ok, :no_liveview}
      _ -> {:error, :timeout}
    end
  end
end
