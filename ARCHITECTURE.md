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

## Browser-server pools

For both Chrome CDP V2 and Chrome BiDi V2 wallabidi can spawn
multiple independent browser-server processes and round-robin
sessions across them. This is the highest-impact perf knob in the
codebase.

### What gets pooled

- **Chrome CDP V2**: N `Wallabidi.Chrome.Server` instances, each
  launching its own headless Chrome on its own random port. Each
  has its own `Wallabidi.WebSocket` cached by `SharedConnection`.
- **Chrome BiDi V2**: N `Wallabidi.Chrome.BidiServer` instances,
  each launching its own chromium-bidi Node process + Chrome.

Sessions are distributed via per-pool atomic counters; the load
balancer is round-robin (no liveness or load awareness — under
uniform test workloads this is close enough to optimal).

### Why this works

A single browser process serializes:

- V8 GC, parser, and isolate scheduling
- Renderer thread per page
- Network thread shared across BrowserContexts
- (BiDi only) the chromium-bidi Node process's own
  session.subscribe queue

Splitting across N processes scales linearly through those
bottlenecks until the BEAM/test-machine itself runs out of CPU or
memory headroom.

### Measured impact on perf_bench (136 tests)

Chrome CDP V2:

| mc | servers=1 | servers=4 | Δ |
|----|-----------|-----------|----|
| 4  | 73s | 72s | −1% (noise) |
| 8  | 63s | **47s** | **−25%** |
| 16 | 61s | **44s** | **−28%** |

Chrome BiDi V2:

| mc | servers=1 | servers=4 | Δ |
|----|-----------|-----------|----|
| 4  | 113s, 2 fails | 103s, 0 fails | −9%, fails eliminated |
| 8  | 95s, 4 fails  | 86s, 4 fails  | −9% |
| 16 | 102s, 6 fails | 106s, 4 fails | flat, fails reduced |

BiDi gains less wallclock because the per-Chrome bottleneck for
BiDi is comparatively smaller — the bigger win there is reliability
under concurrency.

Lightpanda is **not** server-pooled: per-session-WS architecture
means there's no shared-process bottleneck, and LP scales better
under concurrency than Chrome already (272ms/test at mc=8 vs
537ms/test on Chrome CDP).

### Configuration

```sh
# Chrome CDP — opt into N=4 Chrome processes
CHROME_SERVER_COUNT=4 mix test

# Chrome BiDi — opt into N=4 chromium-bidi processes
BIDI_SERVER_COUNT=4 mix test
```

Or via app config:

```elixir
config :wallabidi,
  chrome_server_count: 4,
  bidi_server_count: 4
```

Default for both is `1` — a single server process, identical to the
pre-pool behavior.

### Trade-off

Each additional Chrome process costs ~200–500MB resident memory at
idle (more once Pages exist). Each chromium-bidi Node + Chrome pair
costs similar. Default `count=1` keeps the cost off users who
aren't currently fighting concurrency bottlenecks; `count=4` is
worth turning on once you're running at `mc>=8` and CI has memory
headroom.

### Why no wallabidi-side session pool

An earlier iteration shipped a wallabidi-side session pool
(`Wallabidi.Pool` + `Driver.Pool` behaviour) that pre-warmed N
sessions and round-robined them across tests. It was real (saw a
−22% mc=8 win in isolation) but ended up subsumed by the
browser-server pool.

Stacking both pools wasn't multiplicative — they relieve the
**same** bottleneck (Chrome-process serialization), just at
different points. With `CHROME_SERVER_COUNT=4` the per-Chrome load
is already low enough that pre-warmed sessions buy nothing, and
the session pool's bookkeeping overhead made the combined config
slightly slower than server-pool-only.

The session pool was removed (commits `006108d` and `95c8cbf`
shipped the server pools; commit removing the session pool follows
this doc). Single knob = clearer story.

## Useful entry points

- `Wallabidi.start_session/1`, `Wallabidi.end_session/1` — public
  entry points; both delegate straight to the active driver
- `Wallabidi.Chrome.ServerPool` — N-Chrome supervisor for the
  CDP V2 driver
- `Wallabidi.Chrome.BidiServerPool` — N-chromium-bidi supervisor
  for the BiDi V2 driver
- `Wallabidi.Chrome.SharedConnection` — caches the
  `Wallabidi.WebSocket` pid per Chrome server name; round-robins
  via `ServerPool.next_server/1` when a pool is active
- `Wallabidi.Transport.SharedWS`, `Wallabidi.Transport.PerSession`,
  `Wallabidi.Transport.BiDi` — driver-specific transport shapes
