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

    // Set up the one-shot promise for the NEXT patch
    window.__wallabidi_patch_promise = new Promise(resolve => {
      window.__wallabidi_patch_resolve = resolve;
    });
    return true;
  })()
  """

  @await_patch_js """
  (() => {
    if (!window.__wallabidi_patch_promise) return Promise.resolve(false);
    const p = window.__wallabidi_patch_promise;
    window.__wallabidi_patch_promise = null;
    return Promise.race([
      p,
      new Promise(resolve => {
        window.addEventListener('beforeunload', () => resolve("navigated"), {once: true});
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
  Awaits the patch promise installed by `prepare_patch/1`. Returns `:ok`
  when the patch is applied, or `:page_navigated` if a full navigation
  intervened (beforeunload fired or the JS context was destroyed).
  """
  @spec await_patch(Session.t(), timeout()) :: :ok | :page_navigated
  def await_patch(%Session{} = session, timeout \\ 5_000) do
    case Protocol.eval_async(session, @await_patch_js, timeout) do
      {:ok, "navigated"} -> :page_navigated
      {:ok, _} -> :ok
      {:error, _} -> :page_navigated
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

  ## Options

  - `:timeout` — maximum wait in ms (default: 5000)
  - `:pre_url` — when waiting post-navigation, poll until URL changes

  """
  @spec await_liveview_connected(Session.t(), keyword()) :: :ok
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

    _ = Protocol.eval_async(session, js, timeout + 1_000)
    :ok
  end
end
