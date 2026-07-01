# New-user cold-read audit (docs-only setup)

Method: built a fresh Phoenix 1.8 app (SQLite) under `mise` + `.tool-versions`
(`elixir 1.19.1-otp-28`, `erlang 28.1.1`), then wired wallabidi + sandbox_case +
sandbox_shim using **only** the repo's published docs (README, guides/setup.md,
guides/isolation.md, guides/api.md). Every place I had to guess, add an
undocumented dep, or debug a crash is logged below. Final app: all four sandbox
adapters isolated, cross-process sandbox propagation verified through real Chrome.

Versions resolved: wallabidi 0.4.0-rc.7, sandbox_case 0.3.11, sandbox_shim 0.1.1,
lightpanda 0.3.x, fun_with_flags 1.13, cachex 4.x, mimic 1.12, mox 1.x.

---

## Blocking omissions (a docs-only user cannot get a green browser suite without these)

### 1. Sandbox adapter packages are never listed as consumer deps
`guides/isolation.md` config enables `cachex`, `fun_with_flags`, `mimic`, `mox`,
but never says to add those packages to **your** deps. They're `only: :test` deps
of wallabidi itself, so they do **not** propagate transitively. First symptom is a
runtime `(UndefinedFunctionError) function Mimic.stub/3 is undefined (module Mimic
is not available)` — and `SandboxCase.Sandbox.setup()` does **not** fail early even
though the config references four missing packages, so the gap is silent until a
test touches an adapter.
**Fix:** isolation.md should list `{:mimic, ...}`, `{:mox, ...}`, `{:cachex, ...}`,
`{:fun_with_flags, ...}` as test deps the user must add for the adapters they enable.

### 2. The `lightpanda` package is not a consumer dep — `mix wallabidi.install.lightpanda` silently no-ops
With the documented deps only, `MIX_ENV=test mix wallabidi.install.lightpanda`
prints `Skipping Lightpanda (the lightpanda dep is not available).` and writes no
LIGHTPANDA= line. `setup.md` says "the Lightpanda binary is provided by the
`lightpanda` dependency" but never tells the user to add `{:lightpanda, "~> 0.3",
only: :test}` to **their** mix.exs. So the documented primary path to Lightpanda
produces nothing. After adding the dep, install works perfectly and PATHS gets the
correct version-stamped entry.
**Fix:** setup.md must tell the user to add the `lightpanda` dep (and likewise note
it's required for the Lightpanda driver at all, see #6).

### 3. `mimic: true` crashes sandbox_case 0.3.11
The exact config from isolation.md (`mimic: true`) raises at
`SandboxCase.Sandbox.setup()`:
`(FunctionClauseError) no function clause matching in Code.ensure_compiled/1 …
Mimic.copy({:otp_app, :demo})`. Cause: `normalize_config(true, otp_app)` expands
`true` to `[otp_app: :demo]`, and the Mimic adapter then does
`modules = config[:modules] || config`, falling through to iterate `[otp_app: :demo]`
and calling `Mimic.copy({:otp_app, :demo})`. The documented `true` form is unusable;
the working form is `mimic: [modules: [MyMod]]`.
**Fix:** either fix sandbox_case's Mimic adapter to honour `otp_app` auto-discovery
(or ignore `:otp_app`), or change isolation.md to document `mimic: [modules: […]]`
and drop the "auto-discovers Mimic.copy'd modules" claim (no such auto-discovery
works here).

### 4. `fun_with_flags: true` crashes app boot — FWF is not turnkey
With `fun_with_flags: true` and the package added, the **whole app fails to start**:
`FunWithFlags.Store.Persistent.Redis.worker_spec/0 is undefined` — FWF defaults to a
Redis backend. isolation.md presents `fun_with_flags: true` as a flip-the-switch
option, but the user must first configure a FWF persistence backend (I used the Ecto
backend: `config :fun_with_flags, :persistence, adapter: …Ecto, repo: …` +
`:cache_bust_notifications, enabled: false` + run FWF's migration).
**Fix:** isolation.md should link FWF's own backend-setup requirement and note the
flag is not standalone.

### 5. `base_url` from `Endpoint.url()` points at the wrong port (false-positive trap)
setup.md's Phoenix snippet: `Application.put_env(:wallabidi, :base_url,
YourAppWeb.Endpoint.url())`. In a generated Phoenix app the test endpoint **binds**
on `http: [port: 4002]` but `:url` defaults to **4000**, so `Endpoint.url()` returns
`http://localhost:4000` and every `visit/2` hits a Chrome connection-error page.
Worse: a naive `assert_has(css("body"))` smoke test **passes** against the Chrome
error page (it has a `<body>`), masking the misconfig.
**Fix:** setup.md should tell the user to align `:url` port with the `http:` port
(`url: [host: "localhost", port: 4002]`) and warn that `Endpoint.url()` reflects
`:url`, not the listener.

