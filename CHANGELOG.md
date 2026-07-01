# Changelog

## Wallabidi 0.4.2 (2026-06-30)

Patch release: race-free `await_patch`, a long-standing sandbox-checkout
bug fix, and broader CI coverage. No public API changes.

### Added

- **Legacy otp_app integration test suite** — `mix test.legacy` exercises
  the `maybe_checkout_repos` fallback path (used when sandbox_case is absent)
  end-to-end, including sandbox propagation to the browser. (#51)

### Fixed

- **`execute_script` + `await_patch` race condition** — `execute_script` now
  snapshots the current page ID before running the script. A subsequent
  `await_patch` uses that snapshot to wait for the correct page-ready event,
  eliminating the race where the page transitioned between the script
  completing and `await_patch` arming. (#47)
- **`repo_started?` always returned false** — the legacy otp_app sandbox path
  used `Ecto.Repo.Registry.lookup/1` with a `{_, _, _}` pattern match;
  `Registry.lookup` returns a map, so every repo was silently treated as not
  started and sandbox checkout was skipped. Fixed with `Process.whereis/1`.
  Thanks to Wígny for the fix. (#51)
- **sandbox_case bumped to 0.4.1** — picks up the async: false ownership
  manager fix. (#50)

## Wallabidi 0.4.1 (2026-06-02)

Patch release: test-suite reliability, a lock-free transport hot path, and
wider CI coverage. No public API changes.

### Added

- **Event-driven-await regression detector** — replaces the wall-clock
  `SlowTestGuard`. Each test now fails if an event-driven await (`visit`,
  `click`, `await_patch`, …) silently falls back to its timeout instead of
  resolving on a browser event (`onPatchEnd` / `MutationObserver` /
  page-ready). This catches a masked regression — where a broken
  event path passes anyway via a lucky retry — that the old wall-clock
  guard couldn't distinguish from infrastructure cost (Chrome cold start,
  runner contention). Opt out a structurally-timing-out test with
  `@tag :expected_await_timeout`; downgrade to a warning with
  `WALLABIDI_AWAIT_MODE=warn`. (#37)
- CI now also tests **Elixir 1.18** (on OTP 27) and tracks the latest
  **1.20 release candidate** (rc.6). `mix.exs` already declared `~> 1.18`;
  this exercises the floor. (#38)

### Changed

- **Lock-free `SharedConnection` reads via `persistent_term`** — the shared
  browser WebSocket pid is read without serialization on the hot path;
  only the one-time connect is serialized. Removes a per-`get/1` GenServer
  round-trip and the race-and-close crash that could occur when closing a
  not-yet-handshaked socket. (#36)
- Chrome startup timeout raised to 30s and concurrent `ws_url` callers are
  parked until the browser is ready, rather than each racing startup. (#34)

### Fixed

- Linting/dialyzer/driver-tag fixes and a Chrome startup-timeout fix that
  were causing intermittent CI failures. (#34)

### Docs

- Corrected Wallaby attribution — Mitchell Hanberg is a maintainer, not the
  creator.
- `guides/setup.md` now states the real version requirement (Elixir 1.18+;
  1.18 on OTP 25–27, 1.19+ on OTP 28), matching the `~> 1.18` constraint.
- Install snippets in the setup/migrating/isolation guides now pin
  `{:wallabidi, "~> 0.4"}` (the 0.4 stable line) instead of the now-stale
  `~> 0.4.0-rc`.

## Wallabidi 0.4.0 (2026-06-01)

First stable 0.4.0 release. Highlights since the 0.3 line (see the rc
entries below for detail):

- **Four drivers with a sensible default ladder** — untagged tests on the
  in-process LiveView driver, `@tag :headless` on Lightpanda, `@tag
  :browser` on Chrome (CDP) — routed in a single `mix test` run, no config
  required. `WALLABIDI_DRIVER` pins a whole run to one driver for CI.
- **Sandbox isolation across every remote driver** — the BEAM sandbox
  owner is propagated via the User-Agent on Chrome CDP, Chrome BiDi, and
  Lightpanda, so `sandbox_case`/`sandbox_shim` DB isolation composes with
  all of them.
- **Browser-aware install** — `mix wallabidi.install` prefers a
  pre-installed Chromium and requires one on arm64 Linux (where Chrome for
  Testing has no build), rather than failing obscurely.
- **LiveView DX** — `visit/2` awaits the LiveSocket connection and warns
  clearly when a page's JS bundle isn't built in the test env (the most
  common "dynamic content never renders" trap).
- **Test isolation requires `sandbox_case ~> 0.4.0`**, which isolates
  FunWithFlags through a persistence adapter (no bytecode patching). See
  the [Test Isolation guide](guides/isolation.md) for the FunWithFlags
  config (sandbox adapter + cache disabled).

### Changed

- Depend on `sandbox_case ~> 0.4.0` (final).

## Wallabidi 0.4.0-rc.11 (2026-06-01)

### Changed

- **Test isolation now requires `sandbox_case ~> 0.4.0-rc`.** sandbox_case
  0.4 isolates FunWithFlags through a custom persistence adapter instead of
  runtime bytecode patching, which changes the FunWithFlags test config.
  If you use `fun_with_flags: true`, point persistence at the sandbox
  adapter in your test env:

  ```elixir
  # config/test.exs
  config :fun_with_flags, :persistence,
    adapter: SandboxCase.Sandbox.FwfAdapter,
    sandbox_real_adapter: FunWithFlags.Store.Persistent.Ecto,
    repo: MyApp.Repo

  config :fun_with_flags, :cache, enabled: false
  ```

  `SandboxCase.Sandbox.setup/1` validates this and raises with guidance if
  it's missing. See the [Test Isolation guide](guides/isolation.md).

### Fixed

- **FunWithFlags isolation could leak across concurrent tests.** The guide
  disabled FWF's cache-bust notifications but not its read cache;
  FunWithFlags keeps a single global ETS cache in front of the store, so
  with it enabled one test's flag value could be served to another from
  that shared cache, bypassing the sandbox. The Test Isolation guide now
  requires `config :fun_with_flags, :cache, enabled: false` in
  `config/test.exs` (which also removes the need for the separate
  `cache_bust_notifications` setting).

### Tests

- Added coverage for self-scheduled post-mount patch chains — a LiveView
  that streams content via a `Process.send_after` chain with no browser
  interaction (the auto-wait must ride past several unsolicited patches).
  Runs on all drivers, including the in-process LiveView driver.

## Wallabidi 0.4.0-rc.10 (2026-05-31)

### Added

- **Detects unbuilt test assets — the #1 confusing LiveView-test failure.**
  When a browser test visits a LiveView page whose JavaScript bundle isn't
  loaded (the generated `mix test` alias builds the DB but not assets, and
  `:dev` masks it because its watchers build live), the LiveView client
  never boots: static mount-rendered content shows, but dynamic updates
  (`stream_insert`, async assigns, `phx-*` events) never appear — and it
  used to surface as a baffling assertion timeout. `visit/2` now awaits the
  LiveView connection on remote drivers (making the documented "`visit/2`
  waits for the LiveSocket to connect" actually true) and logs a one-time
  warning naming the cause and the fix when `window.liveSocket` never
  initializes. False-positive-free (a slow-but-present bundle still defines
  `liveSocket`) and zero added cost on connected/static pages.

### Fixed

- **`Query` `text` filter now works with `visible: :any`.** Validation
  rejected a `text` filter whenever visibility wasn't strictly `true`,
  wrongly tripping on `visible: :any`. Since `:any` still includes visible
  elements (webdriver can read their text), only `visible: false`
  (hidden-only) is incompatible. `visible: :any` is the right tool for
  matching content that may be off-viewport (e.g. stream items in a
  scrollable container). (Inherited from upstream Wallaby.)

### Docs

- **Setup:** new "Build your JS assets for browser tests" note — the
  generated `test` alias doesn't build assets and `:dev` watchers hide it;
  add `assets.build` to the `test` alias.
- **API / Migrating:** define what a *patch* is — any server-driven
  re-render of the mounted LiveView (`onPatchEnd`): an `assign` re-render,
  `handle_info`, `assign_async`, or `push_patch`. **Not** just `push_patch`,
  and not `push_navigate`/`redirect` (navigations) or client-only
  `Phoenix.LiveView.JS` commands.

## Wallabidi 0.4.0-rc.9 (2026-05-31)

### Docs

- **Perf chart now renders on HexDocs.** The README's per-test wall-time
  chart was referenced at `priv/perf-matrix.svg`, which ex_doc never
  copied into the docs output — so it 404'd on hexdocs. Moved to
  `assets/perf-matrix.svg` (resolves on both GitHub and HexDocs) and
  configured ex_doc to copy `assets/` into the generated docs.
- **Corrected the LiveView driver speed** from "~0ms/test" to "~30ms/test"
  — the per-test figure the perf suite actually shows (136 tests in ~4s).
- **Simplified the `--max-cases` guidance.** LiveView, Lightpanda, and CDP
  all run cleanly at ExUnit's default concurrency (CDP merely plateaus
  past mc=4 — no flakes); only Chrome BiDi needs capping (to `8`), as its
  single-threaded Mapper goes flaky at the typical 16-core default. The
  docs no longer prescribe caps the data doesn't justify.

## Wallabidi 0.4.0-rc.8 (2026-05-30)

### Added

- **Sensible per-capability driver defaults — no config required.** A
  single `Wallabidi.driver_for/1` now encodes the ladder: untagged tests
  default to `:live_view` (in-process, fastest), `@tag :headless` to
  `:lightpanda` (falling back to the `:browser` driver when the
  `lightpanda` dep is absent), and `@tag :browser` to `:chrome_cdp`. Each
  `config :wallabidi, driver:/headless:/browser:` key is purely an
  override. This makes the README's "each test runs on the cheapest
  driver that supports it" true out of the box.
- **Multi-driver test runs.** `Wallabidi.start/2` now starts a supervisor
  for the primary driver *plus* each distinct `:headless` / `:browser`
  target that's available, so one `mix test` run can fan tests across
  drivers. The primary is validated (raises if unavailable); tag-routed
  drivers are best-effort, so a LiveView-only project with no Chrome still
  boots and runs its untagged suite.

### Changed

- **`WALLABIDI_DRIVER` / `WALLABIDI_BROWSER` now pin by value for
  consumers.** Previously the pin only worked inside wallabidi's own repo
  (which copies the env var into `config :driver`); in a consumer app
  `WALLABIDI_DRIVER=chrome_cdp mix test` silently ran on the configured
  default. The env var's *value* now selects the driver for both routing
  and supervisor startup, and an unknown name raises. This is what the
  documented per-driver CI matrix relies on (see the Setup guide).
- **Bare `Wallabidi.start_session/1` defaults to `:live_view`** (was
  `:chrome_cdp`), consistent with the untagged-test default. Pass
  `driver:` to choose another.

### Fixed

- **Sandbox metadata propagation on Lightpanda and Chrome BiDi.** Only the
  Chrome CDP driver forwarded the BEAM sandbox owner allowance (encoded in
  the User-Agent) to server-side requests; the Lightpanda and BiDi drivers
  dropped it, so `sandbox_shim` couldn't find the owner and DB-backed
  browser tests crashed with `DBConnection.OwnershipError`. Both drivers
  now set the metadata user-agent override (Lightpanda via
  `Network.setUserAgentOverride`, BiDi via `emulation.setUserAgentOverride`).
  Sandbox isolation now composes with every remote driver.

- **`mix wallabidi.install` on arm64 Linux / with a system browser.**
  Chrome for Testing has no arm64-Linux build, so the install would fail
  trying to download an unavailable binary. The installer now prefers a
  Chrome/Chromium already on PATH (recording it and skipping the download,
  with a log line), and on arm64 Linux without one it raises a clear
  message to install a distro Chromium rather than failing obscurely.
  `npx` is only required when actually downloading Chrome for Testing.

### Docs

- New-user setup gaps closed across the Setup, Test Isolation, and
  Migrating guides: adapter deps that aren't transitive
  (mimic/mox/cachex/fun_with_flags) and the `lightpanda` dep, FunWithFlags
  backend setup, the `Endpoint.url()`-vs-`http:` port trap (and Phoenix
  1.8's `runtime.exs` clobbering the test port), Mox/Mimic/Cachex wiring,
  and a recommendation to pin `driver: :chrome_cdp` when migrating from
  Wallaby. Adds a per-driver CI matrix recipe.

> Test isolation requires `sandbox_case ~> 0.3.12` if you use the
> documented `mimic: true` form — earlier versions crash on it. The
> explicit `mimic: [modules: […]]` form works on any 0.3.x.

## Wallabidi 0.4.0-rc.7 (2026-05-30)

### Fixed

- **`mix wallabidi.install` could grab the wrong Chrome path.** The
  installer parsed `@puppeteer/browsers --format {{path}}` output as the
  last non-empty stdout line, but npm update-notice lines can trail the
  path and got picked up instead — leaving the install with a bogus
  `CHROME=` entry even though Chrome downloaded fine (seen on Docker/CI
  images). The installer now (a) suppresses npm's update notice on the
  npx call (`NPM_CONFIG_UPDATE_NOTIFIER=false`) and (b) scans the output
  for the line that actually resolves to an existing path under
  `.browsers/`, rather than trusting line position.

## Wallabidi 0.4.0-rc.6 (2026-05-30)

### Changed

- **Unified browser install into `.browsers/`.** `mix wallabidi.install`
  now downloads Lightpanda alongside Chrome for Testing, into a
  version-stamped `.browsers/lightpanda/<target>-<release>/` dir that
  mirrors Chrome's `.browsers/chrome/<target>-<version>/` layout. Both
  binary paths are recorded in `.browsers/PATHS` (`CHROME=` and
  `LIGHTPANDA=`), so a single mounted/cached `.browsers/` dir provisions
  every driver. Requires `lightpanda ~> 0.3.1` (the release that adds the
  `:install_dir` knob); on older versions the Lightpanda step is skipped
  with a message and Lightpanda continues to work via its `_build/`
  default.

### Added

- **Browser-scoped install subtasks**: `mix wallabidi.install.chrome` and
  `mix wallabidi.install.lightpanda` install one browser each, merging
  into `.browsers/PATHS` without clobbering the other's entry.
- **`WALLABIDI_LIGHTPANDA_PATH`** env override for the Lightpanda binary,
  symmetric with `WALLABIDI_CHROME_PATH` — point it at an existing binary
  in Docker/CI images.
- **`Wallabidi.BrowserPaths.lightpanda/0`, `lightpanda_path/0`, and
  `lightpanda_install_dir/0`**, mirroring the Chrome resolvers. The
  Lightpanda driver now resolves its binary through `BrowserPaths`
  (env override → `.browsers/PATHS`), making the manifest the runtime
  source of truth as it already is for Chrome.

### Fixed

- **macOS Gatekeeper SIGKILL (exit 137) on freshly-downloaded Lightpanda.**
  The install now strips `com.apple.*` xattrs and re-applies an ad-hoc
  code signature on Darwin so the binary launches non-interactively under
  a BEAM Port. Best-effort and no-op off macOS.

### Dependencies

- `lightpanda` `~> 0.3.0` → `~> 0.3.1`.

## Wallabidi 0.4.0-rc.5 (2026-05-28)

Documentation-only release candidate. No code or API changes.

### Changed

- **README split into focused guides** (665 → 190 lines). Reference
  material moved into `guides/`, wired into ExDoc extras under "Guides"
  and "Internals" groups:
  - `guides/setup.md` — installation, Chrome management, CI, Phoenix config.
  - `guides/isolation.md` — `sandbox_case` / `sandbox_shim` test isolation
    (Ecto, Mimic, Mox, Cachex, FunWithFlags).
  - `guides/api.md` — queries, actions, navigation, finding, forms,
    assertions, optimistic-UI testing, screenshots, dialogs, `settle`,
    `intercept_request`, `on_console`.
  - `guides/migrating.md` — what's different from Wallaby and the
    find-and-replace migration steps.

## Wallabidi 0.4.0-rc.4 (2026-05-26)

* **Fix `mix wallabidi.install` from consumer projects.** Two bugs:

  - `bidi_server_dir` resolved to `File.cwd!() / priv/bidi-server`,
    pointing at the *consumer's* tree instead of wallabidi's. In a
    Hex-dep setup the dir doesn't exist there, so `cd:` into it
    failed silently with the npm subprocess writing `spawn: Could
    not cd to ...` to stdout. Now resolves via
    `Application.app_dir(:wallabidi, "priv/bidi-server")`, with a
    cwd-relative fallback for in-tree development.
  - When `npm install` failed (because of the bug above), the
    surrounding `{_, 0} = System.cmd(...)` raised a confusing
    `MatchError` instead of a clear error. Now surfaces the exit
    status with a useful message.

## Wallabidi 0.4.0-rc.3 (2026-05-25)

### Features

* **`Wallabidi.LiveView` — testing helpers for optimistic-UI and
  in-flight observation.**

  Adds three pieces aimed at LiveView apps where the test needs to
  assert on DOM state *between* a user action and the server's reply
  landing (optimistic UI hooks, multi-phase modals, version
  reconciliation).

  - `set_latency/2`, `clear_latency/1`, `with_latency/3` — wrap
    LiveView's built-in latency simulator
    (`liveSocket.enableLatencySim`) so tests can deterministically
    stretch the round-trip and observe the in-flight phase.
  - `await: :defer` opt on `Wallabidi.Browser.click/3`, `clear/3`,
    `fill_in/3` — fires the action, stashes the wait on the session,
    and returns immediately. Assertions can then run against the
    optimistic DOM.
  - `Wallabidi.LiveView.await_patch/2` — drains the deferred wait
    (uses the stashed pre-click `pageId` for click defers, the
    `__wallabidi_patch_promise` machinery for input defers). Falls
    back to today's arm-and-await when no defer is pending.

  Example:

      session
      |> Wallabidi.LiveView.with_latency(300, fn s ->
        s
        |> click(button("Increment"), await: :defer)
        |> assert_has(css("#count", text: "1"))      # optimistic
        |> Wallabidi.LiveView.await_patch()
        |> assert_has(css("#count", text: "1"))      # reconciled
      end)

  In-process LV driver: `with_latency` and `:defer` are no-ops —
  there's no round-trip to delay or defer.

## Wallabidi 0.4.0-rc.2 (2026-05-24)

* **Fix WebSocket upgrade failure against Chromium 148+ over a
  non-`localhost` hostname.** Chromium 148 tightened DevTools' host
  allowlist: the WS upgrade request must carry `Host: localhost` (or
  an IP literal) or Chrome replies `500 Host header is specified and
  is not an IP address or localhost.`. wallabidi previously sent the
  upgrade with the default Mint behavior — `Host: <uri.host>:<port>` —
  which broke docker-sibling topologies where the WS URL is reached by
  service hostname (e.g. `chrome:9222`). The upgrade now passes an
  explicit `Host: localhost` header, mirroring the `/json/version`
  discovery request that already worked around this.
* When the WS upgrade is rejected with a non-101 status, the client
  now logs the response body and shuts down cleanly instead of
  crashing on `Mint.WebSocket.Frame.binary_to_frames/2` with
  `KeyError :buffer not found in nil`. The original error text from
  the server is now surfaced in the logs.

## Wallabidi 0.4.0-rc.1 (2026-05-24)

* `priv/wallabidi.js` + `priv/wallabidi.min.js` are now included in
  the Hex tarball. They were accidentally excluded in 0.4.0-rc.0
  when the `package.files` list was tightened to keep
  `priv/bidi-server/node_modules` out. The Bootstrap module reads
  them at consumer compile time via `@external_resource`, so without
  them the package fails to compile.

## Wallabidi 0.4.0-rc.0 (2026-05-24)

The Driver decomposition + CDP/BiDi convergence release.

### Behavior

- **BiDi click flow simplified.** The await_patch → await_ack →
  await_page_ready_after cascade has been removed. Both CDP and BiDi
  now use the same single-signal wait on `page_ready`. To handle
  slow-destination-mount scenarios that the cascade compensated for
  with extra wall-clock, the bootstrap now emits a `nav_pending`
  signal whenever LiveView delivers a `live_redirect` or `redirect`
  payload in a `phx_reply`; the transport actor extends its
  `page_ready` deadline to 10s when that signal arrives, so the click
  waits exactly long enough for the destination's first `onPatchEnd`.
  No polling.
- **Cookie `sameSite` is now normalised on both clients.** Pass
  `:sameSite | "sameSite" | :same_site | "same_site"` in any value
  casing; CDP emits PascalCase, BiDi emits lowercase. Previously
  BiDi silently dropped `sameSite`.
- **`Browser.fill_in` no longer double-fires `phx-change` on CDP.**
  The `:silent` clear opt now plumbs through to the wire on both
  drivers. Previously CDP fired an extra empty-state `phx-change`
  between clear and set; BiDi did not.
- **`set_cookie` now surfaces Chrome's `success: false` as
  `{:error, :set_cookie_failed}`** instead of silently succeeding.
- **`hover/tap/touch_down` on BiDi now accept lazy elements**,
  materialising on demand. Matches CDP's existing behavior.
- **`Browser.cookies` on BiDi preserves all wire fields** (e.g.
  `sameSite`, `partition`). Previously the BiDi response parser
  picked a fixed subset and dropped the rest.

### Internal

- **Two-protocol convergence.** CDP and BiDi clients now share file
  layout, section order, function signatures, and doc structure.
  Shared logic lives in `Wallabidi.Remote.OpsShared` (element ops,
  trivia accessors, file-input fallback, element geometry, selected,
  blank_page?), `Wallabidi.Remote.Cookies` (attr lookups + sameSite
  normalisation), and `Wallabidi.Remote.Dialogs.Flow` (protocol-
  agnostic dialog orchestration).
- **`patch_url_fallback?` Spec flag removed.** The `nav_pending`
  signal supersedes the old polling-based fallback. Net result: zero
  polling in the click path on any driver.
- **`log_check_accessors?` Spec flag removed.** Neither driver was
  meaningfully log-checking accessors.

### Stability

- Three BiDi tests tagged `:bidi_unstable` (pre-existing flakes under
  contention; pass solo). Default `mix test.chrome.bidi` is green.

## Wallabidi 0.3.0 (2026-05-10)

A large refactor + perf release. 123 commits since 0.2.14. The headline
changes: V2 driver clients are now the default (V1 modules deleted),
page-side dispatch unified under a `W.run` opcode interpreter,
element handles become lazy by default, and several hot ops fuse into
a single round-trip.

### Breaking

- **V1 → V2 driver promotion.** The transitional `_v2` module names are
  gone: `Wallabidi.Remote.CDP.Client`, `Wallabidi.Remote.BiDi.Client`,
  `Wallabidi.Remote.Lightpanda.Client`. Driver atoms `:chrome_cdp_v2` /
  `:chrome_bidi_v2` / `:lightpanda_v2` continue to work; the legacy
  atoms `:chrome_cdp` / `:chrome_bidi` / `:lightpanda` route to the
  same V2 implementations.
- **Layout move.** Remote driver code lives under `Wallabidi.Remote.*`;
  LiveView driver under `Wallabidi.LiveView.*`. The `Wallabidi.Browser`
  / `Wallabidi.Element` / `Wallabidi.Query` public API is unchanged.
- **Element struct rename.** `bidi_shared_id` → `handle`,
  `parent_shared_id` → `parent_object_id`. Pattern-matching on these
  fields needs to be updated.
- **Server pools removed.** The N-process Chrome/BiDi server-pool work
  shipped in this cycle was rolled back after measurement: per-process
  parallelism inside chromium-bidi's Mapper bottlenecked anyway, and
  the added complexity wasn't worth it. `--max-cases` against a single
  server is the supported model.

### Added

- **`W.run` opcode interpreter** (`priv/wallabidi.js`). Page-side
  dispatch goes through a single function that walks an opcode list,
  threading a target value through ops. Replaces ad-hoc inline JS
  scattered through CDP/BiDi clients.
- **Lazy element handles.** `Element.find/click/text/...` chains
  compile to one `W.run` round-trip instead of resolving the
  reference then issuing follow-up calls. Cuts per-element latency
  visibly on multi-step interactions.
- **Op fusion.** Click, `fill_in`, `set_checked`, `has_value?`,
  `has_text?`, and the await-ready paths each fuse into a single
  fused W.run op with a Promise tail. Drains `phx-update` patches in
  the same round-trip on LiveView pages.
- **Wallaby in the cross-driver perf matrix.** `bench/perf_bench_matrix.sh`
  + `bench/render_perf_matrix.exs` produce `priv/perf-matrix.svg`
  covering Wallaby (chromedriver), Chrome CDP, Chrome BiDi,
  Lightpanda, and the LiveView driver across `--max-cases` 1..16.
- **SlowTestGuard.** Per-test runtime budgets; tests exceeding the
  budget are flagged at the end of the run so polling fallbacks /
  perf regressions don't hide.
- **CDP send/receive timing instrumentation** (opt-in via env var).
- **`Wallabidi.Architecture` ExDoc page** covering the driver /
  transport / pool model.

### Fixed

- **Concurrent navigation races** carried over from 0.2.14 — the
  early-return guard, `stale_reference` plumbing, and bound-realm
  retry continue to apply.
- **LV-driver paths through `Browser.fill_in`, `set_value`,
  `has_text?`, `has_value?`** — the lazy-element routings now correctly
  fall back to the LV driver's element ops rather than always
  resolving via the remote (CDP) client.
- **Page-ready click_aware split** — pre- and post-click timeouts are
  now distinct to prevent 5-second stalls when post-click readiness
  takes longer than pre-click.

### Changed

- **Lightpanda dep → 0.2.10-rc.2**, which defaults its download URL to
  the u2i fork build (`fork-YYYY-MM-DD` tag) carrying the
  WS-cookie-on-upgrade patch needed for Phoenix LiveView channel
  joins.
- **Default `:max_wait_time` test config tightened** from 5000ms to
  3500ms — negative-path tests burn the full budget per missing
  element.
- **`mix.exs` test paths** unified: `mix test.lightpanda_v2` /
  `mix test.chrome_cdp_v2` / `mix test.chrome_bidi_v2` all run from
  `integration_test/cases`.

## Wallabidi 0.2.14 (2026-05-03)

### Fixed

- **Concurrent-navigation flakes across CDP and BiDi.** Three related races
  caused `~1-in-4` BiDi job failures and intermittent `FunctionClauseError`
  crashes on CDP:
  - `await_page_ready_after` could early-return `:ok` when `pre_page_id` was
    captured as `nil` (before the SessionProcess processed its first
    `page_ready` notification) but `last_page_id` had since been set —
    falsely signalling the destination was ready before the click had even
    issued. Now requires non-nil `pre_page_id` for the early-return.
  - `CDPClient.find_elements_ops` returned `%Element{id: nil}` placeholders
    when the secondary fetch (`window.__w.queries[id].elements`) raced a
    concurrent navigation that cleared `__w`. The placeholders crashed
    `attribute/2`. Now surfaces `:stale_reference`; the timeout fallback
    fetches real `objectId`s instead of placeholders.
  - `BiDiClient.execute_script` returned `{:error, ..., "Cannot find context
    with specified id"}` immediately after navigation when chromium-bidi
    hadn't yet bound the new realm. Retries (5× with 50ms backoff) on that
    specific error.
- **`Browser.find/2` retries on `:stale_reference`** within the query
  timeout budget, matching the behaviour of the legacy path.

### Added

- **Page-ready state machine** in the bootstrap (`Initial → AwaitingHook →
  HookInstalled → LVReady` or `→ NonLVReady`) with invalid-transition
  raising on the Elixir side. Maintains a 32-entry ring buffer per session;
  `NavigationTimeoutError` dumps the recent transitions on timeout for
  diagnostic visibility.

## Wallabidi 0.2.7 (2026-04-15)

### Fixed

- **Handle `:unknown` from `Mint.HTTP.stream`** in DevTools discovery.
  The SharedConnection Agent's mailbox can contain unrelated messages
  from earlier test sessions. Now skips non-Mint messages and retries.

## Wallabidi 0.2.6 (2026-04-14)

### Fixed

- **Host header fix for Chrome DevTools discovery** — send `Host: localhost`
  instead of the Docker hostname. Chrome rejects non-localhost Host headers.

## Wallabidi 0.2.5 (2026-04-14)

### Added

- **Auto-discover Chrome WebSocket URL** — `WALLABIDI_CHROME_URL=chrome:9222`
  now works. Wallabidi calls `/json/version`, parses `webSocketDebuggerUrl`,
  and rewrites the host automatically. No more manual `ws://` URL discovery.
  Full `ws://` URLs still work for backward compat.

## Wallabidi 0.2.4 (2026-04-13)

### Fixed

- **Visibility no longer rejects off-viewport elements** — removed
  `rect.bottom < 0` / `rect.right < 0` checks from `displayed`.
  Elements scrolled out of view are "visible" per WebDriver spec.
  Combined with the `scrollIntoView` from 0.2.3, clicks now work
  on elements anywhere in the page regardless of scroll position.
- **`@doc false` on `parse_log` delegates** — suppresses ExDoc warnings.

## Wallabidi 0.2.3 (2026-04-13)

### Fixed

- **scrollIntoView before click** — all click paths now scroll the
  element into view before clicking, matching WebDriver/Selenium
  behavior. Fixes flakes where off-screen elements received no-op clicks.

## Wallabidi 0.2.2 (2026-04-13)

### Fixed

- **CDP click no longer polls** — replaced the tight `retry_find` loop
  (no backoff, ~2ms per eval, hundreds of round-trips) with push-based
  find + single click eval. Eliminates shared WebSocket saturation in
  multi-session tests.

## Wallabidi 0.2.1 (2026-04-13)

### Added

- **`mix wallabidi.install`** — downloads Chrome for Testing + chromedriver
  via `npx @puppeteer/browsers`. Cross-platform, no manual setup.
- **`Wallabidi.BrowserPaths`** — unified browser discovery: env var URL/path
  → `.browsers/PATHS` → system PATH. Supports `WALLABIDI_CHROME_URL` and
  `WALLABIDI_CHROMEDRIVER_URL` for Docker/remote connections.
- **CI documentation** in README with GitHub Actions example.

### Fixed

- CDP bootstrap race on slow CI — `addScriptToEvaluateOnNewDocument` now
  synchronous (was fire-and-forget, causing `window.__w` to be undefined)
- `Inspect` protocol for `Element` — compatible with Elixir 1.18 and 1.19+
- `function_exported?` check uses `Code.ensure_loaded!` for Elixir 1.20-rc
- All credo strict issues resolved
- Dialyzer ignore patterns cleaned (14 patterns, 0 unnecessary skips)
- Removed stale dev `elixirc_paths` hack

### Changed

- CI linting runs in dev env (matching upstream Wallaby pattern)
- Config simplified — removed platform-specific glob patterns in test.exs

## Wallabidi 0.2.0 (2026-04-11)

Significant refactor and performance work since 0.1.43. The default browser
protocol is now CDP (`:chrome_cdp`); BiDi (`:chrome`) remains available as
opt-in via `config :wallabidi, driver: :chrome`.

### Added

- **CDP driver as default** — direct CDP-to-Chrome path is ~1.5x faster
  than BiDi via chromedriver. Use `config :wallabidi, driver: :chrome` to
  opt back into BiDi.
- **Push-based element finding** — bootstrap installs an opcode interpreter
  with MutationObserver and LiveView `onPatchEnd` hook. Find operations
  register an opcode query and block until the bootstrap pushes a match
  notification via `Runtime.addBinding` (CDP) or `script.message` channel
  (BiDi). Zero polling.
- **Push-based page-ready notification** — bootstrap fires a `page_ready`
  channel notification when a new document is parsed and any LiveView has
  finished joining (or non-LV is detected). `do_post_click` waits for this
  notification, eliminating the prior polling-based race in
  `await_liveview_connected`.
- **Pipeline click via `Pipeline.click_full`** — find + classify +
  prepare_patch + click compiled into one JS expression. 1 RPC instead of
  4-6.
- **`Wallabidi.LiveViewDriver`** — server-side LiveView driver, no browser.
  ~60x faster than CDP for LiveView-only test suites.
- **BiDi support** — full WebDriver BiDi protocol implementation with the
  same push model as CDP, using `script.addPreloadScript` channels.
- **`mix test.bench`** — load tests, per-operation benchmarks, and
  diagnostic traces in a separate `bench/` bucket.
- **`TESTING.md`** — guide to the three test buckets and four driver
  backends.

### Changed

- **Test directory restructure** — three buckets:
  `test/` (unit), `integration_test/cases/` (correctness across all
  drivers), `bench/` (load tests + benchmarks). Unified `test_helper.exs`
  starts all driver backends so any test can request any driver.
- **Default `@tag :browser`** — now resolves to `:chrome_cdp` (was
  `:chrome`).
- **`mix test.chrome`** now runs CDP. New `mix test.chrome.bidi` runs the
  BiDi driver.

### Performance

- BiDi click cold-start: ~500ms → ~50ms (eliminated about:blank navigate
  overhead)
- BiDi find: polling retry → 1 RPC fire-and-forget + push notification
- CDP visit + 3 clicks + 4 finds: ~93ms total
- LiveView driver: same workload in ~1.4ms

### Fixed

- `bidi_event` mailbox leak — `end_session` now drains stale events
- Test logs quieted (Logger level `:warning` in test helpers; WebSocket
  `:closed` errors downgraded to debug)
- LiveView driver: `blank_page?/1`, `outerHTML`/`innerHTML` extraction
- CDP `attribute("outerHTML")` now reads the DOM property
- Removed unused `bypass` dep that pinned `ranch` to 1.8 and triggered
  `:simple_one_for_one` deprecation warnings

### Removed

- Selenium driver, `web_driver_client`, `httpoison`, `hackney`
- Legacy per-driver `test_helper.exs` files and `Code.require_file`
  injection (`tests.exs`, `all_test.exs`)

---

# Wallaby (upstream)

## [0.31.0](https://github.com/u2i/wallabidi/compare/v0.30.12...v0.31.0) (2026-07-01)


### Features

* [@tag](https://github.com/tag) :browser system and LiveView integration test suite ([500e8a3](https://github.com/u2i/wallabidi/commit/500e8a3f808c684a2e7847f3ad65af246bdec81f))
* add cast_command to BiDi WebSocketClient ([efe3e82](https://github.com/u2i/wallabidi/commit/efe3e82393f0e420ae6a9ed1adae1fed384feec0))
* add ChromeCDP driver — direct CDP to Chrome, 97% tests passing ([5c5be2e](https://github.com/u2i/wallabidi/commit/5c5be2e07695b47ad6d8468ddc25390c2d8282ec))
* add Lightpanda CDP driver (Phase 1) ([30dd7fe](https://github.com/u2i/wallabidi/commit/30dd7febd47731fe995ca92376c279afdf550913))
* add Lightpanda integration test suite and Phase 2 fixes ([a79ae8b](https://github.com/u2i/wallabidi/commit/a79ae8bc201208e30c673073a2e10ab432305a6e))
* **app:** start every driver a test run can route to, not just one ([fa3c11f](https://github.com/u2i/wallabidi/commit/fa3c11fa8bfa9bd785947583f7339af8bb860dd8))
* auto-discover Chrome WebSocket URL from DevTools endpoint ([7fc8f63](https://github.com/u2i/wallabidi/commit/7fc8f6356c45c26a15dea8f667cc0dea0fbd802e))
* auto-flush infrastructure at driver boundary ([abd7bc3](https://github.com/u2i/wallabidi/commit/abd7bc31d05e22b30f219302b70702ef59e9a368))
* auto-inject onPatchEnd hook — no app.js changes needed ([392f963](https://github.com/u2i/wallabidi/commit/392f963964aa347c41d2a3b4555f12200d699b8b))
* await LiveView connected after navigation ([5ab6f90](https://github.com/u2i/wallabidi/commit/5ab6f90ab76e76d26d15a4cbd431eff385d6fc28))
* await_selector handles XPath text queries ([12bf4e8](https://github.com/u2i/wallabidi/commit/12bf4e8df73ecd29661ea52bfb2f607d1adcbf24))
* await+find pipeline — MutationObserver + find + filter in 1 RPC ([2e9f53c](https://github.com/u2i/wallabidi/commit/2e9f53cf0fa730bbba4cad28c09b41713222bb5b))
* **bench:** opt-in CDP send/receive timing instrumentation ([7257986](https://github.com/u2i/wallabidi/commit/7257986310a1ac52371fecbed17458ce48b92c8b))
* BiDi pipeline find — ops-based find+filter via script.evaluate ([12a48ba](https://github.com/u2i/wallabidi/commit/12a48ba6e81a9dafba00d18022b8ceafd412a8fb))
* BiDi push-based find+click via script.addPreloadScript channel ([803fbd2](https://github.com/u2i/wallabidi/commit/803fbd2daa6c3f32817e326fc62fed8d4f79bc4c))
* **bidi:** N-process chromium-bidi server pool ([006108d](https://github.com/u2i/wallabidi/commit/006108d86458a8bcf4dd24f4d87aafe0c4b98bc3))
* **browser:** execute_script snapshots pageId for race-free await_patch ([5bdcfa7](https://github.com/u2i/wallabidi/commit/5bdcfa7f9c4a5a64bf377797ce36fd04509335a7))
* **browser:** execute_script snapshots pageId for race-free await_patch ([195ca8e](https://github.com/u2i/wallabidi/commit/195ca8e982e025e10d142b63c0f5fb1447bbb946))
* CDP query pipeline — find + filter in one JS evaluation ([8dd53a6](https://github.com/u2i/wallabidi/commit/8dd53a62027d19df6c3e4ee83742f444d72659ba))
* chrome test_helper starts all driver backends ([7f369f2](https://github.com/u2i/wallabidi/commit/7f369f2075597bb1a8d56e431024ea54b8a7cf20))
* ChromeCDP 243/245 tests passing — implement remaining driver features ([4225efb](https://github.com/u2i/wallabidi/commit/4225efbfcc115459eed6736f95ab14f768e32a66))
* **chrome:** N-process Chrome server pool ([95c8cbf](https://github.com/u2i/wallabidi/commit/95c8cbf63bb18b989d2d30790c7395d9e96459ef))
* click_full — classify + prepare_patch + click in 1 RPC ([712338f](https://github.com/u2i/wallabidi/commit/712338fc7babcd7797454c5f051b9f5bfeae0f1b))
* config-based driver selection with [@tag](https://github.com/tag) :browser routing ([2c8bc9e](https://github.com/u2i/wallabidi/commit/2c8bc9e8fd44d9edae7571c90fd770477d0bb6ad))
* deterministic page-ready via loaderId-correlated lifecycle events ([96041bb](https://github.com/u2i/wallabidi/commit/96041bba63e2f8384a65d68b72202ee09a60f042))
* direct LiveView driver — no browser needed ([cb5aa36](https://github.com/u2i/wallabidi/commit/cb5aa3660d600c8f04ddda49bd088d8dab2d96fa))
* **drivers:** make WALLABIDI_DRIVER pin by value; document the CI matrix ([4071629](https://github.com/u2i/wallabidi/commit/40716297f20e835fc7e086d9fdc39d72879b44c7))
* **drivers:** single capability→driver resolver with a sensible default ladder ([727e3b3](https://github.com/u2i/wallabidi/commit/727e3b34772d17b6b6037483cf7a265c963b519e))
* **dx:** detect unbuilt test assets; clarify patch semantics + asset build ([015937d](https://github.com/u2i/wallabidi/commit/015937df447393f5010c468abf1ac8edfb3532a3))
* event-driven assert_has via await_selector ([0c6d2c7](https://github.com/u2i/wallabidi/commit/0c6d2c72d357d4142fc7a83878a22ccbeadcadb2))
* event-driven redirect detection via beforeunload ([cb0ffb6](https://github.com/u2i/wallabidi/commit/cb0ffb6fea2a7222d541b3a8759197be7e36b6f1))
* Feature integrates with sandbox_case when available ([f629c2b](https://github.com/u2i/wallabidi/commit/f629c2bc347404f1d6eff242627a1b6e88c1d80e))
* handle full page navigation with BiDi load event ([f3ec14b](https://github.com/u2i/wallabidi/commit/f3ec14b7224425fc7bb0445fd34b65eef0865ae4))
* **install:** prefer system Chromium; require it on arm64 Linux ([1b58c12](https://github.com/u2i/wallabidi/commit/1b58c12b910542a1099479a1249655b7216ec7e6))
* **install:** unify Lightpanda into .browsers/, add scoped install subtasks ([6aef4d1](https://github.com/u2i/wallabidi/commit/6aef4d119291a22055e46e18d45eae7e6c4ddd27))
* **js:** extend lazy path to fill_in / clear / set_value / send_keys / has_text / assert_text ([54ca81e](https://github.com/u2i/wallabidi/commit/54ca81e5e36f0403e530dc473a2714eb03f24c28))
* **js:** fuse click pipeline into one W.run round-trip ([b26b651](https://github.com/u2i/wallabidi/commit/b26b651ccdadfcba296d51c1b3eeb57cd1f56dbf))
* **js:** fuse fill_in pipeline into one W.run round-trip ([f52f8aa](https://github.com/u2i/wallabidi/commit/f52f8aa1d6efcabba4f9e590cc38f6ab68018fc9))
* **js:** fuse has_value? / has_text? into await-style ops ([51315ba](https://github.com/u2i/wallabidi/commit/51315ba01a7e76a1ec646ecd60b83be060d1381a))
* **js:** fuse set_checked + fix lazy element parent ([b0b9d28](https://github.com/u2i/wallabidi/commit/b0b9d28e08c4391809fe6f51100ad8c3650641e2))
* **js:** lazy element dispatch via target opcode (Phase 1) ([292acba](https://github.com/u2i/wallabidi/commit/292acba8049ec5d3a11e7c5ff15a56eb68240bdf))
* **js:** route find-then-discard Browser APIs through lazy path ([33bbe61](https://github.com/u2i/wallabidi/commit/33bbe617a6223bac5d4214791408de35eca1843d))
* **live_view_driver:** native form submit, cross-LV nav, phx-trigger-action ([6b0d801](https://github.com/u2i/wallabidi/commit/6b0d80110c69396b11b5dda19401a9c1650572e3))
* **live_view:** observe optimistic UI with deferred patch awaits (0.4.0-rc.3) ([c3936c7](https://github.com/u2i/wallabidi/commit/c3936c7d5804235302b23a481993b47f44821d26))
* LiveView driver — 0 failures across all test suites ([e3db08c](https://github.com/u2i/wallabidi/commit/e3db08cfd78a3d236bc98afdaa98ba2b77122909))
* LiveViewDriver handles static page interactions ([398fd43](https://github.com/u2i/wallabidi/commit/398fd43def3938e0d83807385ef7dc9ff79f7509))
* mix test.browsers for multi-browser CI testing ([0d0dc32](https://github.com/u2i/wallabidi/commit/0d0dc32eb0c67b67fc58cada6ac4131cc4f02dba))
* native Elixir query evaluation for LiveViewDriver ([031fa8c](https://github.com/u2i/wallabidi/commit/031fa8c0f13aaa9808fa54cb1962016b97272e8f))
* optional SessionPool for browser session reuse ([45df6ab](https://github.com/u2i/wallabidi/commit/45df6ab2a5708be1bf944466a82446223d9f04d9))
* per-operation timing benchmark across CDP, BiDi, LiveView ([c06fe21](https://github.com/u2i/wallabidi/commit/c06fe21db4235c4cb91ea3ac6561c9a5c48a371f))
* pipeline classify op + revert deferred classification ([f66620d](https://github.com/u2i/wallabidi/commit/f66620d851898b0577f254e35301a783f453507c))
* pipeline click — find + filter + click in 1 RPC ([8de785c](https://github.com/u2i/wallabidi/commit/8de785c337b6003f99ee2536c67b13fbe084a7e6))
* **pool:** Phase 1 session pool — :rebuild strategy on Chrome CDP ([ac1ea04](https://github.com/u2i/wallabidi/commit/ac1ea0423bb16fb212b1d063a2ce9cbc4a414d44))
* protocol abstraction, LiveView-aware visit for CDP, load test infra ([971f738](https://github.com/u2i/wallabidi/commit/971f7382b4f53bc7e33a342d76dec78fa91bb02f))
* push-based element finding via Runtime.addBinding ([87dac2d](https://github.com/u2i/wallabidi/commit/87dac2deab4601a724dd62e5e28891795dc9e9a6))
* replace chromedriver with chromium-bidi standalone server ([6fe32e6](https://github.com/u2i/wallabidi/commit/6fe32e6e77beaed85de255b0d847983dee3fb68c))
* streamline Chrome/chromedriver discovery with BrowserPaths ([23049e2](https://github.com/u2i/wallabidi/commit/23049e2a99979b5b838baf87db5d29bc3dc93f8b))
* **test:** event-driven-await regression detector (replaces SlowTestGuard) ([#37](https://github.com/u2i/wallabidi/issues/37)) ([ee4b6a2](https://github.com/u2i/wallabidi/commit/ee4b6a27ccce4e57d30fc52c885e4c52a141b312))
* **test:** SlowTestGuard with budgeted runtime tags ([67a3b52](https://github.com/u2i/wallabidi/commit/67a3b52c8067d0eee32f0931567d726425422cfd))
* text-aware await_selector ([89fa40d](https://github.com/u2i/wallabidi/commit/89fa40de926f30f2dd09b754cd5e809c145efe2e))
* three-tier test system — liveview / headless / browser ([b4363fe](https://github.com/u2i/wallabidi/commit/b4363fe52e48a5062dc763aaa63a15b470abf2ef))
* **v2:** BiDi click_aware + headless Chrome by default + Protocol routing ([33bfb6e](https://github.com/u2i/wallabidi/commit/33bfb6e0856e02e9f6b4190ef8aab83c984c52d3))
* **v2:** BiDi cookies + execute_script_async + invalid_selector surfacing ([927214f](https://github.com/u2i/wallabidi/commit/927214f5f62005a14765cd284a7e769773cbf577))
* **v2:** BiDi dialogs (alert/confirm/prompt) + unhandledPromptBehavior ([d22cea7](https://github.com/u2i/wallabidi/commit/d22cea7d9416ef952f33d13b0cdeee21c3e6bcbc))
* **v2:** BiDi iframe focus via process-dictionary override ([2f1fac8](https://github.com/u2i/wallabidi/commit/2f1fac82199cbc94e403e09e77649d5245b678ce))
* **v2:** BiDi mouse + touch + element geometry + element-arg in evaluate ([f6f648f](https://github.com/u2i/wallabidi/commit/f6f648f2786d5d65c110aee2df9e344f377a53e2))
* **v2:** BiDi screenshot + viewport sizing ([5d2e7f2](https://github.com/u2i/wallabidi/commit/5d2e7f2de8b3f737a35fe67ae37d6845e417fb23))
* **v2:** BiDi transport phase A — session bring-up + passthrough ([8e7b228](https://github.com/u2i/wallabidi/commit/8e7b2282f53cee660d8885a753e5ab2f2f3d58ae))
* **v2:** BiDi transport phase B — page-load awaits ([51c9347](https://github.com/u2i/wallabidi/commit/51c9347f4c7f053e855f714d733bb63504fae524))
* **v2:** BiDi transport phase C — bootstrap channel routing ([e3e9f4a](https://github.com/u2i/wallabidi/commit/e3e9f4a3086d868ffd9553ff991ed151533420e1))
* **v2:** BiDi window/tab handles + reuse Chrome's default tab ([fce5cd2](https://github.com/u2i/wallabidi/commit/fce5cd269569de2926cf5d5ed2d00a076ebe0036))
* **v2:** BiDiClient — click, set_value, clear, send_keys, page_source ([1fd586d](https://github.com/u2i/wallabidi/commit/1fd586d26137496d83148faaae96fe812104947c))
* **v2:** BiDiClient — navigate, evaluate, find, element ops ([534d4bd](https://github.com/u2i/wallabidi/commit/534d4bd70b013202dfb3c79d56a209b29e9296d6))
* **v2:** CDPClient skeleton + first end-to-end test against Lightpanda ([043df0f](https://github.com/u2i/wallabidi/commit/043df0f8de396ce422e7600cf4e147ca3049902e))
* **v2:** CDPClient.{current_url, current_path, page_title, page_source} ([a98bbf2](https://github.com/u2i/wallabidi/commit/a98bbf20f053f16df670c5076236a6a32458a9f1))
* **v2:** CDPClient.{displayed, click} ([32d3576](https://github.com/u2i/wallabidi/commit/32d35763a889aaa062d07e5b9c56a9e8e4a5a6b6))
* **v2:** CDPClient.{set_value, clear, send_keys} ([eb07ad4](https://github.com/u2i/wallabidi/commit/eb07ad438d46724feb9e85957f5cf39b7c0a33ac))
* **v2:** CDPClient.{text, attribute, call_on_element} ([f6b3d38](https://github.com/u2i/wallabidi/commit/f6b3d38bd1a3967160ca3e6aa4255b42097b1a1c))
* **v2:** CDPClient.classify/3 — read element's LV interaction class ([0a1ce71](https://github.com/u2i/wallabidi/commit/0a1ce7108b61e4b629b8e036e8b07b7600022903))
* **v2:** CDPClient.click_aware/3 — LV-aware click + post-click await ([20eb794](https://github.com/u2i/wallabidi/commit/20eb7944ef6a57256a24651d8973ed88c5dab8c0))
* **v2:** CDPClient.evaluate/2 + V2SessionHelper extraction ([dd0f54d](https://github.com/u2i/wallabidi/commit/dd0f54d00d3e230b8686761d1400d6ec5db619f2))
* **v2:** CDPClient.find_elements/3 — push-based via existing Bootstrap ([8532eec](https://github.com/u2i/wallabidi/commit/8532eecdf97e72590f6041c76f3afe9e2828af67))
* **v2:** CDPClient.navigate/2 ([26393c8](https://github.com/u2i/wallabidi/commit/26393c881cb8c4d26ca6938a2e80784373796419))
* **v2:** CDPClient.visit/2 — navigate + await_page_load combined ([5e4adae](https://github.com/u2i/wallabidi/commit/5e4adae9567c49a49c02548db7b141feac1c8ebb))
* **v2:** cookies, screenshot, window size ([c174d31](https://github.com/u2i/wallabidi/commit/c174d31e5dd0fa5158fec3f25cf72f8d84c33c92))
* **v2:** cross-engine text extraction ([1d7fed9](https://github.com/u2i/wallabidi/commit/1d7fed9b6abd7854068432023b4d21466453af15))
* **v2:** element-scoped find_elements ([f69ad2c](https://github.com/u2i/wallabidi/commit/f69ad2cc086e9f150dbaa7b94d3182621e592822))
* **v2:** event subscribe + Session.await_page_load/4 ([d621bd4](https://github.com/u2i/wallabidi/commit/d621bd4c258ed1a9a0c2317177ef0020c0131e0d))
* **v2:** file inputs + JS error capture + batched subscribes ([13a03e4](https://github.com/u2i/wallabidi/commit/13a03e4f778e7ac52ec3025d92f9da11d1b319bb))
* **v2:** frame switching mechanics — frame_stack + executionContextId routing ([a979319](https://github.com/u2i/wallabidi/commit/a97931919768988c57011d7e512d16ef61a81301))
* **v2:** honor window_size in V2Driver init + persist via JS fallback ([294163b](https://github.com/u2i/wallabidi/commit/294163b6caafede658ae185c13c4a810993a8770))
* **v2:** install bootstrap (window.__w + __wallabidi binding) ([9c78952](https://github.com/u2i/wallabidi/commit/9c78952b50cd5a3664c1d2a32f4f4d4246ebe8fa))
* **v2:** introduce V2.WebSocket + V2.Session transport modules ([f346236](https://github.com/u2i/wallabidi/commit/f3462367c10e861acf4ecae63d00723fe487f786))
* **v2:** JS error capture, file inputs, click_aware on driver, cookie expiry ([e5d55d5](https://github.com/u2i/wallabidi/commit/e5d55d58016edeb58aef827932526d19565432d1))
* **v2:** LV-aware patch+ack orchestration in BiDi click_aware ([1129035](https://github.com/u2i/wallabidi/commit/1129035193a5c012813b8b3a5f1db2521b288683))
* **v2:** NavigationTimeoutError on slow nav clicks ([4624222](https://github.com/u2i/wallabidi/commit/4624222de17b7c8a601b09bf2d902fcd9ea73866))
* **v2:** page-ready tracking — get_page_id + await_page_ready_after ([ee4b52d](https://github.com/u2i/wallabidi/commit/ee4b52d97ccd21f064e85ef74294aa993e453782))
* **v2:** patch-timeout fallback + classification-aware nav errors ([bb58e08](https://github.com/u2i/wallabidi/commit/bb58e08909786147278ca9f7c1f316beaf7aee05))
* **v2:** pre-click LV-ready wait ([0d2ece0](https://github.com/u2i/wallabidi/commit/0d2ece01d67080d3d4f2caaa132de9a9fdefa59d))
* **v2:** real CDP objectIds in find_elements results ([c503b49](https://github.com/u2i/wallabidi/commit/c503b49c87d8e30dd5731dc324102adcfb9f1419))
* **v2:** Session.register_find/3 + await_find_result/3 ([6a0a7ff](https://github.com/u2i/wallabidi/commit/6a0a7ff422ea7cf304b48acbc8218e18c987051e))
* **v2:** SessionStore registration + Feature integration + capabilities passthrough ([faece7c](https://github.com/u2i/wallabidi/commit/faece7cff9d04ca4d21375adad09fdd901fbc7df))
* **v2:** SessionStore registration, scoped find fallback, option clicks ([f71e193](https://github.com/u2i/wallabidi/commit/f71e193421b3715ba326d6816bcf465ab1782e04))
* **v2:** single-actor PerSession transport for Lightpanda ([249b386](https://github.com/u2i/wallabidi/commit/249b3861f57c1353ee40b7e808269b87ad72d698))
* **v2:** translate WebDriver element-arg refs to CDP objectId in evaluate/3 ([925f0b7](https://github.com/u2i/wallabidi/commit/925f0b7b00c84c938ba017cc72177a48c4e4c248))
* **v2:** V2BiDiDriver shell + Browser dispatch + mix alias ([17725fe](https://github.com/u2i/wallabidi/commit/17725fe2e0650a04d28df82d1794f996c2bcadec))
* **v2:** V2ChromeDriver + Browser dispatch to V2 stack ([49a1280](https://github.com/u2i/wallabidi/commit/49a1280054a798465fbe589a173f71886ff56e51))
* **v2:** Wallabidi.V2Driver — full Driver behaviour over V2 stack ([2c36642](https://github.com/u2i/wallabidi/commit/2c36642304c4e67500c0dcac5111efaeafaa3803))
* **v2:** WebDriver-BiDi POST /session handshake helper ([441c9ab](https://github.com/u2i/wallabidi/commit/441c9ab37a6038509cee43c4826f3d8d4370b4b0))
* **v2:** window-switching uses live state, not caller's stale struct ([1999409](https://github.com/u2i/wallabidi/commit/19994093b6888cb544f5ef4c5466bffad03a19cb))
* **v2:** window/frame handles + nav-timeout + iframe context routing ([1db8b4d](https://github.com/u2i/wallabidi/commit/1db8b4d86e02099902f1ff05b5abcb85bfebc622))
* visit waits for LiveSocket connection ([#7](https://github.com/u2i/wallabidi/issues/7)) ([d68f612](https://github.com/u2i/wallabidi/commit/d68f612f99831e859c6c2f8911d1e897eb0ff5e7))
* Wallabidi.Pool — generic browser slot pool, Chrome BiDi migration ([a9ea950](https://github.com/u2i/wallabidi/commit/a9ea9508ba6978c12dcc3c33929d2e295c7dfb23))
* with_patch_await for all interaction types ([7530003](https://github.com/u2i/wallabidi/commit/7530003be00e1410da8462552471982361ff8abb))
* XPath polyfill and unique session IDs for Lightpanda ([c8205bf](https://github.com/u2i/wallabidi/commit/c8205bf8e2614c6e8f22a1246f1367a18d680851))


### Bug Fixes

* add cleanup_stale_sessions noop to Lightpanda, avoid compile warnings ([e4923a7](https://github.com/u2i/wallabidi/commit/e4923a7694a3c98cd3385497f02a06896571a660))
* add CSRF token to test app layout ([6327fd2](https://github.com/u2i/wallabidi/commit/6327fd2652868b6ce4c56c93165a0dd880d1082f))
* add Elixir 1.19 Erlang-format dialyzer ignore patterns ([541e47f](https://github.com/u2i/wallabidi/commit/541e47f44335acce78516b289d29c03081a55d5c))
* add native.ex guard_fail to dialyzer ignore ([1dc2e36](https://github.com/u2i/wallabidi/commit/1dc2e362197403e96dd48bb6d0d9bab7cdf4b761))
* add timeout to await_patch promise ([#4](https://github.com/u2i/wallabidi/issues/4)) ([f5beaa2](https://github.com/u2i/wallabidi/commit/f5beaa227fb222207f4d61d0e3b421c8dd6b64ac))
* align patch-branch page_ready timeout with navigate-branch ([a7269e7](https://github.com/u2i/wallabidi/commit/a7269e73dd32100ef0f17b5994b69f177c665168))
* auto-close sessions via on_exit registration ([73b918d](https://github.com/u2i/wallabidi/commit/73b918dd941fdae6ff55fbe29bbeaca4de6957e1))
* await_liveview_connected resolves on old LiveView ([#4](https://github.com/u2i/wallabidi/issues/4)) ([8114fae](https://github.com/u2i/wallabidi/commit/8114fae7eac2e23a4d1a387247ef4add7eb47226))
* await_liveview_connected uses pre_url to avoid old LV race ([1ba2f98](https://github.com/u2i/wallabidi/commit/1ba2f9818c48694b21bba1a048a0bce5b31ac351))
* await_patch detects navigation and returns early ([#4](https://github.com/u2i/wallabidi/issues/4)) ([f6feebc](https://github.com/u2i/wallabidi/commit/f6feebc36d5d0e32834ae0a4038bc43f9128fd9b))
* await_patch resolves "navigated" and waits for LV connected ([ab978fb](https://github.com/u2i/wallabidi/commit/ab978fb6ba8995e479b645a53ce39960812e1aa6))
* await_selector bails on navigation ([#4](https://github.com/u2i/wallabidi/issues/4)) ([6004c1f](https://github.com/u2i/wallabidi/commit/6004c1fbee0a62a3181dcb0cb041de8efc90ff8d))
* await_selector re-runs on new page after navigation ([#4](https://github.com/u2i/wallabidi/issues/4)) ([60fdf93](https://github.com/u2i/wallabidi/commit/60fdf930b1e73f9de9839f2bb8ef1600e51eb09d))
* await_selector uses querySelectorAll for text matching ([b05e28a](https://github.com/u2i/wallabidi/commit/b05e28a7300d62d93fcba2070a7b4368116b3334))
* beforeunload in prepare_patch catches redirect during click ([aeb3c26](https://github.com/u2i/wallabidi/commit/aeb3c26b1731d336062587258133e761821ca326))
* BiDi bootstrap activation + input[image] classification ([6a417a4](https://github.com/u2i/wallabidi/commit/6a417a4e9c0e6c242006c44b390ca8c3ea1ed873))
* BiDi full-page navigation — subscribe to page_load, drain before click ([5b7c68d](https://github.com/u2i/wallabidi/commit/5b7c68dda73718b01c1a6f7a6946430c9355d42b))
* BiDi ResponseParser.extract_value must unwrap {:ok, map} tuples ([290b98e](https://github.com/u2i/wallabidi/commit/290b98eef1b615aad2484219dd6bd26771fa3991))
* **bidi:** add --no-sandbox + --disable-dev-shm-usage to BiDi Chrome args ([10bb26e](https://github.com/u2i/wallabidi/commit/10bb26e2f089d54320e05d0671fc79d4b855edbb))
* **bidi:** drop session.subscribe timeout 30s → 12s ([d34facd](https://github.com/u2i/wallabidi/commit/d34facdf572d3a5dfeb4c39f4d5a1e8f157915f3))
* **bidi:** library-level retry on session.subscribe timeout ([929cb01](https://github.com/u2i/wallabidi/commit/929cb01806174bbb45d43212b304c0fadbf3b96b))
* **bidi:** raise session.subscribe timeout to 30s for slow runners ([38b9052](https://github.com/u2i/wallabidi/commit/38b9052f717eadf2a043eadd42a676a3db86c149))
* **bidi:** start SessionActor via GenServer.start, retry harder ([71add6e](https://github.com/u2i/wallabidi/commit/71add6ea20891a5a808f7067af7e412625ab9a28))
* **bidi:** tolerate mid-suite chromium-bidi crashes ([f3a1264](https://github.com/u2i/wallabidi/commit/f3a12641058f1d0199758b98fbae17c4ec1737eb))
* **browser:** don't double-wait on Chrome CDP/BiDi click ([64a9d3c](https://github.com/u2i/wallabidi/commit/64a9d3c8737f1dc35f9f45ccee2bb54c707c0df8))
* **browser:** make await_patch actually wait ([dfae35e](https://github.com/u2i/wallabidi/commit/dfae35eabf64ebc54885558cd63bf328fa555b8d))
* **browser:** make await_patch actually wait ([e498714](https://github.com/u2i/wallabidi/commit/e498714959ffedfbe09559a0ece7a17230bd49b0))
* **browser:** retire dead :protocol gate; unstick fill_in drain + with_patch_await ([0d96fc4](https://github.com/u2i/wallabidi/commit/0d96fc4644eac74b6c885f723e4a5a6483a2111f))
* call mark_cleanup_started before closing sessions ([798edea](https://github.com/u2i/wallabidi/commit/798edea4d51d428064dcf1a704ed50fbbfc2a48a))
* cast releaseObject, await page load on patch→navigate transition ([5d908f5](https://github.com/u2i/wallabidi/commit/5d908f563353a61abbc3b11419edacd47835c345))
* CDP client — scoping, send_keys, options, displayed, window size ([6031d8a](https://github.com/u2i/wallabidi/commit/6031d8afa1a740574d555f55e422f71053b6caa6))
* CDP client compatibility — DOM text walker, attribute properties ([8d8f9d9](https://github.com/u2i/wallabidi/commit/8d8f9d9df151e6d886560b4d87b1ff59aad09f7f))
* CDP client send_keys Session guard, window size tracking ([7d733a2](https://github.com/u2i/wallabidi/commit/7d733a230015815cfa22b38935b5733f5be9a375))
* Chrome launch args — missing -- prefix and user-data-dir ([d949cbd](https://github.com/u2i/wallabidi/commit/d949cbdef4b1a49ef6e259b5ef79096869dff215))
* ChromeCDP 245/245 — eliminate parallel race conditions ([564d3cc](https://github.com/u2i/wallabidi/commit/564d3cceaabdcb292010b58e6c48b5ac97dd2aa7))
* CI dialyzer — remove deprecated --halt-exit-status flag, ignore callback_info_missing ([5a634f3](https://github.com/u2i/wallabidi/commit/5a634f368201ab9c2bd5e6a2e9d11821c55e599b))
* CI reduce concurrency, remove browser cache ([7593493](https://github.com/u2i/wallabidi/commit/7593493bf21e7e6fc4e5bbc889e56064fef5fc16))
* **ci:** boot LiveView driver standalone + retry pool open + install lightpanda ([fd9c6c3](https://github.com/u2i/wallabidi/commit/fd9c6c3933a7ec3d7b798783b8cb0ee96b387b8c))
* **ci:** drop stale lightpanda :version pin ([79a36f6](https://github.com/u2i/wallabidi/commit/79a36f646ec1d9c4b951e49671b2ecc89943dcd2))
* **ci:** exclude :browser tests from default mix test ([f55f62c](https://github.com/u2i/wallabidi/commit/f55f62cfb6519ac1628e14c9f471aeba6dbdc4b8))
* **ci:** fix two test failures exposed by the 3-version matrix ([12a6221](https://github.com/u2i/wallabidi/commit/12a6221d5b512165d16b6b811991a229374f6c44))
* **ci:** install Chrome for unit_tests job too ([79400ac](https://github.com/u2i/wallabidi/commit/79400ac1c21b1c77e56e732c7dd2ae740d328684))
* **ci:** lint, driver-tag, dialyzer, and Chrome startup-timeout fixes ([#34](https://github.com/u2i/wallabidi/issues/34)) ([b6cf76e](https://github.com/u2i/wallabidi/commit/b6cf76ee22c9110df44bd58bfde6cb991eb4cdee))
* **ci:** MIX_ENV=test for lightpanda.install + drop single-cond credo nag ([3fa3df0](https://github.com/u2i/wallabidi/commit/3fa3df0625bf46e15d6d7711e44f1f7f48e60c8a))
* **ci:** scope deps cache key to OTP version to prevent rebar beam mismatch ([7fb19d3](https://github.com/u2i/wallabidi/commit/7fb19d3337bb5a634a76d5e7659647ce97f2b342))
* classify phx-trigger-action forms and JS command lists ([007238b](https://github.com/u2i/wallabidi/commit/007238b0f763569a086908e4b71fa56a2be9c8c5))
* classify unknown/failed bindings as :none, not :patch ([#5](https://github.com/u2i/wallabidi/issues/5)) ([795eb73](https://github.com/u2i/wallabidi/commit/795eb73a3fb36f25b169406be750ceeef33d11f8))
* clean up dialyzer, elixirc_paths, CI linting ([aa53963](https://github.com/u2i/wallabidi/commit/aa53963797515e11a1d6414f56dffad93f149ba7))
* **click_aware:** split pre/post-click timeouts to prevent 5s stalls ([c638a6d](https://github.com/u2i/wallabidi/commit/c638a6de0253aacd55265238190b300c028bf6d6))
* compile deps separately from app to avoid dep warnings ([a82d404](https://github.com/u2i/wallabidi/commit/a82d404cd9066963721101a3ef9da6b6b427d2f4))
* compiler warnings, CI lightpanda install, 1.20-rc.4 ([7fbcada](https://github.com/u2i/wallabidi/commit/7fbcada9c3fee08c9e59fe62821c3d015ca646c7))
* DELETE session before closing WebSocket ([2fdd597](https://github.com/u2i/wallabidi/commit/2fdd5971331d35da3846476e5491978adefaa059))
* detect non-LV pages via [data-phx-main] instead of 200ms timeout ([347464c](https://github.com/u2i/wallabidi/commit/347464c83d791e372c47d1815e8cbedcc331e2c5))
* detect redirect after await_patch timeout via URL check ([728b9b3](https://github.com/u2i/wallabidi/commit/728b9b394c1f6fe97892e6ea679025f2a112808b))
* dialyzer ignore for LiveViewDriver guard_fail warnings ([7132b8a](https://github.com/u2i/wallabidi/commit/7132b8ac4b12a46cc60acadd2f7b9188e08ea778))
* dialyzer ignore patterns for Elixir 1.19 warning format ([d93b67d](https://github.com/u2i/wallabidi/commit/d93b67d05c95816da74d13c05faafa8f650bef46))
* dialyzer xpath_polyfill guard, Lightpanda CI concurrency ([ec2fe53](https://github.com/u2i/wallabidi/commit/ec2fe53e4c0701eac7775d2bc26341e5ec6d30c7))
* don't fail on unused dialyzer filters (cross-version compat) ([7672672](https://github.com/u2i/wallabidi/commit/767267249e1f4b166fd2faef03a3ee168eb2ec13))
* don't use link/button selectors as body text search ([#4](https://github.com/u2i/wallabidi/issues/4)) ([c599ef5](https://github.com/u2i/wallabidi/commit/c599ef5cd8f971e5352e10265f74ed4d3e6f6cea))
* drain stale bidi_event messages on session end ([7e3b227](https://github.com/u2i/wallabidi/commit/7e3b227423fbc126456808f272c5a4c8d8aacbe3))
* **drivers:** propagate BEAM sandbox metadata via User-Agent on Lightpanda + BiDi ([497a14c](https://github.com/u2i/wallabidi/commit/497a14c2383a42906ffd063bdb26c0eab07c319c))
* drop binary-presence check from lightpanda driver validate ([#14](https://github.com/u2i/wallabidi/issues/14)) ([3943355](https://github.com/u2i/wallabidi/commit/3943355f54d4bec0c2ff815f8f00fba18f14e0a9))
* eliminate two intermittent CI flakes from concurrent navigation ([#15](https://github.com/u2i/wallabidi/issues/15)) ([3fc9e4c](https://github.com/u2i/wallabidi/commit/3fc9e4c316071d7d19547614a98827815b9d64f0))
* ensure BiDiClient loaded before function_exported? check ([16cc5ab](https://github.com/u2i/wallabidi/commit/16cc5ab0998e8cd0fa67dc204d6bb35b2de6c4aa))
* exclude priv/bidi-server/node_modules from Hex package ([#18](https://github.com/u2i/wallabidi/issues/18)) ([ccc62f3](https://github.com/u2i/wallabidi/commit/ccc62f3b99eb600c2c9909aec6497c244b28b569))
* explicitly end session in on_exit for non-Feature tests ([a0c12f5](https://github.com/u2i/wallabidi/commit/a0c12f5cecebf73fe646fd0a6ded63bda62c4b09))
* explicitly end sessions in on_exit before sandbox checkin ([376339a](https://github.com/u2i/wallabidi/commit/376339aa77a1ec1925c84ce9c4a9151be63858e5))
* fill_in drains all phx-change patches before returning ([#9](https://github.com/u2i/wallabidi/issues/9)) ([3d7e49a](https://github.com/u2i/wallabidi/commit/3d7e49a895b881dd7a78230ba6a08264ea9f706b))
* handle Mint :unknown in DevTools discovery receive loop ([3a04dcf](https://github.com/u2i/wallabidi/commit/3a04dcfbd9743210fec48270811ffc25b8e75404))
* headless=new, Chrome throttling flags, safe classification default ([910ffa7](https://github.com/u2i/wallabidi/commit/910ffa7ad22b6c2f152d4fca5921bf738cab964d))
* Host header must be localhost for Chrome DevTools discovery ([1cdeb92](https://github.com/u2i/wallabidi/commit/1cdeb926dc109a39b10651a20145f304ae2d961b))
* increase lifecycle timeout test margins for CI ([6771e95](https://github.com/u2i/wallabidi/commit/6771e952e26819694bd99a260b92b87bc815c79d))
* increase Lightpanda CDP max connections to 64 ([cc7e75c](https://github.com/u2i/wallabidi/commit/cc7e75cca6b9d2eff878039c59ffe073c89768dd))
* Inspect impl avoids Inspect.Algebra internals entirely ([2ea18cb](https://github.com/u2i/wallabidi/commit/2ea18cb4d8803672ea5bf2716d0351df95ff3aa5))
* Inspect impl uses Algebra.line() for Elixir 1.19 compat ([772451f](https://github.com/u2i/wallabidi/commit/772451fccb3338623db3930b274f209c5057569f))
* Inspect.Algebra compat for Elixir 1.19+, lint env ([5063086](https://github.com/u2i/wallabidi/commit/5063086f768e3fc3eb2c1e1a4f5085c091c27c1d))
* **install:** resolve priv/bidi-server via app_dir + surface npm exit codes (0.4.0-rc.4) ([7ec3876](https://github.com/u2i/wallabidi/commit/7ec38761a0752d4af8f58f8eb0f35ac0abd6d1e3))
* **install:** robustly parse Chrome install path from npx output ([8a9da83](https://github.com/u2i/wallabidi/commit/8a9da838afcdf5ecd3d22c5b87e5a6688808d165))
* **install:** silence Lightpanda undefined-module warnings in :dev/:prod ([ca6e5d3](https://github.com/u2i/wallabidi/commit/ca6e5d3fad99786bb62f5e28064ed6a49eabd238))
* isolate DevTools discovery from Agent mailbox ([48006af](https://github.com/u2i/wallabidi/commit/48006af73d382ac80913497821a9ffd7bde0d843))
* lifecycle timeout test catches both RuntimeError and EXIT ([7b28061](https://github.com/u2i/wallabidi/commit/7b280614860fe24b372022ce6cd0b2dbc8006e22))
* lightpanda 0.2.9 + integration suite + BiDi click race fixes ([4f8a0f6](https://github.com/u2i/wallabidi/commit/4f8a0f6e7c6790abab30a05065c00a96c1ed3d27))
* Lightpanda end_session — close WebSocket, skip closeTarget ([27f13a0](https://github.com/u2i/wallabidi/commit/27f13a04d4b8f94d1e1e36618c1c495f0182a1ff))
* **lightpanda:** route Lightpanda through run_command.sh wrapper for BEAM kill-9 safety ([d6c6052](https://github.com/u2i/wallabidi/commit/d6c6052707eeb03b3cb0cbc18e80c4d4e5352bce))
* limit Lightpanda concurrency on CI, fix arg passthrough ([efb6d48](https://github.com/u2i/wallabidi/commit/efb6d48ad5ca31875646ceba162adef02a8e8262))
* LiveView driver — body extraction, index route, visit_endpoint ([dcf51ce](https://github.com/u2i/wallabidi/commit/dcf51ce78ade70d4e82d10757731a961bab4e41b))
* LiveView driver — current_url, tags, parse_html ([cf9c535](https://github.com/u2i/wallabidi/commit/cf9c53537d854a47a3b3ace5e89a3b86bd89b8b0))
* LiveView driver — decode_xpath ordering, click return, native finder ([2590af6](https://github.com/u2i/wallabidi/commit/2590af6a05cc1ca5c5b333387ea8a78f46bfcdd0))
* LiveView driver — parse_html, text scope, attribute hyphen ([0bde740](https://github.com/u2i/wallabidi/commit/0bde74019461573e679e5a95fea6a093aeff5221))
* LiveView driver — text normalization, radio/checkbox click, selected state ([69e0625](https://github.com/u2i/wallabidi/commit/69e06259de092be6a77d79b805d68967017b7f32))
* LiveView driver blank_page?, outerHTML, tag browser-only tests ([3027d8c](https://github.com/u2i/wallabidi/commit/3027d8c4f18dcf3261d6124d659a16ba5fe2e23f))
* LiveView static pages, SessionStore tests, outerHTML inspect ([8ab6ad9](https://github.com/u2i/wallabidi/commit/8ab6ad984c114e1ea038187ba9f3b44e46070043))
* LiveViewDriver re-reads element HTML and tracks field values ([4518630](https://github.com/u2i/wallabidi/commit/45186303b20d5c58596f02319c465cccbde0b023))
* LV driver path through Browser.fill_in / set_value / has_text / has_value ([2d6ba79](https://github.com/u2i/wallabidi/commit/2d6ba79e5076315bc22accac7a508db38e10efe5))
* monitor LiveView processes instead of fixed sleep ([1c33092](https://github.com/u2i/wallabidi/commit/1c330921f133476c0ede72d33cdd2850793aac1e))
* **package:** include priv/wallabidi.js{,.min.js} in hex tarball ([870b3e3](https://github.com/u2i/wallabidi/commit/870b3e3944e351c33a657b01ad7149901956d022))
* phx-change also checks for push vs JS-only ([d102e14](https://github.com/u2i/wallabidi/commit/d102e14007c92214afe6d4bc6cbf982f2d476a65))
* pipeline scoped queries — preserve this binding in XPath ops ([28c0238](https://github.com/u2i/wallabidi/commit/28c02382b1b57f1e7fc8e87d680708eef42304b7))
* plain form submit classified as :full_page ([#6](https://github.com/u2i/wallabidi/issues/6)) ([c273f9c](https://github.com/u2i/wallabidi/commit/c273f9cf24411cea8430cc2d7957d5da541bcb89))
* polyfill form.reset() for Lightpanda CDP driver ([d3080ae](https://github.com/u2i/wallabidi/commit/d3080aeaac3fea2c7cb12843b70757a4beb4820c))
* push-based find — selected filter, error propagation, race fix ([32187ec](https://github.com/u2i/wallabidi/commit/32187ec338352ba912bac9dfd991f803b9f2efd1))
* push-based page-ready waiter eliminates click flakiness ([2458765](https://github.com/u2i/wallabidi/commit/245876545e4f3a4933b1e08b4c2150eaf1772800))
* **query:** allow text filter with visible: :any ([a5ef146](https://github.com/u2i/wallabidi/commit/a5ef146503406f260f17e7a9635803a8896a76e1))
* raise max_cases to 16, fix Session noproc crash, fix phx-trigger-action and observedPatch races ([cfd9083](https://github.com/u2i/wallabidi/commit/cfd90830c6a69e750e00ddb2bd92b1c0a767137c))
* raise NavigationTimeoutError on silent click-through timeouts ([9caa5c6](https://github.com/u2i/wallabidi/commit/9caa5c606cce5799d48c253426d1082f22db9965))
* relax lifecycle timeout test assertion and add ExUnit timeout ([59c39c6](https://github.com/u2i/wallabidi/commit/59c39c616cc96dd1148a28b37027af968f976782))
* remove linter-injected Runtime.addBinding corruption in pipeline.ex classify JS ([074c597](https://github.com/u2i/wallabidi/commit/074c597a93fc4fd8bab982c61f2b50a3d9cb9de3))
* remove unused form_html variable ([ff64b05](https://github.com/u2i/wallabidi/commit/ff64b050a6626263128fe0e4c153a153276f45c3))
* replace Ecto.Repo.Registry.lookup with Process.whereis ([7277f1c](https://github.com/u2i/wallabidi/commit/7277f1ccfce2263dd636fc62c121b01fd7fc2c46))
* replace polling click with push-based find + single click eval ([50f1310](https://github.com/u2i/wallabidi/commit/50f13107b36ca6a525ec37efbd9331b1fa220d64))
* repo_started? was rejecting all repos ([4059a98](https://github.com/u2i/wallabidi/commit/4059a9866dd0668bfdd74fc8762d50ff05ff4e66))
* resolve all Credo --strict issues ([de986d2](https://github.com/u2i/wallabidi/commit/de986d2457b19cdc063b74983eb455a79a744db3))
* resolve all credo strict issues ([f772088](https://github.com/u2i/wallabidi/commit/f772088274d8c01020c64640f2febd8821096dcc))
* resolve all test and dialyzer failures ([db57512](https://github.com/u2i/wallabidi/commit/db57512b870fe2317c7c419fb24dd8a282a48a69))
* resolve CI failures — Credo nesting, Docker fallback in lifecycle tests ([b795fdd](https://github.com/u2i/wallabidi/commit/b795fdd0ebfc9240133a18163c1792d5a16cbdec))
* resolve_test_driver respects WALLABIDI_DRIVER env ([f54911b](https://github.com/u2i/wallabidi/commit/f54911b6f93a945f6f2a377312e1edf0be1f8823))
* run dialyzer in dev env (dialyxir is dev-only dep) ([466a37f](https://github.com/u2i/wallabidi/commit/466a37f96a0da9cacf4798f39f5cd28fba6d1f56))
* run entire linting job in dev env ([8ed9ab3](https://github.com/u2i/wallabidi/commit/8ed9ab35381e8681ad6a36f68fbb353ed864e3b7))
* runtime check for SandboxCase instead of compile-time ([26a6044](https://github.com/u2i/wallabidi/commit/26a604465f567d7d3cafc57ed64020fe0f18a1a9))
* scrollIntoView before click on all code paths ([a410043](https://github.com/u2i/wallabidi/commit/a4100431147ef807430bb82013d9dbc7c3783b37))
* session pool propagates sandbox metadata on checkout ([#3](https://github.com/u2i/wallabidi/issues/3)) ([fe66fc2](https://github.com/u2i/wallabidi/commit/fe66fc2bb8705ca3d24c14436ee765f4b0e58fda))
* sync bootstrap install in CDP session creation ([be19366](https://github.com/u2i/wallabidi/commit/be193668f9c6f684a9974a822c1505d441cd51e8))
* tag JS-dependent and wait/retry tests as :headless ([1a0de34](https://github.com/u2i/wallabidi/commit/1a0de34f9d7c2d34c3401c9b930495c33fe746f9))
* **tags:** :headless runs on Lightpanda; :browser is Chrome-only ([3c834aa](https://github.com/u2i/wallabidi/commit/3c834aaeef81ef31cb0e7d8902c4e58f6fbb1d0b))
* **test:** exclude :headless tests on Lightpanda ([c070484](https://github.com/u2i/wallabidi/commit/c0704847ff77f1826c18c6033ec84f9e2a7c4cf1))
* **test:** fix LightpandaSmokeTest URL paths and tag genuine LP gaps ([5a10660](https://github.com/u2i/wallabidi/commit/5a1066044ed143cc38a97d55e409c6df58d8ba1e))
* **test:** fix SharedConnection dead-pid test to catch Agent exit ([346882c](https://github.com/u2i/wallabidi/commit/346882c6cf9b604c135797b5d245e9cd7df21cb1))
* **test:** point lightpanda dep at locally-patched binary ([34be4ea](https://github.com/u2i/wallabidi/commit/34be4ea1b36dd410a838cda1ca776cce0e347a38))
* **test:** set reuseaddr on endpoint so mix test.all doesn't hit :eaddrinuse ([83ae4cf](https://github.com/u2i/wallabidi/commit/83ae4cf5f9e069d5c3706f0a3fcf2ef362e3b2ee))
* **test:** stop wallabidi on exit in unit test helper to release port 4321 ([aad7aad](https://github.com/u2i/wallabidi/commit/aad7aada64280be1aefe02ddf07c0464e7ae14c5))
* **test:** stop wallabidi on exit in unit test helper to release port 4321 ([b75a34e](https://github.com/u2i/wallabidi/commit/b75a34ec91fc7ebbdf3f267fd3c46734fa8394ec))
* **test:** tolerate already-stopped endpoint in at_exit / after_suite ([e386502](https://github.com/u2i/wallabidi/commit/e386502475c193f95747b8d3dee849cb2a6be27e))
* **test:** tolerate already-stopped endpoint in at_exit / after_suite ([0451c53](https://github.com/u2i/wallabidi/commit/0451c5357e20bc10d258547adace92b8fadb9d8b))
* **test:** tolerate race between Process.alive? check and Agent.stop in on_exit ([12f2ef3](https://github.com/u2i/wallabidi/commit/12f2ef398181b9d27c93ce38966bb3452d25d5a0))
* trace timing test works for all drivers ([5086936](https://github.com/u2i/wallabidi/commit/5086936003c537d8831e0bfeb7a2e4f50ff293f6))
* **transport:** send Host: localhost on WebSocket upgrades ([ef2d8bd](https://github.com/u2i/wallabidi/commit/ef2d8bd39944e95c58450fc77db25da5e5eb8b7d))
* **types:** correct dialyzer specs for await_find_result + Session.t ([3587c7f](https://github.com/u2i/wallabidi/commit/3587c7f610e2c648287a6271ed96e098c164d127))
* **types:** resolve dialyzer warnings post-refactor ([1c2245a](https://github.com/u2i/wallabidi/commit/1c2245ad5490572444a55a7637ffbd1097efb95a))
* unused variable warning (grab_error → _) ([47b8023](https://github.com/u2i/wallabidi/commit/47b802391914650997155a6971a3fdc9aa5d2e2a))
* update CI for new test structure and browser install ([e84086d](https://github.com/u2i/wallabidi/commit/e84086d54678f2aa439895f491d879c18c70c6d3))
* upgrade dialyxir 1.4.3 → 1.4.7 for OTP 28 compatibility ([6c3b648](https://github.com/u2i/wallabidi/commit/6c3b648429b9c4b26fe7bea7516f3e3b825af8b3))
* use BiDi network interception for pool user-agent override ([#3](https://github.com/u2i/wallabidi/issues/3)) ([2379a4b](https://github.com/u2i/wallabidi/commit/2379a4b1eab4a7808a4d03706e5d3bdb6ffa55c6))
* use exact OTP version for 1.20-rc (strict requires it) ([f7e8837](https://github.com/u2i/wallabidi/commit/f7e88372a1a6feea290a8c524e534c54a53c41c5))
* use file-level credo disable for apply in lightpanda.ex ([ab80f18](https://github.com/u2i/wallabidi/commit/ab80f18814457b405792ea0e15d253a4c52cdac6))
* use LazyHTML.from_document for full HTML pages ([62def29](https://github.com/u2i/wallabidi/commit/62def2988e462f873c34e3a700c21ffbcd14a938))
* **v2_driver:** await LiveView channel-join after visit, parity w/ Chrome ([e3add61](https://github.com/u2i/wallabidi/commit/e3add61608c0cda9c1d2a2df395c580e165ce292))
* **v2:** BiDi find timeout fallback + selected/1 ([c25f9c8](https://github.com/u2i/wallabidi/commit/c25f9c843b7352ef3250aff9f75319106a6a97f8))
* visibility check no longer rejects off-viewport elements ([e8e4895](https://github.com/u2i/wallabidi/commit/e8e4895368f8aea5e26140148d831856a05c1475))
* visit uses wait:interactive and 30s timeout ([#8](https://github.com/u2i/wallabidi/issues/8)) ([08b69a1](https://github.com/u2i/wallabidi/commit/08b69a122a8bcbd8ae23eac5ff67481e9f3070f2))
* wait for liveSocket.main.joinPending before dispatching click ([6e007c3](https://github.com/u2i/wallabidi/commit/6e007c38202e9a32145fef8d1057f6a746c6fbdd))
* wait for LV server ack on patch-classified click timeout ([ad8d0a2](https://github.com/u2i/wallabidi/commit/ad8d0a215f444f74c13b3ce138902543a696b115))
* XPath classification and form redirect handling ([3daafac](https://github.com/u2i/wallabidi/commit/3daafac5e5045b1f133baabcee36b6efb05e0d59))


### Performance Improvements

* **cdp:** batch send_keys + cast focus_window IIFE ([0ef1839](https://github.com/u2i/wallabidi/commit/0ef1839797fb1de6afe641e1e2538e31bf8f42b4))
* **cdp:** pipeline install_bootstrap behind single barrier ([a696ae7](https://github.com/u2i/wallabidi/commit/a696ae737367e6f28d44de05bf9dfe84d1232833))
* eliminate about:blank navigate in BiDi session setup ([37ec11a](https://github.com/u2i/wallabidi/commit/37ec11aa09bf982aff44e686c07ee953ad78869c))
* fire-and-forget domain enables, eliminate 4 blocking round-trips ([e2a5fe5](https://github.com/u2i/wallabidi/commit/e2a5fe581107e500f787c11b0a5ec57b2bb1433a))
* fire-and-forget register_js + inline ops in final_check ([2554cce](https://github.com/u2i/wallabidi/commit/2554ccee16e22bc9db2695c2e19ba40f4e1af687))
* remove --disable-gpu, add anti-throttle features for headless ([296f1c8](https://github.com/u2i/wallabidi/commit/296f1c8b38cc3c7008d8b6ae85e064464a28c1c9))
* skip await_patch for JS-only clicks and non-phx forms ([#4](https://github.com/u2i/wallabidi/issues/4)) ([bac0ba0](https://github.com/u2i/wallabidi/commit/bac0ba0f7b9e148de3e4498159facd10fc032b5d))
* skip xpath polyfill injection on Chrome (native support) ([1603d4f](https://github.com/u2i/wallabidi/commit/1603d4f5b963d0839d0bb0a0987712c429a2a13b))
* **v2:** route V2 click through click_aware (push-based page_ready) ([2e836f2](https://github.com/u2i/wallabidi/commit/2e836f267d8fa3a66d964e4af10365ed4d87f95f))


### Reverts

* remove session pool ([7ec3266](https://github.com/u2i/wallabidi/commit/7ec326699f084208b9055ca041448ae154ac532a))

## [0.30.12](https://github.com/elixir-wallaby/wallaby/compare/v0.30.11...v0.30.12) (2026-01-09)


### Bug Fixes

* flush a DOWN message if one was present ([#832](https://github.com/elixir-wallaby/wallaby/issues/832)) ([63d64de](https://github.com/elixir-wallaby/wallaby/commit/63d64dec492d06f4b609c67bfef41deac161b8a5))

## [0.30.11](https://github.com/elixir-wallaby/wallaby/compare/v0.30.10...v0.30.11) (2025-10-29)


### Bug Fixes

* removed elixir 1.19 warnings ([#823](https://github.com/elixir-wallaby/wallaby/issues/823)) ([f64b943](https://github.com/elixir-wallaby/wallaby/commit/f64b943aca168ddf5869081201a5993384a66d61))

## v0.30.10

- only automatically start sessions for `feature` test macros and not every test in a file by @s3cur3 in https://github.com/elixir-wallaby/wallaby/pull/795

## v0.30.9

- fix unhandled alerts by @s3cur3 in https://github.com/elixir-wallaby/wallaby/pull/779

## v0.30.8

- fix malformed JSON from chromedriver by @s3cur3 in https://github.com/elixir-wallaby/wallaby/pull/778

## v0.30.7

- refactor to map_intersperse by @bradhanks in https://github.com/elixir-wallaby/wallaby/pull/758
- Fix Wallaby.Element.size/1 spec by @NikitaNaumenko in https://github.com/elixir-wallaby/wallaby/pull/759
- Update README to Avoid Elixir Warning by @stratigos in https://github.com/elixir-wallaby/wallaby/pull/762
- Update README: Local Sandbox File Location by @stratigos in https://github.com/elixir-wallaby/wallaby/pull/766
- Update chrome.ex by @RicoTrevisan in https://github.com/elixir-wallaby/wallaby/pull/768
- Make Query.text/2 docs also point to assert_text/{2,3} by @s3cur3 in https://github.com/elixir-wallaby/wallaby/pull/770
- Update README: Separate Phoenix setup from Ecto by @Corkle in https://github.com/elixir-wallaby/wallaby/pull/772
- Address deprecation; prefer ExUnit.Case.register_test/6 by @vanderhoop in https://github.com/elixir-wallaby/wallaby/pull/776
- Fix newer invalid selector error from chromedriver by @mhanberg in 4f82ca82a6c417d298663ac4a996d49e1150d6f2

## v0.30.6

- fix: concurrent tests when using custom capabilities (#744)

## v0.30.5

- Workaround for chromedriver 115 regression (#740)

## v0.30.4

- Set headless and binary chromedriver opts from the `@sessions` attribute in feature tests (#736)

## v0.30.3

- Better support Chromedriver tests on machines with tons of cores

## v0.30.2

- Surface 'text' condition in css query error message (#714)
- Allow 2.0 in httpoison in version constraint (#725)
- Allow setting of optional cookie attributes (#711)

## v0.30.1 (2022-07-16)

### Fixes

- fix(chromedriver): Account for Chromium when doing the version matching (#698)

## v0.30.0 (2022-07-14)

### Breaking

- Now only supports Elixir v1.12 and higher. Please open an issue if this is too restrictive. This was done to allow us to vendor `PartitionSupervisor`, which uses functions that were introduced in v1.12, so vendoring only gets us that far.

### Fixes

- Handle errors related to Wallaby.Element more consistently #632
- Fix `refute_has` when passed a query with an invalid selector #639
- Fix ambiguity between imported Browser.tap/2 and Kernel.tap/2 #686
- Fix `remote_url` config option for selenium driver #582
- Specifying `at` now removes the default `count` of 1 #641
- Various documentation fixes/improvements
- Start a ChromeDriver for every scheduler #692
  - This may fix a long standing issue #365

## v0.29.1 (2021-09-22)

- Docs improvements #629

## v0.29.0 (2021-09-14)

- `has_css?/3` returns a boolean instead of raising. (#624)
- Updates `web_driver_client` to v0.2.0 (#625)

## v0.28.1 (2021-07-31)

- Fix async tests when using selenium and the default capabilities.
- Fixes the DependencyError message in chrome.ex (#581)

## v0.28.0 (2020-12-8)

### Breaking

- `Browser.assert_text/2` and `Browser.assert_text/3` now return the parent instead of `true` when the text was found.

### Fixes

- File uploads when using local and remote selenium servers.

### Improvements

- Added support for touch events
 - `Wallaby.Browser.touch_down/3`
 - `Wallaby.Browser.touch_down/4`
 - `Wallaby.Browser.touch_up/1`
 - `Wallaby.Browser.tap/2`
 - `Wallaby.Browser.touch_move/3`
 - `Wallaby.Browser.touch_scroll/4`
 - `Wallaby.Element.touch_down/3`
 - `Wallaby.Element.touch_scroll/3`

- Added support for getting Element size and location
  - `Wallaby.Element.size/1`
  - `Wallaby.Element.location/1`

## 0.27.0 (2020-12-4)

### Breaking

- Increases minimum Elixir version to 1.8

### Fixes

- Correctly remove stopped sessions from the internal store. [#558](https://github.com/elixir-wallaby/wallaby/pull/558)
- Ensures all sessions are closed after the test suite is over.
- Tests won't crash when side effects fail when calling the inspect protocol on an Element

## 0.26.2 (2020-06-19)

### Fixes

- Improve `Query.t()` specification to fix dialyzer warnings. Fixes [#542](https://github.com/elixir-wallaby/wallaby/issues/542)

## 0.26.1 (2020-06-17)

### Fixes

- Change Wallaby.Browser.sync_result from `@opaque` to `@type` Fixes [#540](https://github.com/elixir-wallaby/wallaby/issues/540)

## 0.26.0 (2020-06-15)

### Remove `Wallaby.Phantom`

The PhantomJS driver was deprecated in v0.25.0 because it is no longer maintained and does not implement many modern browser features.

Users are encouraged to switch to the `Wallaby.Chrome` driver, which is now the default. `Wallaby.Chrome` requires installing `chromedriver` as well as Google Chrome, both of which now come pre-installed on many CI platforms.

## 0.25.1 (2020-06-09)

### Fixes

- Add `ecto_sql` and `phoenix_ecto`

## 0.25.0 (2020-05-27)

### Deprecations

- Deprecated `Wallaby.Phantom`, please switch to `Wallaby.Chrome` or `Wallaby.Selenium`

### Breaking

- `Wallaby.Experimental.Chrome` renamed to `Wallaby.Chrome`.
- `Wallaby.Experimental.Selenium` renamed to `Wallaby.Selenium`.
- `Wallaby.Chrome` is now the default driver.

## 0.24.1 (2020-05-21)

- Compatibility fix for ChromeDriver version >= 83. Fixes [#533](https://github.com/elixir-wallaby/wallaby/issues/533)

## 0.24.0 (2020-04-15)

### Improvements

- Enables the ability to set capabilities by passing them as an option and using application configuration.
- Implements default capabilities for Selenium.
- Implements the `Wallaby.Feature` module.

#### Breaking

- Moves configuration options for using chrome headlessly, the chrome binary, and the chromedriver binary to the `:chromedriver` key in the `:wallaby` application config.
- Automatic screenshots will now only occur inside the `feature` macro.
- Removed `:create_session_fn` option from `Wallaby.Experimental.Selenium`
- Removed `:end_session_fn` option from `Wallaby.Experimental.Selenium`
- Increases the minimum Elixir version to v1.7.
- Increases the minimum Erlang version to v21.

## 0.23.0 (2019-08-14)

### Improvements

- Add ability to configure the path to the ChromeDriver executable
- Enable screenshot support for Selenium driver
- Enable `accept_alert/2`, `dismiss_alert/2`, `accept_confirm/2`, `dismiss_confirm/2`, `accept_prompt/2`, `dismiss_prompt/2` for Selenium driver
- Add `:log` option to `take_screenshot`, this is set to `true` when taking screenshots on failure
- Introduce window/tab switching support: `Browser.window_handle/1`, `Browser.window_handles/1`, `Browser.focus_window/2` and `Browser.close_window/1`
- Introduce window placement support: `Browser.window_position/1`, `Browser.move_window/3` and `Browser.maximize_window/1`
- Introduce frame switching support: `Browser.focus_frame/2`, `Browser.focus_parent_frame/1`, `Browser.focus_default_frame/1`
- Introduce async script support: `Browser.execute_script_async/2`, `Browser.execute_script_async/3`, and `Browser.execute_script_async/4`
- Introduce mouse events support: `Browser.hover/2`, `Browser.move_mouse_by/3`, `Browser.double_click/1`, `Browser.button_down/2`, `Browser.button_up/2`, and a version of `Browser.click/2` that clicks in current mouse position.

### Bugfixes

- LogStore now wraps logs in a list before attempting to pass them to List functions. This was causing Wallaby to crash and would mask actual test errors.

## 0.22.0 (2019-02-26)

### Improvements

- Add `Query.data` to find by data attributes
- Add selected conditions to query
- Add functions for query options
- Add `visible: any` option to query
- Handle Safari and Edge stale reference errors

### Bugfixes

- allow newlines in chrome logs
- Allow other versions of chromedriver
- Increase the session store genserver timeout

## 0.21.0 (2018-11-19)

### Breaking changes

- Removed `accept_dialogs` and `dismiss_dialogs`.

### Improvements

- Improved readability of `file_test` failures
- Allow users to specify the path to the chrome binary
- Add Query.value and Query.attribute
- Adds jitter to all http calls
- Returns better error messages from obscured element responses
- Option to configure default window size
- Pretty printing element html

### Bugfixes

- Chrome takes screenshots correctly if elements are passed to `take_screenshot`.
- Chrome no longer spits out errors constantly.
- Find elements that contain single quotes

## 0.20.0 (2018-04-11)

### Breaking changes

- Normalized all exception names
- Removed `set_window_size/3`

### Bugfixes

- Fixed issues with zombie phantom processes (#338)

## 0.19.2 (2017-10-28)

### Features

- Capture JavaScript logs in chrome
- Queries now take an optional `at:` argument with which you can specify which one of multiple matches you want returned

### Bugfixes

- relax httpoison dependency for easier upgrading and not locking you down
- Prevent failing if phantom jsn't installed globally
- Fix issue with zombie phantomjs processes (#224)
- Fix issue where temporary folders for phantomjs processes aren't deleted

## 0.19.1 (2017-08-13)

### Bugfixes

- Publish new release with an updated version of hex to fix file permissions.

## 0.19.0 (2017-08-08)

### Features

- Handle alerts in chromedriver - thanks @florinpatrascu

### Bugfixes

- Return the correct error message for text queries.

## 0.18.1 (2017-07-19)

### Bugfixes

- Pass correct BEAM Metadata to chromedriver to support db_connection
- Close all sessions when their parent process dies.

## 0.18.0 (2017-07-17)

### Features

- Support for chromedriver

### Bugfixes

- Capture invalid state errors

## 0.17.0 (2017-05-17)

This release removes all methods declared as _deprecated_ in the 0.16 release, experimental Selenium support and much more! If you are looking to upgrade from an earlier release, it is recommended to first go to 0.16.x.
Other goodies include improved test helpers, a cookies API and handling for JS-dialogues.

### Breaking Changes

- Removed deprecated version of `fill_in`
- Removed deprecated `check`
- Removed deprecated `set_window_size`
- Removed deprecated `send_text`
- Removed deprecated versions of `click`
- Removed deprecated `checked?`
- Removed deprecated `get_current_url`
- Removed deprecated versions of `visible?`
- Removed deprecated versions of `all`
- Removed deprecated versions of `attach_file`
- Removed deprecated versions of `clear`
- Removed deprecated `attr`
- Removed deprecated versions of `find`
- Removed deprecated versions of `text`
- Removed deprecated `click_link`
- Removed deprecated `click_button`
- Removed deprecated `choose`

### Features

- New cookie API with `cookies/1` and `set_cookie/3`
- New assert macros `assert_has/2` and `refute_has/2`
- execute_script now returns the session again and is pipable, there is an optional callback if you need access to the return value - thanks @krankin
- Phantom server is now compatible with escripts - thanks @aaronrenner
- Ability to handle JavaScript dialogs via `accept_dialogs/1`, `dismiss_dialogs/1`, plus methods for alerts, confirms and prompts - thanks @padde
- Ability to pass options for driver interaction down to the underlying hackney library through `config :wallaby, hackney_options: [your: "option"]` - thanks @aaronrenner
- Added `check_log` option to `execute_script` - thanks @aaronrenner
- Experimental support for selnium 2 and selenium 3 web drivers has been added, use at your own risk ;)
- Updated hackney and httpoison dependencies - thanks @aaronrenner
- Removed documentation for modules that aren't intended for external use - thanks @aaronrenner
- set_value now works with text fields, checkboxes, radio buttons, and
  options. - thanks @graeme-defty

### Bugfixes

- Fix spawning of phantomjs when project path contains spaces - thanks @schnittchen
- Fixed a couple of dialyzer warnings - thanks @aaronrenner
- Fixed incorrect malformed label warning when it was really a mismatch between expected elements found

## <= 0.16.1

Changelogs for these versions can be found under [releases](https://github.com/keathley/wallaby/releases)
