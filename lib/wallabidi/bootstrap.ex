defmodule Wallabidi.Bootstrap do
  @moduledoc false
  # Shared browser-side bootstrap JS for push-based element finding.
  #
  # The body installs window.__w with an opcode interpreter, MutationObserver,
  # LiveView onPatchEnd hook, and query checker. It references `__wallabidi`
  # as a free variable — the caller provides it as either:
  #   - CDP: a global binding via Runtime.addBinding
  #   - BiDi: a channel callback via script.addPreloadScript argument

  @doc "CDP form: IIFE that assumes `__wallabidi` is a global binding."
  def cdp_iife, do: "(function() {\n#{body()}\n})()"

  @doc "BiDi form: arrow function receiving `__wallabidi` as channel parameter."
  def bidi_preload, do: "(__wallabidi) => {\n#{body()}\n}"

  @doc """
  Build the register_js snippet that stores a query in W.queries and
  calls W.check(). Used by both CDPClient and BiDi find paths.

  `root_js` is `"this"` for scoped (Element parent) or `"null"` for document.
  """
  def register_js(query_id, ops_json, count_js, root_js \\ "null") do
    id_js = Jason.encode!(query_id)

    "var W=window.__w;" <>
      "if(W){" <>
      "W.queries[#{id_js}]={ops:#{ops_json},count:#{count_js},resolved:false,elements:[],root:#{root_js}};" <>
      "W.check();" <>
      "}else{" <>
      "try{" <>
      "var r={els:[],error:null};" <>
      "try{var _o=#{ops_json};for(var i=0;i<_o.length;i++){var o=_o[i];if(o[0]==='query'){r.els=Array.from(document.querySelectorAll(o[2]));}}}catch(e){r.error=e.message;}" <>
      "if(r.error)__wallabidi(JSON.stringify({id:#{id_js},count:0,error:r.error}));" <>
      "else{var c=r.els.length;var m=#{count_js}===null?c>0:c===#{count_js};if(m)__wallabidi(JSON.stringify({id:#{id_js},count:c}));}" <>
      "}catch(e){}" <>
      "}"
  end

  @doc "JS to clean up a resolved query from window.__w.queries."
  def cleanup_js(query_id) do
    id_js = Jason.encode!(query_id)
    "if(window.__w&&window.__w.queries)delete window.__w.queries[#{id_js}];"
  end

  defp body do
    ~S"""
    if (window.__w) return;
    var W = window.__w = {};
    W.queries = {};

    // --- Visibility check ---
    W.isVisible = function(el) {
      if (!el.isConnected) return false;
      // Head and its descendants are never user-visible regardless of CSS
      // (real browsers enforce this via UA stylesheet; some headless engines
      // like Lightpanda don't, so check explicitly).
      if (el.ownerDocument && el.ownerDocument.head && el.ownerDocument.head.contains(el)) return false;
      if (el.tagName === 'OPTION') {
        var s = el.closest('select');
        if (!s) return true;
        var ss = getComputedStyle(s);
        return ss.display !== 'none' && ss.visibility !== 'hidden';
      }
      var st = getComputedStyle(el);
      if (st.display === 'none' || st.visibility === 'hidden') return false;
      var r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0 && el.offsetParent === null && st.position !== 'fixed') return false;
      return true;
    };

    // --- Click handler ---
    W.clickEl = function(el) {
      if (!el) return;
      if (el.tagName !== 'OPTION') {
        el.scrollIntoView({block: 'center', inline: 'nearest'});
      }
      if (el.tagName === 'OPTION') {
        var sel = el.closest('select');
        if (sel && !sel.multiple) {
          sel.value = el.value;
          Array.from(sel.options).forEach(function(o) { o.selected = (o === el); });
        } else { el.selected = !el.selected; }
        if (sel) sel.dispatchEvent(new Event('change', {bubbles: true}));
        return;
      }
      var form = el.closest('form');
      if (form && (el.type === 'reset' || (el.tagName === 'BUTTON' && el.type === 'reset'))) {
        Array.from(form.elements).forEach(function(fe) {
          if (fe.type === 'checkbox' || fe.type === 'radio') fe.checked = fe.defaultChecked;
          else if (fe.tagName === 'SELECT') Array.from(fe.options).forEach(function(o) { o.selected = o.defaultSelected; });
          else if ('defaultValue' in fe) fe.value = fe.defaultValue;
        });
        form.dispatchEvent(new Event('reset', {bubbles: true}));
        return;
      }
      el.focus();
      el.click();
    };

    // --- Classify handler ---
    W.classify = function(el, type) {
      if (!el) return 'none';
      if (type === 'click') {
        var link = el.closest('[data-phx-link]');
        if (link) return link.getAttribute('data-phx-link') === 'redirect' ? 'navigate' : 'patch';
        var pc = el.getAttribute('phx-click');
        if (pc) {
          if (pc.startsWith('[')) {
            if (pc.indexOf('"navigate"') !== -1) return 'navigate';
            if (pc.indexOf('"patch"') !== -1) return 'patch';
            if (pc.indexOf('"push"') !== -1) return 'patch';
            return 'none';
          }
          return 'patch';
        }
        // Only buttons/inputs that submit a form trigger navigation.
        // type='reset' and type='button' run JS but never submit/navigate.
        var submits = (el.type === 'submit' || el.type === 'image') ||
                      (el.tagName === 'BUTTON' && el.type !== 'reset' && el.type !== 'button');
        if (submits) {
          var f = el.closest('form');
          if (f && f.hasAttribute('phx-trigger-action')) return 'full_page';
          if (f && f.getAttribute('phx-submit')) return 'patch';
          if (f) return 'full_page';
        }
        var a = el.closest('a[href]');
        if (a && a.getAttribute('href') && !a.getAttribute('href').startsWith('#')) {
          // target="_blank" / target="newwindow" / etc. open in a new tab —
          // the source page doesn't navigate, so don't await a load.
          var tgt = a.getAttribute('target');
          if (tgt && tgt !== '_self' && tgt !== '_top' && tgt !== '_parent') return 'none';
          // onclick handler may preventDefault — can't statically tell.
          // Defer to the JS to decide; if it does navigate, downstream
          // assertions will retry-with-timeout anyway.
          if (a.hasAttribute('onclick')) return 'none';
          return 'full_page';
        }
        return 'none';
      }
      if (type === 'change') {
        var phxC = el.getAttribute('phx-change') || (el.form && el.form.getAttribute('phx-change'));
        return phxC ? 'patch' : 'none';
      }
      return 'none';
    };

    // --- Opcode interpreter ---
    // Executes an array of opcodes against a root element.
    // Returns {els, meta, error} where meta has classification/prepared.
    W.exec = function(ops, root) {
      var els = [], meta = {}, error = null;
      for (var i = 0; i < ops.length; i++) {
        var op = ops[i], cmd = op[0];
        try {
          switch(cmd) {
            case 'query':
              var t = op[1], sel = op[2], ctx = root || document;
              if (t === 'css') {
                els = Array.from(ctx.querySelectorAll(sel));
              } else {
                if (!ctx.nodeType) ctx = document;
                var xr = document.evaluate(sel, ctx, null, 7, null);
                els = [];
                for (var j = 0; j < xr.snapshotLength; j++) els.push(xr.snapshotItem(j));
              }
              break;
            case 'visible':
              var wantVis = op[1];
              els = wantVis ? els.filter(W.isVisible) : els.filter(function(e) { return !W.isVisible(e); });
              break;
            case 'text':
              var txt = op[1];
              els = els.filter(function(e) {
                var t = (e.innerText || e.textContent || '').replace(/[\s\u00a0]+/g, ' ').trim();
                return t.indexOf(txt) !== -1;
              });
              break;
            case 'selected':
              var wantSel = op[1];
              els = wantSel
                ? els.filter(function(e) { return e.selected || e.checked || false; })
                : els.filter(function(e) { return !(e.selected || e.checked); });
              break;
            case 'classify':
              if (els.length > 0) meta.classification = W.classify(els[0], op[1]);
              else meta.classification = 'none';
              break;
            case 'prepare_patch':
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
                meta.prepared = true;
              }
              break;
            case 'click':
              // Capture result BEFORE clicking (click may navigate)
              meta.count = els.length;
              W.clickEl(els[0]);
              break;
          }
        } catch(e) {
          error = e.message || String(e);
          els = [];
          break;
        }
      }
      return {els: els, meta: meta, error: error};
    };

    // --- Query checker ---
    W.check = function() {
      for (var id in W.queries) {
        var q = W.queries[id];
        if (q.resolved) continue;
        var result = W.exec(q.ops, q.root);
        if (result.error) {
          q.resolved = true;
          try { __wallabidi(JSON.stringify({id: id, count: 0, error: result.error})); } catch(e) {}
          continue;
        }
        var count = result.meta.count != null ? result.meta.count : result.els.length;
        var match = q.count == null ? count > 0 : count === q.count;
        if (match) {
          q.resolved = true;
          q.elements = result.els;
          q.meta = result.meta;
          try { __wallabidi(JSON.stringify({id: id, count: count, meta: result.meta})); } catch(e) {}
        }
      }
    };

    // MutationObserver on document (before body exists)
    new MutationObserver(function() {
      requestAnimationFrame(W.check);
    }).observe(document, {childList: true, subtree: true, attributes: true, characterData: true});

    // --- Page-ready detection + LiveView patch hook ---
    //
    // Each new document gets a fresh pageId. When the page is ready
    // (DOM parsed + LV connected mount applied, OR non-LV detected),
    // we set pageReady and fire a channel notification. Elixir captures
    // the pre-click pageId, then waits for a page_ready notification
    // with a new pageId. Fully event-driven, no polling.
    //
    // For LV pages, the canonical "connected mount applied" signal is
    // `phx:page-loading-stop` with `detail.kind === "initial"`. It's a
    // public, documented LV event (same one NProgress integrations
    // hook into). It fires from `withPageLoading`'s `done` closure
    // inside `applyJoinPatch`, AFTER the join's diff has been
    // performPatch'd into the DOM and AFTER `joinPending = false`.
    // We listen on window — listener can be installed before
    // `liveSocket` exists, so no construction-order race.
    //
    // `phx:page-loading-stop` also fires for `kind: "patch"`
    // (live_redirect via pushHistoryPatch) and `kind: "redirect"`
    // (replaceMain) — both bump pageId via the same listener.
    //
    // Plain `phx-click → diff` interactions don't fire
    // page-loading-stop (only navigations and elements with
    // phx-page-loading do). For those, we still patch
    // `domCallbacks.onPatchEnd` to bump pageId on every diff. The
    // hook is installed lazily — first time we see liveSocket, but no
    // earlier than DOMContentLoaded.
    W.pageId = Date.now() + '-' + Math.random().toString(36).slice(2, 8);
    W.pageReady = false;
    W.lvHooked = false;

    function bumpPageId() {
      W.pageId = Date.now() + '-' + Math.random().toString(36).slice(2, 8);
      W.pageReady = true;
      try { __wallabidi(JSON.stringify({type: 'page_ready', pageId: W.pageId})); } catch(e) {}
    }

    function installLvHook() {
      if (W.lvHooked) return true;
      try {
        var ls = window.liveSocket;
        if (ls && ls.domCallbacks) {
          var origPatch = ls.domCallbacks.onPatchEnd;
          ls.domCallbacks.onPatchEnd = function(c) {
            if (origPatch) origPatch(c);
            W.check();
            bumpPageId();
          };
          W.lvHooked = true;
          return true;
        }
      } catch(e) {}
      return false;
    }

    function markReady() {
      if (W.pageReady) return;
      W.pageReady = true;
      try { __wallabidi(JSON.stringify({type: 'page_ready', pageId: W.pageId})); } catch(e) {}
    }

    // Listener installed early (before liveSocket exists) — no race.
    // Fires on initial join, live_redirect, replaceMain. Each of those
    // means navigation/connection completed and the diff is in the DOM.
    window.addEventListener('phx:page-loading-stop', function(e) {
      // Try to install the patch hook here too — by the time
      // page-loading-stop fires, liveSocket definitely exists. This
      // covers the case where DOMContentLoaded ran before app.js.
      installLvHook();
      bumpPageId();
    });

    document.addEventListener('DOMContentLoaded', function() {
      // Non-LV page: ready as soon as DOM is parsed.
      if (!document.querySelector('[data-phx-session]')) {
        return markReady();
      }
      // LV page: install the patch hook for plain phx-click → diff
      // interactions (which don't fire page-loading-stop). The
      // page-loading-stop listener above handles initial/redirect/
      // patch readiness — this hook handles everything else.
      installLvHook();
    });
    """
  end
end
