// Browser-side bootstrap for wallabidi push-based element finding.
//
// Installs window.__w with: visibility check, click handler, classifier,
// opcode interpreter, MutationObserver-driven query checker, page-ready
// detection, and LiveView onPatchEnd hook.
//
// References `__wallabidi` as a free variable — the caller wraps this
// body in either:
//   - CDP: `(function(){ ... })()` IIFE; __wallabidi is a global binding
//          installed via Runtime.addBinding.
//   - BiDi: `(__wallabidi) => { ... }` arrow; __wallabidi is the channel
//          callback passed in via script.addPreloadScript.
//
// Source of truth: this file. Wallabidi.Bootstrap embeds it at compile
// time via @external_resource + File.read!.

if (window.__w) return;
var W = window.__w = {};
W.queries = {};

// --- Internal helpers ---

// Fire `input` then `change` events. Used by every value-mutating op
// so consumers (controlled inputs, phx-change handlers) see the update.
function fireInputChange(el) {
  el.dispatchEvent(new Event('input', {bubbles: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
}

// Send a JSON payload up the channel binding. Wrapped because the
// binding may not exist in every execution context (e.g. iframes).
function send(payload) {
  try { __wallabidi(JSON.stringify(payload)); } catch (e) {}
}

function newPageId() {
  return Date.now() + '-' + Math.random().toString(36).slice(2, 8);
}

// Wraps liveSocket.domCallbacks.onPatchEnd so `cb(container)` is invoked
// after the original handler. Returns a `restore` function that puts the
// previous handler back. No-ops when there's no LiveSocket.
function wrapPatchEnd(cb) {
  var ls = window.liveSocket;
  if (!ls || !ls.domCallbacks) return function() {};
  var orig = ls.domCallbacks.onPatchEnd;
  ls.domCallbacks.onPatchEnd = function(container) {
    if (orig) orig(container);
    cb(container);
  };
  return function() { ls.domCallbacks.onPatchEnd = orig; };
}

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

// --- Element operations ---
// These are the JS primitives behind Wallabidi's per-element API. The
// Elixir side calls Runtime.callFunctionOn (CDP) / script.callFunction
// (BiDi) with `function(ops) { return W.run(ops, this); }` — the wire
// payload is just an opcode list, dispatched through the W.run
// interpreter to the helpers below.

// Stale-element sentinel: returned when the element is detached. The
// Elixir client translates this to {:error, :stale_reference}.
W.STALE = {__wallabidi_stale: true};

W.attribute = function(el, name) {
  if (el && !el.isConnected) return W.STALE;
  if (name === 'value' && 'value' in el) return el.value;
  if (name === 'checked') return el.checked ? 'true' : null;
  if (name === 'selected') return el.selected ? 'true' : null;
  if (name === 'outerHTML') return el.outerHTML;
  if (name === 'innerHTML') return el.innerHTML;
  return el.getAttribute(name);
};

W.text = function(el) {
  var blocks = ['DIV','P','H1','H2','H3','H4','H5','H6','LI','TR','BR',
                'SECTION','ARTICLE','HEADER','FOOTER','NAV','MAIN','UL','OL','DL',
                'BLOCKQUOTE','PRE','TABLE','THEAD','TBODY','TFOOT','FORM','FIELDSET','HR'];
  function walk(node) {
    if (node.nodeType === 3) return node.nodeValue.replace(/\s+/g, ' ');
    if (node.nodeType !== 1) return '';
    if (node.tagName === 'BR') return '\n';
    var parts = [];
    for (var i = 0; i < node.childNodes.length; i++) {
      parts.push(walk(node.childNodes[i]));
    }
    var text = parts.join('');
    if (blocks.indexOf(node.tagName) >= 0) text = '\n' + text + '\n';
    return text;
  }
  var result = walk(el);
  return result.split('\n').map(function(l) { return l.trim(); }).filter(Boolean).join('\n');
};

// Geometry. mode: 'rect' (full {x,y,width,height}), 'size' ([w,h]),
// 'position' ([x,y]), 'center' ({x,y}), 'origin' ({x,y}).
W.rect = function(el, mode) {
  var r = el.getBoundingClientRect();
  switch (mode) {
    case 'size':     return [Math.round(r.width), Math.round(r.height)];
    case 'position': return [Math.round(r.x), Math.round(r.y)];
    case 'center':   return {x: r.x + r.width / 2, y: r.y + r.height / 2};
    case 'origin':   return {x: r.x, y: r.y};
    default:         return {x: r.x, y: r.y, width: r.width, height: r.height};
  }
};

W.setValue = function(el, v) {
  var t = el.tagName;
  var ty = (el.type || '').toLowerCase();

  if (t === 'INPUT' && (ty === 'checkbox' || ty === 'radio')) {
    el.checked = !!v;
    fireInputChange(el);
    return null;
  }

  if (t === 'OPTION') {
    var sel = el.closest('select');
    if (sel) {
      if (sel.multiple) {
        el.selected = !!v;
      } else {
        sel.value = el.value;
        for (var i = 0; i < sel.options.length; i++) {
          sel.options[i].selected = (sel.options[i] === el);
        }
      }
      fireInputChange(sel);
    } else {
      el.selected = !!v;
    }
    return null;
  }

  el.value = v;
  fireInputChange(el);
  return null;
};

// silent=true skips dispatching input/change events (used internally
// before fill_in to avoid firing phx-change for the empty intermediate).
W.clear = function(el, silent) {
  el.value = '';
  if (!silent) fireInputChange(el);
  return null;
};

W.sendKeysText = function(el, s) {
  el.value = (el.value || '') + s;
  fireInputChange(el);
  return null;
};

W.isFileInput = function(el) {
  return el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'file';
};

// True if the element is in the "selected" state — covers both
// checkbox/radio (`checked`) and <option> (`selected`).
W.isSelected = function(el) {
  return el.checked === true || el.selected === true;
};

W.focus = function(el) {
  el.focus();
  return null;
};

// Wait for liveSocket.main to finish its JoinPending phase (or for there
// to be no LV at all), then classify the element for the given
// interaction. Returns a Promise resolving to the classification string.
// Times out after timeoutMs (defaults 5000) — on timeout, classifies
// anyway so the caller still gets a routable answer.
W.awaitLvReadyAndClassify = function(el, interaction, timeoutMs) {
  return new Promise(function(resolve) {
    // Classify synchronously first. Some classifications don't need
    // LV-channel readiness:
    //   * "full_page"  — form submits / plain <a href> leave the page;
    //                    the destination LV mounts fresh either way
    //   * "none"       — non-LV-aware element; waiting is pointless
    // Others (patch, navigate, change-without-classification-yet) DO
    // need LV ready, because the click dispatches a phx-event that the
    // current LV channel must receive.
    var classification = W.classify(el, interaction);
    if (classification === 'none' || classification === 'full_page') {
      return resolve(classification);
    }

    function done() { resolve(classification); }
    function isReady() {
      if (W.observedPatch === true) return true;
      var ls = window.liveSocket;
      if (!ls || !ls.main) return true;
      if (typeof ls.main.isJoined === 'function' && ls.main.isJoined()) return true;
      if (ls.main.joinPending !== true) return true;
      return false;
    }

    if (isReady()) return done();

    var deadline = Date.now() + (timeoutMs || 5000);
    function check() {
      if (isReady()) return done();
      if (Date.now() > deadline) return done();
      setTimeout(check, 20);
    }
    check();
  });
};

// --- LiveView-aware operations ---
// These were previously inlined as JS heredocs in
// lib/wallabidi/remote/live_view_aware.ex. Keeping them here means
// (a) one source of truth for the page-side logic, (b) the bundle is
// installed once via Page.addScriptToEvaluateOnNewDocument so callers
// just invoke W.x() rather than shipping fresh JS each call.

// Install a one-shot promise on window.__wallabidi_patch_promise that
// resolves after the next LiveView onPatchEnd fires (or to "navigated"
// if a beforeunload happens first). Idempotent.
W.preparePatch = function() {
  if (!window.liveSocket || !window.liveSocket.main) return false;
  if (!window.__wallabidi_patch_hooked) {
    wrapPatchEnd(function() {
      if (window.__wallabidi_patch_resolve) {
        var r = window.__wallabidi_patch_resolve;
        window.__wallabidi_patch_resolve = null;
        r(true);
      }
    });
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
  return true;
};

// Resolve when the patch promise installed by preparePatch settles, or
// after `timeoutMs`. If no promise is in flight we return 'no-promise'
// so the caller can distinguish stale from "patch never armed."
W.awaitPatch = function(timeoutMs) {
  if (!window.__wallabidi_patch_promise) return Promise.resolve('no-promise');
  var p = window.__wallabidi_patch_promise;
  window.__wallabidi_patch_promise = null;
  return Promise.race([
    p,
    new Promise(function(resolve) { setTimeout(function() { resolve(false); }, timeoutMs || 5000); })
  ]);
};

// Resolve once no LV patch has fired for `idleMs`. Used after multi-
// event interactions (fill_in fires phx-change for each char) where we
// want the post-quiet state, not the first patch.
W.drainPatches = function(idleMs) {
  if (!window.liveSocket || !window.liveSocket.domCallbacks) return Promise.resolve(true);
  return new Promise(function(resolve) {
    var timer = null;
    var idle = idleMs || 300;
    var restore;
    function done() { restore(); resolve(true); }
    function reset() {
      if (timer) clearTimeout(timer);
      timer = setTimeout(done, idle);
    }
    restore = wrapPatchEnd(reset);
    reset();
  });
};

// Resolve once liveSocket.main.lastAckRef >= target, meaning the
// server has finished processing whatever event our click triggered
// (regardless of whether it produced a diff, redirect, or nothing).
// Returns 'acked' / 'no-liveview' / 'navigated' / false.
W.awaitAck = function(target, timeoutMs) {
  return new Promise(function(resolve) {
    var deadline = Date.now() + (timeoutMs || 5000);
    function check() {
      var ls = window.liveSocket;
      if (!ls || !ls.main) return resolve('no-liveview');
      if (ls.main.lastAckRef !== null && ls.main.lastAckRef >= target) return resolve('acked');
      if (Date.now() > deadline) return resolve(false);
      setTimeout(check, 20);
    }
    window.addEventListener('beforeunload', function() {
      resolve('navigated');
    }, {once: true});
    check();
  });
};

// Resolve when a CSS selector matches in the live DOM, using
// MutationObserver + onPatchEnd hooks. opts.text adds a text-includes
// constraint. Resolves 'navigated' if the page navigates mid-wait.
W.awaitSelector = function(selector, opts) {
  opts = opts || {};
  var text = opts.text || null;
  var timeoutMs = opts.timeoutMs || 200;

  function matches() {
    if (!text) return !!document.querySelector(selector);
    var els = document.querySelectorAll(selector);
    for (var i = 0; i < els.length; i++) {
      if (els[i].textContent.indexOf(text) !== -1) return true;
    }
    return false;
  }

  if (matches()) return Promise.resolve(true);

  return new Promise(function(resolve) {
    var timer = setTimeout(function() { cleanup(); resolve(false); }, timeoutMs);
    var restorePatchEnd = wrapPatchEnd(function() {
      if (matches()) { cleanup(); resolve(true); }
    });
    var observer = new MutationObserver(function() {
      requestAnimationFrame(function() {
        if (matches()) { cleanup(); resolve(true); }
      });
    });
    observer.observe(document.body, {
      childList: true, subtree: true,
      attributes: true, characterData: true
    });

    var startUrl = window.location.href;
    function onNav() { cleanup(); resolve('navigated'); }
    window.addEventListener('beforeunload', onNav, {once: true});
    var navCheck = setInterval(function() {
      if (window.location.href !== startUrl) {
        requestAnimationFrame(function() {
          if (matches()) { cleanup(); resolve(true); }
          else { cleanup(); resolve('navigated'); }
        });
      }
    }, 50);
    function cleanup() {
      clearTimeout(timer);
      clearInterval(navCheck);
      observer.disconnect();
      window.removeEventListener('beforeunload', onNav);
      restorePatchEnd();
    }
  });
};

W.liveViewConnected = function() {
  var ls = window.liveSocket;
  if (!ls || !ls.main) return false;
  return !ls.main.joinPending;
};

// Wait until the current page's LiveSocket is connected. preUrl forces
// a "wait for URL change first" mode used post-navigation. Resolves
// true / 'no-liveview' / false (timeout).
W.awaitLiveViewConnected = function(preUrl, timeoutMs) {
  return new Promise(function(resolve) {
    var deadline = Date.now() + (timeoutMs || 5000);
    function check() {
      if (preUrl && window.location.href === preUrl) {
        if (Date.now() > deadline) return resolve(false);
        return setTimeout(check, 30);
      }
      if (document.readyState === 'loading') {
        if (Date.now() > deadline) return resolve(false);
        return setTimeout(check, 20);
      }
      if (!document.querySelector('[data-phx-session]')) return resolve('no-liveview');
      var ls = window.liveSocket;
      if (ls && ls.main && !ls.main.joinPending) return resolve(true);
      if (Date.now() > deadline) return resolve(false);
      setTimeout(check, 30);
    }
    check();
  });
};

// --- Trivia accessors ---
// Stable callable shims for common one-line evaluates. Each replaces
// a per-call JS string compile with a stable call.
W.url = function() { return location.href; };
W.path = function() { return location.pathname; };
W.title = function() { return document.title; };
W.source = function() { return document.documentElement.outerHTML; };
W.getWindowSize = function() {
  return JSON.stringify(window.__wallabidi_window_size ||
    {width: window.innerWidth, height: window.innerHeight});
};
W.setWindowSize = function(w, h) {
  window.__wallabidi_window_size = {width: w, height: h};
};

// Register a push-find query and trigger an immediate check. Called
// from the Elixir side via Runtime.evaluate / Runtime.callFunctionOn
// with this body wrapped in a function — bootstrap is already
// installed by then, so we don't need any fallback path here.
W.registerQuery = function(id, ops, count, root) {
  W.queries[id] = {
    ops: ops,
    count: count,
    resolved: false,
    elements: [],
    root: root
  };
  W.check();
};

W.cleanupQuery = function(id) {
  if (W.queries) delete W.queries[id];
};

// --- Unified opcode runner ---
//
// Single page-side entry point invoked from the Elixir side. Takes an
// array of opcodes, runs them in order, returns the pipeline result.
//
// Three call shapes (same wire form, different meaning):
//
//   1. Element-scoped single op:
//      callFunctionOn `function(ops){return W.run(ops,this);}` with
//      ops = `[["text"]]`. Returns the element's text.
//
//   2. Element-scoped find pipeline:
//      same shape, ops = `[["query","css",".foo"], ["visible",true]]`.
//      Returns `{els, meta, error}` since the ops mutated els[].
//
//   3. Document-scope op:
//      Runtime.evaluate `window.__w.run([["url"]])` (no target).
//      Returns the last op's primary value.
//
// Op categories:
//
//   * Element ops — read `target`, return a value.
//   * Find/filter ops — mutate els[]; force runner to return
//     `{els, meta, error}` shape.
//   * Document ops — global; ignore target. Some return Promises (the
//     BEAM uses awaitPromise: true for those, see Op.async?/1).
//
// The runner returns the last op's value, except when find/filter ops
// were used — then it returns the {els, meta, error} accumulator.
W.run = function(ops, target) {
  var els = [], meta = {}, error = null, value;
  var stateful = false;

  for (var i = 0; i < ops.length; i++) {
    var op = ops[i] || [], cmd = op[0];
    try {
      switch (cmd) {
        // --- Find / filter / pipeline ops (mutate els[]) ---
        case 'query': {
          var ctx = target || document;
          if (op[1] === 'css') {
            els = Array.from(ctx.querySelectorAll(op[2]));
          } else {
            if (!ctx.nodeType) ctx = document;
            var xr = document.evaluate(op[2], ctx, null, 7, null);
            els = [];
            for (var j = 0; j < xr.snapshotLength; j++) els.push(xr.snapshotItem(j));
          }
          stateful = true;
          break;
        }
        case 'visible':
          els = op[1]
            ? els.filter(W.isVisible)
            : els.filter(function(e) { return !W.isVisible(e); });
          stateful = true;
          break;
        case 'text_includes': {
          var txt = op[1];
          els = els.filter(function(e) {
            var t = (e.innerText || e.textContent || '').replace(/[\s ]+/g, ' ').trim();
            return t.indexOf(txt) !== -1;
          });
          stateful = true;
          break;
        }
        case 'selected':
          els = op[1]
            ? els.filter(W.isSelected)
            : els.filter(function(e) { return !W.isSelected(e); });
          stateful = true;
          break;
        case 'classify_first':
          meta.classification = els.length > 0 ? W.classify(els[0], op[1]) : 'none';
          stateful = true;
          break;
        case 'click_first':
          meta.count = els.length;
          W.clickEl(els[0]);
          stateful = true;
          break;
        case 'prepare_patch_filter':
          if (W.preparePatch()) meta.prepared = true;
          stateful = true;
          break;

        // --- Element ops — read target. ---
        case 'text':           value = W.text(target); break;
        case 'attribute':      value = W.attribute(target, op[1]); break;
        case 'displayed':      value = W.isVisible(target); break;
        case 'rect':           value = W.rect(target, op[1]); break;
        case 'set_value_dom':  value = W.setValue(target, op[1]); break;
        case 'clear':          value = W.clear(target, op[1]); break;
        case 'send_keys_text': value = W.sendKeysText(target, op[1]); break;
        case 'is_file_input':  value = W.isFileInput(target); break;
        case 'is_selected':    value = W.isSelected(target); break;
        case 'focus':          value = W.focus(target); break;
        case 'click':          value = W.clickEl(target); break;
        case 'classify':       value = W.classify(target, op[1]); break;
        case 'await_lv_ready_and_classify':
          value = W.awaitLvReadyAndClassify(target, op[1], op[2]); break;

        // --- Document ops — global. ---
        case 'prepare_patch':       value = W.preparePatch(); break;
        case 'await_patch':         value = W.awaitPatch(op[1]); break;
        case 'drain_patches':       value = W.drainPatches(op[1]); break;
        case 'await_ack':           value = W.awaitAck(op[1], op[2]); break;
        case 'await_selector':      value = W.awaitSelector(op[1], op[2]); break;
        case 'live_view_connected': value = W.liveViewConnected(); break;
        case 'await_lv_connected':  value = W.awaitLiveViewConnected(op[1], op[2]); break;
        case 'url':                 value = W.url(); break;
        case 'path':                value = W.path(); break;
        case 'title':               value = W.title(); break;
        case 'source':              value = W.source(); break;
        case 'get_window_size':     value = W.getWindowSize(); break;
        case 'set_window_size':     value = W.setWindowSize(op[1], op[2]); break;

        default:
          error = 'unknown op: ' + cmd;
          break;
      }
      if (error) break;
    } catch (e) {
      error = e.message || String(e);
      els = [];
      break;
    }
  }

  if (stateful) return {els: els, meta: meta, error: error};
  return value;
};

// --- Query checker ---
W.check = function() {
  for (var id in W.queries) {
    var q = W.queries[id];
    if (q.resolved) continue;
    var result = W.run(q.ops, q.root);
    if (result.error) {
      q.resolved = true;
      send({id: id, count: 0, error: result.error});
      continue;
    }
    var count = result.meta.count != null ? result.meta.count : result.els.length;
    var match = q.count == null ? count > 0 : count === q.count;
    if (match) {
      q.resolved = true;
      q.elements = result.els;
      q.meta = result.meta;
      send({id: id, count: count, meta: result.meta});
    }
  }
};

// MutationObserver on document (before body exists). Two coalesce
// optimizations on the hot path of busy pages:
//
//   (1) Skip entirely when no queries are pending — a heavy LV update
//       on a page with nothing in W.queries should cost zero check()
//       work, not a wasted rAF + empty-loop.
//
//   (2) Debounce: at most ONE check() per animation frame. Without
//       this, a flurry of mutations schedules N rAFs and check() runs
//       up to 60×/s on a busy page; with this, we run once per frame
//       no matter how many mutation batches fired.
var checkScheduled = false;
function scheduleCheck() {
  if (checkScheduled) return;
  // Cheap "any pending query?" test. Object.keys allocates; this avoids
  // it by short-circuiting on the first own property.
  var hasPending = false;
  for (var k in W.queries) { hasPending = true; break; }
  if (!hasPending) return;
  checkScheduled = true;
  requestAnimationFrame(function() {
    checkScheduled = false;
    W.check();
  });
}

new MutationObserver(scheduleCheck)
  .observe(document, {childList: true, subtree: true, attributes: true, characterData: true});

// --- Page-ready detection + LiveView patch hook ---
//
// Each new document gets a fresh pageId. When the page is ready
// (DOM parsed + LV connected mount applied, OR non-LV detected),
// we set pageReady and fire a channel notification. Elixir captures
// the pre-click pageId, then waits for a page_ready notification
// with a new pageId.
//
// State machine (each page_ready carries its current state):
//
//   Initial
//     │ DOMContentLoaded
//     │
//     ├─ no [data-phx-session] ─→ NonLVReady (terminal for non-LV)
//     │
//     └─ has [data-phx-session] ─→ AwaitingHook
//                                    │ liveSocket.domCallbacks present
//                                    ▼
//                                  HookInstalled
//                                    │ first onPatchEnd
//                                    ▼
//                                  LVReady ←─┐
//                                    │       │ subsequent
//                                    └───────┘ onPatchEnd
//
// Allowed transitions only. The Elixir side raises on invalid
// ones (e.g. LVReady → AwaitingHook on the same document) so we
// see violations instead of silently flaking.
W.pageId = newPageId();
W.docId = W.pageId; // stable identifier for the bootstrap's lifetime
W.pageReady = false;
W.lvHooked = false;
W.observedPatch = false;
W.state = 'Initial';

function transition(next) {
  W.state = next;
}

function notify(reason) {
  send({
    type: 'page_ready',
    pageId: W.pageId,
    docId: W.docId,
    state: W.state,
    reason: reason
  });
}

function bumpPageId(reason) {
  W.pageId = newPageId();
  W.pageReady = true;
  notify(reason || 'patch');
}

function installLvHook() {
  if (W.lvHooked) return true;
  try {
    var ls = window.liveSocket;
    if (ls && ls.domCallbacks) {
      var origPatch = ls.domCallbacks.onPatchEnd;
      ls.domCallbacks.onPatchEnd = function(c) {
        if (origPatch) origPatch(c);
        if (!W.observedPatch) {
          W.observedPatch = true;
          transition('LVReady');
        }
        W.check();
        bumpPageId('onPatchEnd');
      };
      W.lvHooked = true;
      transition('HookInstalled');
      return true;
    }
  } catch(e) {}
  return false;
}

function markReady(reason) {
  if (W.pageReady) return;
  W.pageReady = true;
  notify(reason);
}

function detectReady() {
  if (!document.querySelector('[data-phx-session]')) {
    transition('NonLVReady');
    return markReady('non-lv');
  }
  if (W.state === 'Initial') transition('AwaitingHook');
  var hooked = installLvHook();
  if (hooked && W.observedPatch) {
    return markReady('lv-ready');
  }
  if (W.pageReady) return; // bumpPageId beat us
  requestAnimationFrame(detectReady);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', detectReady);
} else {
  detectReady();
}