### 6. Phoenix 1.8 `runtime.exs` clobbers the test port (connection refused)
Compounding #5: `phx.new` 1.8 emits, **outside** the `:prod` block in
`config/runtime.exs`:
`config :app, Endpoint, http: [port: String.to_integer(System.get_env("PORT","4000"))]`.
`runtime.exs` loads **after** `test.exs`, so it resets the listener to 4000 while
`:url` (if you fixed #5) stays 4002 → `:econnrefused` → Chrome error page on every
visit. Required guard: `if config_env() != :test do … end`.
**Fix:** setup.md's Phoenix section should warn that a `server: true` browser-test
setup must ensure `runtime.exs` doesn't override the test `http:` port, and that the
bound port and `base_url` must match.

### 7. Multi-driver tag routing does NOT work out of the box (headline-feature mismatch)
The README's central pitch — *"each test runs on the cheapest driver that supports
it. No env vars, no aliases — just `mix test`"* with mixed `@tag :headless` /
`@tag :browser` / untagged tests — does not hold for a consumer. `Wallabidi.start/2`
starts **exactly one** driver supervisor, chosen from `config :wallabidi, :driver`.
A test routed by tag to a *different* driver then crashes:
`(exit) … GenServer.call(Wallabidi.Remote.Chrome.SharedConnection, …) ** (EXIT) no
process`. The per-tag knobs are separate, **undocumented** config keys
(`config :wallabidi, browser: …, headless: …`), and `@tag :headless` defaults to
`:chrome_cdp` ("Lightpanda is experimental"), not Lightpanda. The viable consumer
model is **one driver per run** (the most capable the suite needs), like wallabidi's
own `WALLABIDI_DRIVER` + `test_paths` aliases — which are not documented for
consumers.
**Fix:** document the real model. Either (a) explain that you run the suite once per
driver and how to select the driver per run, plus the `:browser`/`:headless` config
keys; or (b) make `Wallabidi.start/2` start every driver supervisor the suite's tags
can route to. The current README oversells single-command multi-driver routing.

---

## Limitations / sharp edges (worth a doc note)

### 8. Sandbox propagation fails on the Lightpanda driver (DBConnection.OwnershipError) — FIXED
Cross-process Ecto-sandbox propagation works on Chrome CDP (verified: a row inserted
in the test process is visible to the browser-driven LiveView mount, and a sibling
test sees zero). On **Lightpanda** the same test crashed with
`(DBConnection.OwnershipError) cannot find ownership process …
DemoWeb.WidgetLive.mount/3`. Root cause: Chrome CDP appends the sandbox metadata to
the User-Agent (`Metadata.append` → `Network.setUserAgentOverride`) so
`sandbox_shim`'s plug can find the owner; **the Lightpanda CDP driver never set a
metadata user-agent override**, so server-side requests had no sandbox owner.

**FIXED (2026-05-30) — all remote drivers:**
- `LightpandaCDP.start_session` now mirrors ChromeCDP — when `opts[:metadata]` is
  present it appends it to a `Lightpanda/1.0` base UA and issues
  `Network.setUserAgentOverride` (verified the fork binary honors it). Applied in both
  transport paths via a shared `apply_session_opts/2`.
- `ChromeBiDi.start_session` now does the same via BiDi-native
  `emulation.setUserAgentOverride` (`%{userAgent, contexts: [ctx]}` — verified
  chromium-bidi 15 honors it and the override reaches the server), with the same base
  UA as ChromeCDP.

Regression test: `integration_test/cases/browser/sandbox_metadata_test.exs` (tag
`:sandbox_metadata`) — green on **chrome_cdp, lightpanda, and chrome (BiDi)**;
excluded on live_view (in-process, no real UA). Re-ran the scratch propagation test on
both Lightpanda and BiDi: inserted rows visible to the LiveView mount, sibling sees 0.

sandbox_shim DB isolation now composes with every remote driver (CDP, Lightpanda,
BiDi). The only driver without UA metadata is live_view, which doesn't need it.

### 9. `mix help` can't discover the install task
Because wallabidi is `only: :test`, `mix help` (dev env) does not list
`wallabidi.install*`, and plain `mix wallabidi.install` errors with
`Did you mean "tailwind.install"?`. setup.md *does* explain the `MIX_ENV=test`
requirement (good), but discoverability is poor — a note in the README usage block
would help.

### 10. `cachex: [:my_cache]` requires the user to start the cache, undocumented
isolation.md's `cachex: [:my_cache]` references a named cache the user must add to
their supervision tree (`{Cachex, name: :my_cache}`); the guide never says so. Also,
since `cachex` is `only: :test`, referencing it unconditionally in `application.ex`
breaks dev/prod — the child spec must be env-guarded. Neither point is documented.

### 11. `mox: [Demo.MockWeather]` / Mimic require setup the guide omits
The config lists `mox: [Demo.MockWeather]` and `mimic: true`, but the guide never
shows where `Mox.defmock(Demo.MockWeather, for: Behaviour)` goes, nor (given #3) how
Mimic modules are actually registered. A cold-read user must learn both from the
Mox/Mimic docs. A one-line "define your mocks in test_helper.exs" note would close
this.

### 12. No guidance on the Phoenix-generated sandbox line
`phx.new` puts `Ecto.Adapters.SQL.Sandbox.mode(Demo.Repo, :manual)` in
`test_helper.exs`, and ships `DataCase`/`ConnCase` that check out the sandbox. The
guides never say whether to keep or remove these alongside `SandboxCase.Sandbox.setup()`.
(Empirically they coexist — the generated controller tests stayed green — but the
user is left guessing.)

---

## What worked well (no friction)

- `mix wallabidi.install` / `.chrome` / `.lightpanda` (once the lightpanda dep was
  added) downloaded into the documented version-stamped `.browsers/` layout and wrote
  `.browsers/PATHS` exactly as setup.md describes; macOS Gatekeeper fixup was silent.
- Chrome CDP driver: full suite (12 features + 5 generated tests) green in ~12s,
  including cross-process sandbox propagation through a real browser.
- Ecto / Mox / Cachex / FunWithFlags isolation (once deps + backends were wired) all
  held per-test under `async: true`.
- The core `use Wallabidi.Feature` + `visit/assert_has/Query.css` API matched the
  README/api.md examples exactly.
