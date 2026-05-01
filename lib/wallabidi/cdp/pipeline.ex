defmodule Wallabidi.CDP.Pipeline do
  @moduledoc false

  # Builds a find + filter chain as data, compiles to one JS function that
  # returns a flat array of DOM nodes. One `evaluate` + one `getProperties`
  # replaces the old `evaluate → getProperties → [callFunctionOn × N]`
  # chain (2 RPCs instead of 2+N).
  #
  # ## Example
  #
  #     Pipeline.new()
  #     |> Pipeline.query_all(:css, "#menu-btn")
  #     |> Pipeline.filter_visible()
  #     |> Pipeline.filter_text("Menu")
  #     |> Pipeline.to_js()
  #     #=> "(() => { var els; els = ...; els = els.filter(...); return els; })()"
  #
  # The returned JS always evaluates to an array of DOM nodes (live
  # references). Callers use the existing `find_elements_js` / `find_elements_on`
  # machinery to extract objectIds via `getProperties`.

  defstruct ops: [], parent_id: nil

  def new, do: %__MODULE__{}

  def new(%{bidi_shared_id: parent_id}) when not is_nil(parent_id) do
    %__MODULE__{parent_id: parent_id}
  end

  def new(_), do: %__MODULE__{}

  def query_all(%__MODULE__{} = p, :css, selector) do
    %{p | ops: p.ops ++ [{:query_css, selector}]}
  end

  def query_all(%__MODULE__{} = p, :xpath, xpath) do
    %{p | ops: p.ops ++ [{:query_xpath, xpath}]}
  end

  def filter_visible(%__MODULE__{} = p) do
    %{p | ops: p.ops ++ [:filter_visible]}
  end

  def filter_not_visible(%__MODULE__{} = p) do
    %{p | ops: p.ops ++ [:filter_not_visible]}
  end

  def filter_text(%__MODULE__{} = p, text) do
    %{p | ops: p.ops ++ [{:filter_text, text}]}
  end

  def filter_selected(%__MODULE__{} = p, selected) do
    %{p | ops: p.ops ++ [{:filter_selected, selected}]}
  end

  @doc """
  Append classification metadata to the result array. The classification
  string is set as `els.__classify` so `getProperties` returns it alongside
  the element objectIds. The caller can extract it without an extra RPC.
  """
  def classify(%__MODULE__{} = p, interaction) do
    %{p | ops: p.ops ++ [{:classify, interaction}]}
  end

  @doc """
  Click the first matching element. Runs the click JS inline after
  find+filter, eliminating a separate callFunctionOn round-trip.
  """
  def click(%__MODULE__{} = p) do
    %{p | ops: p.ops ++ [:click]}
  end

  @doc """
  Combined classify + prepare_patch + click in one op. Replaces three
  separate RPCs (classify_interaction, prepare_patch, pipeline click)
  with one JS evaluation that:
  1. Installs the LiveView onPatchEnd promise (prepare_patch)
  2. Classifies the first matching element's phx bindings
  3. Clicks the element
  4. Returns {count, classification, prepared} by value
  """
  def click_full(%__MODULE__{} = p, interaction) do
    %{p | ops: p.ops ++ [{:click_full, interaction}]}
  end

  @doc """
  Mark this pipeline as async. `count` is the expected element count —
  the Promise only resolves when exactly this many elements match (or
  `:any` to resolve as soon as at least 1 matches).
  """
  def await(%__MODULE__{} = p, timeout \\ 200, count \\ :any) do
    %{p | ops: p.ops ++ [{:await, timeout, count}]}
  end

  @doc """
  Compiles the pipeline to a JS expression string. Returns `{js, parent_id, mode}`.

  `mode` is `:elements` (default) or `:count`. When the pipeline includes
  a `:click` op, mode is `:count` because the click's side effects (form
  submit, navigation) may invalidate element references before they can
  be returned. In count mode, the JS returns `{count: N}` by value.
  """
  def to_js(%__MODULE__{ops: ops, parent_id: parent_id}) do
    root = if parent_id, do: "this", else: "document"
    has_click = Enum.any?(ops, &(&1 == :click))
    has_click_full = Enum.any?(ops, &match?({:click_full, _}, &1))
    await_op = Enum.find(ops, &match?({:await, _, _}, &1))

    # Separate ops: everything except :await (which wraps the whole thing)
    non_await_ops = Enum.reject(ops, &match?({:await, _, _}, &1))

    body = Enum.map_join(non_await_ops, "\n", fn op -> compile_op(op, root) end)

    ret =
      cond do
        has_click_full -> "_ret"
        has_click -> "{count: els.length}"
        true -> "els"
      end

    js =
      if await_op do
        {_, timeout, count} = await_op
        compile_await_wrapper(body, ret, root, parent_id, timeout, count)
      else
        if parent_id do
          """
          function() {
            var els;
            #{body}
            return #{ret};
          }
          """
        else
          """
          (() => {
            var els;
            #{body}
            return #{ret};
          })()
          """
        end
      end

    mode =
      cond do
        has_click_full -> :click_full
        has_click -> :count
        await_op != nil -> :await
        true -> :elements
      end

    {js, parent_id, mode}
  end

  # --- Op compilation ---

  defp compile_op({:query_css, selector}, root) do
    "els = Array.from(#{root}.querySelectorAll(#{Jason.encode!(selector)}));"
  end

  defp compile_op({:query_xpath, xpath}, root) do
    # Use a block scope instead of an IIFE to preserve `this` binding
    # from callFunctionOn. An IIFE rebinds `this` to undefined/window.
    """
    try {
      var _xctx = #{root};
      if (!_xctx || !_xctx.nodeType) _xctx = document;
      var _xr = document.evaluate(#{Jason.encode!(xpath)}, _xctx, null,
        XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      els = [];
      for (var _xi = 0; _xi < _xr.snapshotLength; _xi++) els.push(_xr.snapshotItem(_xi));
    } catch(_xe) { els = []; }
    """
  end

  defp compile_op(:filter_visible, _root) do
    "els = els.filter(#{visibility_fn()});"
  end

  defp compile_op(:filter_not_visible, _root) do
    "els = els.filter(function(el) { return !(#{visibility_fn()})(el); });"
  end

  defp compile_op({:filter_text, text}, _root) do
    """
    els = els.filter(function(el) {
      var t = (el.innerText || el.textContent || '').replace(/[\\s\\u00a0]+/g, ' ').trim();
      return t.indexOf(#{Jason.encode!(text)}) !== -1;
    });
    """
  end

  defp compile_op({:filter_selected, true}, _root) do
    "els = els.filter(function(el) { return el.selected || el.checked || false; });"
  end

  defp compile_op({:filter_selected, false}, _root) do
    "els = els.filter(function(el) { return !(el.selected || el.checked); });"
  end

  defp compile_op(:click, _root) do
    """
    if (els.length > 0) {
      var _el = els[0];
      #{click_fn()}
    }
    """
  end

  defp compile_op({:click_full, interaction}, _root) do
    """
    var _prepared = false;
    var _classification = "none";
    var _count = els.length;
    var _preRef = null;
    (function() {
      // 1. prepare_patch — install onPatchEnd hook + promise
      var ls = window.liveSocket;
      if (ls && ls.main) {
        if (!window.__wallabidi_patch_hooked) {
          var orig = ls.domCallbacks.onPatchEnd;
          ls.domCallbacks.onPatchEnd = function(container) {
            orig(container);
            if (window.__wallabidi_patch_resolve) {
              var r = window.__wallabidi_patch_resolve;
              window.__wallabidi_patch_resolve = null;
              r(true);
            }
          };
          window.__wallabidi_patch_hooked = true;
        }
        window.__wallabidi_patch_promise = new Promise(function(resolve) {
          window.__wallabidi_patch_resolve = resolve;
          window.addEventListener('beforeunload', function() {
            if (window.__wallabidi_patch_resolve) {
              window.__wallabidi_patch_resolve = null;
              resolve('navigated');
            }
          }, {once: true});
        });
        _prepared = true;
      }

      // 2. classify first element
      if (els.length > 0) {
        _classification = (#{classify_fn()})(els[0], #{Jason.encode!(to_string(interaction))});
      }

      // 2a. Snapshot the LV view's ref counter. Every phx-* event push
      // grabs `view.ref++` for its server-side reply. After the click,
      // waiting for `view.lastAckRef >= _preRef` tells us the server has
      // finished processing whatever event our click triggered — even
      // if that processing takes longer than patch/load deadlines. This
      // closes the gap where a slow handle_event + push_navigate
      // completes AFTER wallabidi's post-click awaits have given up.
      if (ls && ls.main && typeof ls.main.ref === 'number') {
        _preRef = ls.main.ref;
      }
    })();

    // 3. Capture return value BEFORE clicking — the click may navigate
    // the page and destroy the execution context. _ret becomes a
    // Promise that resolves to the return map once the click has
    // been dispatched (step 5). evaluate is called with
    // awaitPromise: true so the RPC response waits for it.
    var _retValue = {count: _count, classification: _classification, prepared: _prepared, preRef: _preRef};

    // 4. Wait for the source LiveView to finish joining before
    // dispatching the click. If the LV is mid-join, Phoenix's
    // [data-phx-link] handler may not be bound yet and the synthetic
    // click falls through to the default anchor behaviour — the
    // teamology u2i/teamology#586 nav-click flake. Bounded by a 5s
    // deadline so a genuinely-broken LV doesn't hang indefinitely.
    var _ret = new Promise(function(resolve) {
      var ls = window.liveSocket;
      if (!ls || !ls.main || !ls.main.joinPending) return resolve();

      var deadline = Date.now() + 5000;
      function check() {
        var ls2 = window.liveSocket;
        if (!ls2 || !ls2.main || !ls2.main.joinPending) return resolve();
        if (Date.now() > deadline) return resolve();
        setTimeout(check, 20);
      }
      check();
    }).then(function() {
      // 5. Click (fire-and-forget — if it navigates, we won't get a
      // response, but Chrome still processes the click).
      if (els.length > 0) {
        var _el = els[0];
        #{click_fn()}
      }
      return _retValue;
    });
    """
  end

  defp compile_op({:classify, interaction}, _root) do
    """
    if (els.length > 0) {
      els.__classify = (#{classify_fn()})(els[0], #{Jason.encode!(to_string(interaction))});
    } else {
      els.__classify = "none";
    }
    """
  end

  # Inline visibility function — same logic as CDPClient.displayed/1
  defp visibility_fn do
    """
    function(el) {
      if (!el.isConnected) return false;
      if (el.tagName === 'OPTION') {
        var select = el.closest('select');
        if (!select) return true;
        var ss = window.getComputedStyle(select);
        return ss.display !== 'none' && ss.visibility !== 'hidden';
      }
      var style = window.getComputedStyle(el);
      if (style.display === 'none') return false;
      if (style.visibility === 'hidden') return false;
      var rect = el.getBoundingClientRect();
      if (rect.width === 0 && rect.height === 0 && el.offsetParent === null && style.position !== 'fixed') return false;
      return true;
    }
    """
  end

  defp click_fn do
    """
    (function() {
      if (_el.tagName !== 'OPTION') {
        _el.scrollIntoView({block: 'center', inline: 'nearest'});
      }
      if (_el.tagName === 'OPTION') {
        var select = _el.closest('select');
        if (select && !select.multiple) {
          select.value = _el.value;
          Array.from(select.options).forEach(function(o) { o.selected = (o === _el); });
        } else {
          _el.selected = !_el.selected;
        }
        if (select) select.dispatchEvent(new Event('change', { bubbles: true }));
        return;
      }
      var form = _el.closest('form');
      if (form && (_el.type === 'reset' || (_el.tagName === 'BUTTON' && _el.type === 'reset'))) {
        Array.from(form.elements).forEach(function(el) {
          if (el.type === 'checkbox' || el.type === 'radio') {
            el.checked = el.defaultChecked;
          } else if (el.tagName === 'SELECT') {
            Array.from(el.options).forEach(function(o) { o.selected = o.defaultSelected; });
          } else if ('defaultValue' in el) {
            el.value = el.defaultValue;
          }
        });
        form.dispatchEvent(new Event('reset', { bubbles: true }));
        return;
      }
      if (form && _el.tagName === 'INPUT' && (_el.type === 'submit' || _el.type === 'image')) {
        _el.focus();
        _el.click();
        return;
      }
      _el.focus();
      _el.click();
    })();
    """
  end

  defp compile_await_wrapper(body, ret, root, parent_id, timeout, count) do
    # Capture the root element outside tryFind so nested function calls
    # don't rebind `this`. For document-level queries root is "document"
    # (no rebinding issue). For scoped queries root is "this" which
    # we capture as _root.
    capture = if root == "this", do: "var _root = this;", else: ""
    # Replace references to "this" in the body with "_root" for scoped queries
    safe_body = if root == "this", do: String.replace(body, "this", "_root"), else: body

    inner =
      """
      #{capture}
      function tryFind() {
        var els;
        #{safe_body}
        return #{ret};
      }

      var _expected = #{compile_count(count)};
      function _matches(r) {
        if (!Array.isArray(r)) return r != null;
        if (_expected === null) return r.length > 0;
        return r.length === _expected;
      }

      var found = tryFind();
      if (_matches(found)) return Promise.resolve(found);

      return new Promise(function(resolve) {
        var timer = setTimeout(function() { cleanup(); resolve(tryFind()); }, #{timeout});

        var origOnPatchEnd;
        var ls = window.liveSocket;
        if (ls && ls.domCallbacks) {
          origOnPatchEnd = ls.domCallbacks.onPatchEnd;
          ls.domCallbacks.onPatchEnd = function(container) {
            if (origOnPatchEnd) origOnPatchEnd(container);
            var r = tryFind();
            if (_matches(r)) { cleanup(); resolve(r); }
          };
        }

        var observer = new MutationObserver(function() {
          requestAnimationFrame(function() {
            var r = tryFind();
            if (_matches(r)) { cleanup(); resolve(r); }
          });
        });
        observer.observe(document.body, {
          childList: true, subtree: true,
          attributes: true, characterData: true
        });

        function cleanup() {
          clearTimeout(timer);
          observer.disconnect();
          if (origOnPatchEnd && ls && ls.domCallbacks) {
            ls.domCallbacks.onPatchEnd = origOnPatchEnd;
          }
        }
      });
      """

    if parent_id do
      "function() {\n#{inner}\n}"
    else
      "(function() {\n#{inner}\n})()"
    end
  end

  defp compile_count(:any), do: "null"
  defp compile_count(nil), do: "null"
  defp compile_count(n) when is_integer(n), do: Integer.to_string(n)

  defp classify_fn do
    """
    function(el, type) {
      if (!el) return "none";
      if (type === 'click') {
        var link = el.closest('[data-phx-link]');
        if (link) return link.getAttribute('data-phx-link') === 'redirect' ? 'navigate' : 'patch';
        var phxClick = el.getAttribute('phx-click');
        if (phxClick) {
          if (phxClick.startsWith('[')) {
            // JS command list — pick the strongest navigation signal present.
            // JSON-quoted command names are robust enough to string-match.
            if (phxClick.indexOf('"navigate"') !== -1) return 'navigate';
            if (phxClick.indexOf('"patch"') !== -1) return 'patch';
            if (phxClick.indexOf('"push"') !== -1) return 'patch';
            return 'none';
          }
          return 'patch';
        }
        // Only buttons/inputs that submit a form trigger navigation.
        // type='reset' and type='button' run JS but never submit/navigate.
        var submits = (el.type === 'submit' || el.type === 'image') ||
                      (el.tagName === 'BUTTON' && el.type !== 'reset' && el.type !== 'button');
        if (submits) {
          var form = el.closest('form');
          // phx-trigger-action fires a native form submit after the LV event,
          // so a full page load is the load-bearing transition — await that,
          // not the preceding LV patch.
          if (form && form.hasAttribute('phx-trigger-action')) return 'full_page';
          if (form && form.getAttribute('phx-submit')) return 'patch';
          if (form) return 'full_page';
        }
        var anchor = el.closest('a[href]');
        if (anchor && anchor.getAttribute('href') && !anchor.getAttribute('href').startsWith('#')) {
          // target="_blank" / target="newwindow" / etc. open in a new tab —
          // the source page doesn't navigate, so don't await a load.
          var tgt = anchor.getAttribute('target');
          if (tgt && tgt !== '_self' && tgt !== '_top' && tgt !== '_parent') return 'none';
          // onclick handler may preventDefault — can't statically tell.
          // Defer to the JS to decide; if it does navigate, downstream
          // assertions will retry-with-timeout anyway.
          if (anchor.hasAttribute('onclick')) return 'none';
          return 'full_page';
        }
        return 'none';
      }
      if (type === 'change') {
        var phxChange = el.getAttribute('phx-change') || (el.form && el.form.getAttribute('phx-change'));
        return phxChange ? 'patch' : 'none';
      }
      if (type === 'submit') {
        var f = el.closest('form');
        if (f && f.hasAttribute('phx-trigger-action')) return 'full_page';
        if (f && f.getAttribute('phx-submit')) return 'patch';
        if (f) return 'full_page';
        return 'none';
      }
      return 'none';
    }
    """
  end
end
