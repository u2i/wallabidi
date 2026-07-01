# Architecture

How wallabidi's drivers, transports, and the page-side opcode
interpreter fit together.

## Two halves

Wallabidi is BEAM-side Elixir on one half, page-side JavaScript
(`priv/wallabidi.js`) on the other. They communicate over a single
WebSocket per Chrome process or per Lightpanda binary, speaking CDP
or BiDi.

**Elixir side** keeps no per-element state beyond `%Element{}` structs.
Each element op turns into an opcode list shipped over the wire.

**Page side** holds the live DOM, runs the `W.run` interpreter, owns
the LiveView patch hook (`onPatchEnd`) and the `MutationObserver`
that re-checks pending queries, and publishes query-resolved events
back to Elixir via `Runtime.addBinding` (CDP) or
`script.addPreloadScript` channels (BiDi).

## The `W.run` opcode interpreter

The page-side bootstrap (installed via `Page.addScriptToEvaluateOnNewDocument`
on every new document) defines a single function:

```js
window.__w.run(ops, target)
```

Every Elixir → browser call dispatches through it. The wire payload
is an opcode list:

```
[["query","css",".btn"],["visible",true],["classify_first","click"],
 ["click_first"]]
```

The interpreter has three categories of opcodes:

- **Find / filter / pipeline ops** (`query`, `visible`, `text_includes`,
  `selected`, `classify_first`, `click_first`, …) — mutate the
  pipeline's `els[]` and `meta` accumulator. Used by Browser.find,
  Browser.click(query), etc.
- **Element ops** (`text`, `attribute`, `set_value_dom`, `clear`,
  `click`, `focus`, …) — read the bound `target` and return a value.
- **Document ops** (`url`, `path`, `title`, `await_selector`,
  `await_patch`, `await_lv_connected`, …) — operate at document
  scope; the target is ignored.

Plus a `target N` bridge that rebinds the function-argument `target`
to `els[N]` mid-pipeline — used by the lazy-element path below.

The interpreter handles a Promise-tail: if the last op produced a
thenable, `W.run` returns `result.then(v => …)` so the caller's
`awaitPromise: true` sees the resolved value. Compound async ops
(click_aware, fill_in, has_text) compose into single Promises this
way.

## Fused operations

Several Browser-level operations that were historically multi-step
fuse into one Promise on the page side:

- `await_ready_classify_and_click` — awaits LV-ready, classifies,
  optionally arms `preparePatch`, captures `pageId` and `ref`,
  clicks. Returns `{classification, prePageId, preRef}` after the
  click. **One round-trip** for what was 4 in the legacy click path.
- `fillIn(el, value, drainIdleMs)` — silent clear + set value +
  (when LV-aware) drain patches. **One round-trip** vs three.
- `setChecked(el, target)` — reads state, clicks only if it differs.
  **One round-trip** vs two.
- `awaitElementMatch(el, kind, target, timeoutMs)` —
  MutationObserver + onPatchEnd-driven match for `el.value === target`
  (used by `has_value?`) or `el.textContent.includes(target)` (used
  by `has_text?` / `assert_text`). **One round-trip** vs an
  Elixir-side polling loop.

Each fused op exists because the Elixir side has no decisions to make
between the steps. The fusion happens in `priv/wallabidi.js`; the
Elixir entry points (in <code>Wallabidi.Remote.OpsShared</code>) just ship the
opcode and `await_promise: true`.

## Lazy elements

Elements have a `handle` field. Three shapes:

- A string (CDP `objectId` or BiDi `sharedId`) — eager V8 reference.
- `{:lazy, ops, index, parent_id}` — lazy: the element op pipeline
  hasn't been ref-fetched, just the count was returned. Element ops
  on a lazy element re-resolve the query inline by splicing
  `[query_ops, ["target", index], <caller's ops>]` into a single
  `W.run` dispatch. Saves the ref-fetch round-trip that Wallaby pays
  on every find.
- `{:lv_element, sel, idx, html}` — pseudo-ref used by the LV driver
  (no V8, just a re-resolvable identity).

