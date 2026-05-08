# LiveView Smoke Suite — Driver Capability Matrix

The smoke suite (`integration_test/cases/live_view_smoke/`) runs the same
small LV scenarios across every driver to surface capability gaps.

Capability tags excluded per driver:

| driver         | excluded tags                                                    |
|----------------|------------------------------------------------------------------|
| live_view      | `:browser`, `:headless`, `:cross_lv_nav`, `:native_form_submit`, `:cdp_only` |
| chrome_cdp_v2  | `:live_view_only`, `:cdp_only`                                   |
| chrome_bidi_v2 | `:live_view_only`, `:cdp_only`                                   |
| lightpanda_v2  | `:browser` (TODO: re-evaluate), `:lightpanda_ni`, `:cdp_only`    |

## Results

Run with `mix test integration_test/cases/live_view_smoke --max-cases 1`
(date: 2026-05-06).

| Test                                           | live_view | chrome_cdp_v2 | lightpanda_v2 |
|------------------------------------------------|:---------:|:-------------:|:-------------:|
| counter: phx-click increment                   | ✓         | ✓             | ✗             |
| text_change: connected? mount → text           | ✓         | ✓             | ✗             |
| text_change: phx-value param                   | ✓         | ✓             | ✗             |
| async: start_async result lands                | ✓         | ✓             | ✗             |
| async: two-phase sync→async                    | ✓         | ✓             | ✗             |
| form: phx-change echo                          | ✓         | ✓             | ✗             |
| form: phx-submit via type=submit (browser-only)| skip      | ✓             | ✗             |
| multi_element: list, click, append             | ✓         | ✓             | ✗             |
| navigation: <.link navigate> (browser-only)    | skip      | ✓             | ✗             |
| navigation: <a href> cross-live_session        | skip      | ✓             | ✗             |
| slow_event: 3s server work + push_navigate     | skip      | ✓             | ✗             |
| form_redirect: submit + cross-LV redirect      | skip      | ✓             | ✗             |
| trigger_action: phx-trigger-action POST flow   | skip      | ✓             | ✗             |

- **live_view**: 7/7 visible tests pass (6 skipped by capability tag)
- **chrome_cdp_v2**: 13/13 pass
- **lightpanda_v2**: 0/13 pass (every interaction-after-visit test fails)

## LP failure pattern

LP successfully fetches the initial server-rendered HTML and elements
are found. As soon as a test does anything that requires a live LV
WebSocket (a click that triggers `phx-click`, a fill_in that triggers
`phx-change`, even a `connected?` branch in mount), nothing happens
on the server and the post-action assertion times out.

## Phase 5 — root cause

LP **does** run LV's client JS bundle and **does** open the LV
WebSocket. The Phoenix endpoint logs `CONNECTED TO Phoenix.LiveView.Socket`
and the LV client logs `lv:phx-...` channel-join attempts. The join
fails immediately with this LV-client-side log:

    error: unauthorized live_redirect. Falling back to page request

That message is emitted by LV's client for both `unauthorized` and
`stale` server replies. Patching `Phoenix.LiveView.Channel.mount/3`
to dump intermediate state showed:

  * `Session.verify_session` succeeds — the page-rendered session
    token is valid.
  * The next branch checks `connect_info[:session]` (set by
    `Plug.Session` from the cookie on the WS upgrade) and finds
    `nil`. That triggers the "session stale" path which returns
    `{:error, %{reason: "stale"}}` — and LV's client logs it as
    "unauthorized live_redirect" because of the shared branch.

Inspecting `connect_info` directly:

    %{session: nil, user_agent: "Lightpanda/1.0"}

**LP fetches `/counter` and accepts the `Set-Cookie` header (the
cookie is visible in `document.cookie` once `http_only: false` is
configured, but unset under default `HttpOnly: true`). However, on
the subsequent WebSocket upgrade to `/live/websocket`, LP does NOT
include the cookie in the upgrade request.** Phoenix's
`Plug.Session` therefore sees no session, sets `connect_info.session
= nil`, and LV rejects the channel join.

Real browsers (and `curl`) send all matching cookies on a same-origin
WebSocket upgrade regardless of `HttpOnly`. LP doesn't.

## Implications

This is a **LP bug**, not a wallabidi or Phoenix issue. It blocks
every wallabidi test that uses Phoenix LiveView (any `phx-*` event,
any `connected?(socket)` branch). Fixing it requires either:

  * LP upstream patch: carry cookies into WS upgrades (the
    correct fix), or
  * Wallabidi workaround: configure the LP-driver session to
    inject cookies into the WS upgrade headers via the CDP
    `Network.setExtraHTTPHeaders` (but this requires extracting
    the cookies from the page's cookie jar, which CDP exposes via
    `Network.getCookies`).

Until then, `:lightpanda_v2` is excluded from the LV smoke suite
via `:lightpanda_ni` (or by adding LV-driver-specific exclusion).

## Workaround attempts (all failed)

Tested CDP-side cookie injection via wallabidi V2 WebSocket against
both LP `0.2.9` and LP `1.0.0-nightly.6065`:

| Method                                     | LP accepts? | WS upgrade carries cookie? |
|--------------------------------------------|:-----------:|:---------------------------:|
| `Set-Cookie` response header from server   | yes         | **no**                      |
| `Network.setExtraHTTPHeaders` w/ `Cookie`  | yes (`{}`)  | **no**                      |
| `Network.setCookie` (cookie jar)           | yes (`{success: true}`) | **no**          |
| `document.cookie = "..."` via `Runtime.evaluate` | empty string returned | **no**       |

`Network.getAllCookies` returns `UnknownMethod` on both versions.

The WS upgrade path in LP appears to bypass cookies entirely — none
of the four ways a normal browser carries cookies onto a WS upgrade
work in LP. There is no client-side workaround.

## Fix

Patched `src/browser/webapi/net/WebSocket.zig` in lightpanda-io/browser
to call `frame._session.cookie_jar.forRequest(...)` and prepend
`Cookie: ...` to the headers passed to `conn.setHeaders`. About 15
lines of Zig.

Built locally as `1.0.0-dev.1+03ee1f6` and re-ran the regression and
smoke suites:

| Probe                                       | LP 0.2.9 | LP 1.0.0-dev (patched) |
|---------------------------------------------|:--------:|:----------------------:|
| 1) bare nav (Set-Cookie response)           | FAIL     | **PASS**               |
| 2) Network.setExtraHTTPHeaders Cookie       | FAIL     | FAIL (unrelated bug)   |
| 3) Network.setCookie cookie jar             | FAIL     | **PASS**               |
| 4) document.cookie via Runtime.evaluate     | FAIL     | **PASS**               |

LV smoke suite on patched LP: **12/13 pass** (was 0/13). Counter,
async, form, multi_element, text_change, navigation, slow_event,
form_redirect all PASS. Remaining failure: trigger_action — click
on `<button type=submit>` for `phx-trigger-action` form doesn't
fire the native form submit. Separate LP gap (form-submit via
button click), tracked separately from cookie/WS issue.

## Suggested next step

Open upstream LP PR with the WebSocket cookie-jar patch:

  Title: WebSocket upgrade carries cookies from the session jar
  Body: links this MATRIX.md and the regression script in
        `bench/lp_lv_regression.sh`
