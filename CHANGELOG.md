# Changelog

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
