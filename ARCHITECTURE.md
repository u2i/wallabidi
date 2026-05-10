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

## Concurrency model

One Chrome process per BEAM. Sessions multiplex over a single
`Wallabidi.WebSocket` via CDP's flat-session-id, with each session
isolated by its own BrowserContext. This is the Playwright-default
shape: amortize browser startup across the BEAM lifetime, throw
away contexts cheaply per test.

For Chrome BiDi the same applies with one chromium-bidi Node
process per BEAM. Lightpanda runs its own one-process-many-WS
model. LiveView uses no browser at all.

### Reliability and concurrency under load

Measured on perf_bench (136 LV scenarios), 3-run averages:

| mc | Chrome CDP | Chrome BiDi | Lightpanda | Wallaby | LiveView |
|---:|---:|---:|---:|---:|---:|
| 1  | 182s | 285s | 155s | 206s | 14s |
| 4  | 70s | 102s, 3 flake | 44s | 66s | 6s |
| 8  | 63s | 95s, 4 flake | 36s | 59s, 15 flake | 4s |
| 16 | 61s | 102s, 12 flake | 35s | 53s, 16 flake | 4s |

Reliability picture at mc=16 across 3 runs:

- **Chrome CDP V2**: 0 flakes
- **Lightpanda V2**: 0 flakes
- **LiveView**: 0 flakes
- **Chrome BiDi V2**: 12 flakes — chromium-bidi's session.subscribe
  serializes under concurrency. Structural; not solvable from the
  wallabidi side.
- **Wallaby (chromedriver)**: 16 flakes — chromedriver's
  session-per-test creation is the bottleneck and intermittent
  timeouts cascade.

For typical test workloads (especially CI runs that share a
machine with non-functional tests), Chrome CDP V2 and Lightpanda
both run flake-free at mc=16 with the default supervised single
browser process. No tuning required.

### Speed picking guide

- **LiveView** — 10-50× faster than any browser driver. Use where
  the test doesn't need a real DOM (most LiveView assertions).
- **Lightpanda V2** — fastest browser driver. ~25% ahead of
  Chrome CDP at every mc level. Reliable.
- **Chrome CDP V2** — solid default for tests that need real Chrome
  semantics.
- **Chrome BiDi V2** — slowest browser driver and the only one
  with structural reliability issues. Available for tests that
  specifically exercise the WebDriver BiDi protocol.

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

- `Wallabidi.start_session/1`, `Wallabidi.end_session/1` — public
  entry points; both delegate straight to the active driver
- `Wallabidi.Chrome.SharedConnection` — caches the
  `Wallabidi.WebSocket` pid for the supervised Chrome process
- `Wallabidi.Chrome.Server` / `Wallabidi.Chrome.BidiServer` —
  the supervised browser server processes
- `Wallabidi.Transport.SharedWS`, `Wallabidi.Transport.PerSession`,
  `Wallabidi.Transport.BiDi` — driver-specific transport shapes