Browser APIs that find-then-op-then-discard (the majority: `text/2`,
`attr/3`, `has_value?/3`, `selected?/2`, `fill_in/3`, `clear/2`,
`set_value/3`, `send_keys/3`, `has_text?/2,3`, `assert_text/3`,
`click/2`'s primary path) use the lazy path. The user-facing
`find/2` still materializes refs because callers expect to hold
elements across arbitrary subsequent ops.

The lazy element struct still carries `parent_id` so scoped finds
(`select |> selected?(option("X"))`) re-resolve under the same parent
scope — the dispatch uses `callFunctionOn`/`script.callFunction`
with `this` bound to the parent's V8 ref.

## Driver-by-driver process model

Each driver chooses its own transport shape based on what its target
browser supports.

### Chrome CDP — shared WebSocket

```
                    ┌──────────────────────┐
  Test process ─────→  Wallabidi.WebSocket │  one WS to Chrome
                    │  (BEAM-wide singleton)│  per BEAM
                    └──────────┬───────────┘
                               │ flat-session-id routing
                  ┌────────────┼────────────┐
                  ▼            ▼            ▼
              Session A    Session B    Session C
              (Browser     (Browser     (Browser
               Context A)   Context B)   Context C)
```

One `Remote.WebSocket` GenServer per BEAM holds the WS to
Chrome (via <code>Wallabidi.Remote.Chrome.SharedConnection</code>). Sessions
multiplex over that one socket using CDP's flat-session protocol —
each session has its own `BrowserContext` + `Target`, and CDP frames
carry a `sessionId` field that routes responses/events to the right
Session GenServer.

This is the cheap-isolation model Playwright uses: the browser
process is shared across the BEAM lifetime, but each test gets a
fresh `BrowserContext` with isolated cookies/storage/cache.

**Trade-off**: every CDP frame from every session goes through the
shared WebSocket's GenServer mailbox. Under high concurrency, frames
serialize there.

### Chrome BiDi — per-session WebSocket via chromium-bidi

```
  Test process ──→ Session A ──→ WS_A ──┐
  Test process ──→ Session B ──→ WS_B ──┼──→ chromium-bidi server ──→ Chrome
  Test process ──→ Session C ──→ WS_C ──┘
```

The chromium-bidi node server (in `priv/bidi-server/`) sits between
wallabidi and Chrome. Each session opens its own WebSocket to the
chromium-bidi server, which provisions a Chrome
`browsingContext`/`userContext` for it. wallabidi-side, sessions
don't share state at all.

**Trade-off**: chromium-bidi imposes its own internal session
capacity (typically 8–10). At high test concurrency this becomes the
real bottleneck, not anything on the wallabidi side.

### Lightpanda — per-session WebSocket to a shared LP server

```
  Test process ──→ Session A ──→ WS_A ──┐
  Test process ──→ Session B ──→ WS_B ──┼──→ Lightpanda binary
  Test process ──→ Session C ──→ WS_C ──┘
```

Lightpanda enforces "one BrowserContext per CDP connection," so
sharing a WS across sessions isn't possible. Each session opens its
own raw Mint WebSocket to the shared Lightpanda binary
(`Lightpanda.Server`). LP's `--cdp-max-connections` (default 24)
caps how many sessions can run concurrently.

**Trade-off**: no shared-WS contention, but every session pays a
WS handshake cost.

### LiveView — no browser at all

```
  Test process ──→ Session ──→ Phoenix.LiveViewTest
```

The `:live_view` driver is in-process: it dispatches directly to
Phoenix.LiveViewTest's harness without going through any browser.
Fastest by far for LiveView-only test scenarios; cannot test
anything that requires real DOM, mouse, keyboard, or non-LV
JavaScript.

## Session lifecycle

A session represents one isolated test environment. Today's default:
session lifetime = test lifetime. `Wallabidi.start_session` creates
one (driver-specific build steps), the test uses it,
`Wallabidi.end_session` disposes it. The underlying actor monitors
the test process — if the test crashes, the session is torn down
automatically.

For Chrome CDP specifically, that build sequence is:

1. `Target.createBrowserContext` — fresh isolated context
2. `Target.createTarget(url: "about:blank", browserContextId: ...)`
3. `Target.attachToTarget(flatten: true)` — returns the `sessionId`
4. `Page.enable` + `Page.setLifecycleEventsEnabled` (cast)
5. `Runtime.addBinding("__wallabidi")` + `Page.addScriptToEvaluateOnNewDocument`
   pipelined behind one `Page.getFrameTree` barrier
6. `Runtime.executionContextCreated/Destroyed` subscribes for frame
   tracking

Teardown is `Target.disposeBrowserContext`. The shared WS itself
stays alive across sessions.

## Concurrency model

One Chrome process per BEAM. Sessions multiplex over a single
`Remote.WebSocket` via CDP's flat-session-id, with each
session isolated by its own BrowserContext. This is the
Playwright-default shape: amortize browser startup across the BEAM
lifetime, throw away contexts cheaply per test.

For Chrome BiDi the same applies with one chromium-bidi Node process
per BEAM. Lightpanda runs its own one-process-many-WS model.
LiveView uses no browser at all.

### Reliability and concurrency under load

Measured on the [perf_bench](https://github.com/u2i/perf_bench)
LiveView scenario suite (136 tests, all happy-path), single-run
wallclock:

| mc | LiveView | Lightpanda | Chrome CDP | Chrome BiDi    | Wallaby (chromedriver) |
|---:|---:|---:|---:|---:|---:|
| 1  | 15s | 43s | 68s | 486s           | 218s |
| 2  | 9s  | 22s | 52s | 100s           | 122s |
| 4  | 6s  | 12s | 48s | 71s            | 80s  |
| 8  | 4s  | 8s  | 51s | 68s            | 69s, 4 flakes |
| 16 | 4s  | 8s  | 52s | 259s, 2 flakes | 70s, 5 flakes |

Chrome BiDi's mc=16 result reproduces the structural chromium-bidi
contention we've measured before: the BiDi Mapper is single-threaded
JS in one Chrome tab, so once concurrent sessions saturate it, both
wallclock and reliability degrade. mc=8 is the practical ceiling.

Wallaby's mc≥8 results show a different structural limit:
chromedriver creates a fresh CDP session per test, and concurrent
session-creation requests start timing out under contention. The
total wallclock at mc=8 actually beats Chrome BiDi, but Wallaby
trades that for ~3% test flakiness.

LiveView and Lightpanda both plateau cleanly (4s and 8s respectively
at mc≥8 — they've hit the limit of test work, not protocol limits).
Chrome CDP plateaus around 50s and stays reliable through mc=16.

### Speed picking guide

- **LiveView** — fastest by a wide margin (~4s/136 tests at mc=8).
  Use where the test doesn't need a real DOM.
- **Lightpanda** — fastest browser driver (~8s/136 at mc=8), about
  2× LiveView. Reliable through mc=16.
- **Chrome CDP** — ~50s/136 at mc≥4, ~6× Lightpanda. Use for tests
  that need real Chrome semantics (CSS visibility, screenshots,
  native mouse).
- **Chrome BiDi** — ~68s/136 at mc=8 (best case). chromium-bidi
  routes everything through a single Node-side Mapper per Chrome, so
  concurrency past mc=8 actively hurts (contention causes timeouts).
  Available for tests that specifically exercise the WebDriver BiDi
  protocol.

### Why no server pool

Earlier iterations shipped Chrome and BiDi server pools that
spawned N independent browser processes and round-robined sessions
across them. The Chrome pool measured a real ~25% wallclock win
at mc=8 in isolated runs, but:

1. Run-to-run variance was wider than the win
2. Single Chrome at default mc=16 is already flake-free
3. Each extra Chrome adds 200–500MB resident memory
4. Tests typically share CI runners with other work; memory cost
   matters more than a 25% wallclock that stays within total CI noise

Both pools were removed. The architectural lesson: most workloads
don't need it, and the ones that do already have headroom in
choice-of-driver (Lightpanda > Chrome CDP for speed) rather than
process count.

## Useful entry points

**Public API**

- `Wallabidi.start_session/1`, `Wallabidi.end_session/1`
- `Wallabidi.Browser.*` — high-level test API
- `Wallabidi.Query`, `Wallabidi.Element`

**Internals (in order of how deep you go)**

- <code>Wallabidi.Remote.OpsShared</code> — the using-module macro that gives
  CDP and BiDi clients identical W.run dispatch wrappers for element
  ops (text, attribute, click, fill_in, classify, set_checked,
  await_value, await_text, …).
- <code>Wallabidi.Remote.CDP.Client</code> / <code>Wallabidi.Remote.BiDi.Client</code> —
  protocol-specific clients. Hold `call_on_element/5` (which
  recognizes lazy refs), `find_elements/3` / `find_elements_lazy/3`,
  `click_aware`, frame-switching, geometry, cookies, screenshots.
- <code>Wallabidi.Remote.LiveViewAware</code> — thin BEAM-side adapter for the
  LV-aware document-scope ops (prepare_patch, await_patch, await_ack,
  await_selector, live_view_connected).
- <code>Wallabidi.Remote.Bootstrap</code> — bakes `priv/wallabidi.js` into the
  BEAM and produces the CDP/BiDi install forms.
- `priv/wallabidi.js` — the page-side bootstrap. Defines `W.run`, the
  fused ops, the find-pipeline result push, and the `onPatchEnd` +
  `MutationObserver` hooks.
- <code>Wallabidi.Remote.Transport.Session</code> — per-session GenServer that
  owns the wire layer for one session (whichever transport shape
  the driver picked).
- `Remote.WebSocket` — the Mint WebSocket actor. Shared
  across sessions on Chrome CDP; per-session on BiDi and Lightpanda.
