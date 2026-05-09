# Architecture

How wallabidi's drivers, transports, and session pool fit together.

## Driver-by-driver process model

Each driver chooses its own transport shape based on what its target
browser supports.

### Chrome CDP V2 — shared WebSocket

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

One `Wallabidi.WebSocket` GenServer per BEAM holds the WS to Chrome
(via `Wallabidi.Chrome.SharedConnection`). Sessions multiplex over
that one socket using CDP's flat-session protocol — each session has
its own `BrowserContext` + `Target`, and CDP frames carry a
`sessionId` field that routes responses/events to the right Session
GenServer.

This is the cheap-isolation model Playwright uses: the browser
process is shared across the BEAM lifetime, but each test gets a
fresh `BrowserContext` with isolated cookies/storage/cache.

**Trade-off**: every CDP frame from every session goes through the
shared WebSocket's GenServer mailbox. Under high concurrency, frames
serialize there — see "When pooling helps" below.

### Chrome BiDi V2 — per-session WebSocket via chromium-bidi

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

### Lightpanda V2 — per-session WebSocket to a shared LP server

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

For Chrome CDP V2 specifically, that build sequence is:

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

## Session pooling

For Chrome CDP V2 only. The pool is opt-in via app config and
relieves shared-WS GenServer mailbox contention under high
concurrency.

### Why pool only for Chrome CDP V2

Pool wins come from one specific source: pre-warming N sessions at
pool startup so the per-session bring-up cost (steps 1–6 above)
isn't on the test critical path. That cost compounds under
concurrency because the bring-up RPCs serialize through the shared
WebSocket's GenServer mailbox.

For drivers without that mailbox shape:

- **Chrome BiDi**: each session has its own WS — no shared mailbox
  to relieve. Plus chromium-bidi's own internal session pool is the
  real bottleneck. Pooling here would just stack two pools and
  cause exhaustion.
- **Lightpanda**: per-session WS, no shared mailbox. Pre-warming
  buys nothing because nothing was queueing. Measured: 0% to +9%
  wallclock (slightly negative from bookkeeping overhead).
- **LiveView**: in-process, no transport at all. Pool would just
  add overhead.

Measured pool impact on perf_bench (136 tests):

| driver         | mc=1 | mc=4 | mc=8 |
|----------------|------|------|------|
| Chrome CDP V2  | 0%   | +3%  | **−22%** |
| Chrome BiDi V2 | net negative (collides w/ chromium-bidi pool) |
| Lightpanda V2  | ~0%  | 0%   | +9%  |

### Behaviour contract: `Wallabidi.Driver.Pool`

A driver wires into the pool by implementing this behaviour:

```elixir
@callback open_slot(opts) :: {:ok, handle} | {:error, reason}
@callback prepare_session(handle, session_opts) :: {:ok, session_state} | {:error, reason}
@callback finalize_session(handle, session_state | :crashed) :: :ok
@callback close_slot(handle) :: :ok

# optional
@callback reset_slot(handle) :: :ok | :must_recreate
```

Slot handle vs session state:

- **Handle** is per-slot, lasts the slot's lifetime (returned by
  `open_slot`, passed back to all subsequent calls). For Chrome CDP
  it's a small map referencing the shared WS pid.
- **Session state** is per-checkout, returned by `prepare_session`
  and passed to `finalize_session` on checkin. Holds the active
  Session struct + caller info.

### Phase 1 strategy: `:rebuild`

Today's behaviour. On checkin, `finalize_session` runs the standard
driver `end_session` — `Target.disposeBrowserContext` tears down the
BrowserContext, then the slot's `prepare_session` (called by the next
checkout) builds a fresh one.

Wins come from concurrent pre-warming at pool startup, not from
state-reuse on subsequent checkouts.

### `:reset` strategy (deferred)

A `reset_slot/1` callback could clear browser state in place
(`Network.clearBrowserCookies` + `Storage.clearDataForOrigin` +
`Page.navigate("about:blank")` + Session GenServer state cleanup +
input dispatcher reset) and keep the BrowserContext alive across
many tests. Unlike :rebuild, this would benefit mc=1 too.

Investigated and not yet shipped: Chrome's input dispatcher state
(pressed mouse buttons, partial touch sequences, modifier keys)
isn't fully clearable via standard CDP methods. Even with all the
state-reset Playwright uses (and more), residual cumulative drift
breaks input-sensitive tests under heavy load. Playwright sidesteps
this by defaulting to fresh-BrowserContext-per-test rather than
true reuse.

The `:reset` work is intentionally deferred — Phase 1's wins are
real, contained, and don't require the dispatcher-reset rabbit
hole.

### Configuration

Enable the pool via app config:

```elixir
# config/test.exs
config :wallabidi, :pools, %{chrome_cdp_v2: MyApp.WallabidiPool}
```

…then start the pool in your application supervisor or test helper:

```elixir
{:ok, _} =
  Wallabidi.Pool.start_link(
    name: MyApp.WallabidiPool,
    impl: Wallabidi.ChromeDriver.PoolImpl,
    size: System.schedulers_online()
  )
```

`Wallabidi.start_session/1` automatically routes through the
configured pool when one matches the active driver. No test-side
changes required — pool-managed and direct sessions look identical
to test code.

## Useful entry points

- `Wallabidi.start_session/1`, `Wallabidi.end_session/1` — public
  entry points; route through pool when configured
- `Wallabidi.Pool` — the generic pool GenServer
- `Wallabidi.Driver.Pool` — the behaviour drivers implement to plug
  in
- `Wallabidi.ChromeDriver.PoolImpl` — the only currently-shipped
  pool impl
- `Wallabidi.Transport.SharedWS`, `Wallabidi.Transport.PerSession`,
  `Wallabidi.Transport.BiDi` — driver-specific transport shapes
