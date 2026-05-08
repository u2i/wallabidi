# Suppress debug/info noise during test runs
Logger.configure(level: :warning)

# Unified integration test helper.
#
# Starts all driver backends so any test can create sessions on any driver.
# The primary driver is set via WALLABIDI_DRIVER env var (default: chrome_cdp).
#
# Capability tags (use the sharpest one that applies):
#   :cross_lv_nav       — clicks/links that navigate to a different LiveView
#                          (push_navigate or cross-live_session href). The
#                          in-process LV-driver is scoped to one LV process
#                          at a time, so it can't follow these.
#   :native_form_submit — needs <button type=submit> traversal (LV-driver can't)
#   :headless           — needs a JS-capable headless browser (Chrome / LP)
#   :browser            — needs full real browser (Chrome only — currently)
#                          this is a TODO marker: tests carry it because they
#                          were originally written for Chrome. Each one should
#                          be re-evaluated and downgraded to a sharper tag if
#                          LP can also run it.
#   :lightpanda_ni      — known LP bug or unimplemented feature (temporary;
#                          should track to a fix, not a permanent capability gate)
#   :cdp_only           — driver-internal CDP wire test
#   :live_view_only     — exercises the in-process LV driver itself

# --- Configure primary driver ---
driver =
  case System.get_env("WALLABIDI_DRIVER") do
    "chrome" -> :chrome
    "chrome_bidi_v2" -> :chrome_bidi_v2
    "live_view" -> :live_view
    "lightpanda" -> :lightpanda
    "lightpanda_v2" -> :lightpanda_v2
    "chrome_cdp_v2" -> :chrome_cdp_v2
    _ -> :chrome_cdp
  end

# Mix auto-starts :wallabidi before this helper runs, with whatever
# driver was set via Application.get_env (default :chrome_cdp). Stop
# it so we can swap the driver env and bring up the right supervisor.
Application.stop(:wallabidi)
Application.put_env(:wallabidi, :driver, driver)

# --- Start wallabidi app (primary driver's supervisor) ---
{:ok, _} = Application.ensure_all_started(:wallabidi)

# --- Best-effort start secondary browser backend ---
# CDP and BiDi use different supervisors. Start the one that isn't primary.
secondary =
  case driver do
    :chrome_cdp -> {Wallabidi.Chrome, Wallabidi.Chrome.Supervisor}
    :chrome -> {Wallabidi.ChromeCDP, Wallabidi.ChromeCDP.Supervisor}
    _ -> nil
  end

if secondary do
  {mod, name} = secondary

  try do
    mod.validate()
    mod.start_link(name: name)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end

# --- ExUnit config: exclude tags unsupported by this driver ---
excludes = [pending: true]

# WALLABIDI_AUDIT=1 strips driver-specific excludes and runs every
# non-pending test on whichever driver is selected. Used to discover
# which tests genuinely need which capabilities (we then assign
# tags accordingly). Don't use this in CI — many tests will
# legitimately fail under drivers that lack their needed features.
audit? = System.get_env("WALLABIDI_AUDIT") == "1"

excludes =
  cond do
    audit? ->
      excludes

    driver == :live_view ->
      excludes ++
        [
          browser: true,
          headless: true,
          cross_lv_nav: true,
          native_form_submit: true,
          cdp_only: true
        ]

    # LP has a full JS implementation and a WebSocket client, so it
    # should drive LiveView. We don't exclude :live_view_only here.
    # :browser stays excluded for now because those tests were
    # written for Chrome and haven't been verified against LP — each
    # should be re-evaluated. :lightpanda_ni is a temporary marker
    # for known LP gaps tracked in code comments.
    driver in [:lightpanda, :lightpanda_v2] ->
      excludes ++ [browser: true, lightpanda_ni: true, cdp_only: true]

    driver in [:chrome_cdp_v2, :chrome_bidi_v2, :chrome] ->
      excludes ++ [live_view_only: true, cdp_only: true]

    true ->
      excludes ++ [live_view_only: true]
  end

ex_unit_opts = [exclude: excludes]

# chromium-bidi's session.subscribe handler stalls under high
# concurrency — at default max_cases (System.schedulers_online()
# = typically 16) we see intermittent 10s timeouts. Cap parallelism
# so the BiDi V2 suite is reliable. CDP-based drivers don't have
# this issue (single shared WS).
ex_unit_opts =
  if driver == :chrome_bidi_v2 and is_nil(System.get_env("WALLABIDI_MAX_CASES")) do
    Keyword.put(ex_unit_opts, :max_cases, 8)
  else
    ex_unit_opts
  end

ExUnit.configure(ex_unit_opts)

# SlowTestGuard flags tests that exceed a threshold without an
# explicit @tag :polling. Tests intentionally relying on Wallabidi's
# max_wait_time polling (refute_has, find/not-found, etc.) should
# carry the tag so the guard ignores them — anything else over
# 1500ms is suspicious.
ExUnit.start(
  formatters: [ExUnit.CLIFormatter, Wallabidi.Integration.SlowTestGuard]
)

# --- Start LiveApp endpoint (LiveView integration tests) ---
Application.put_env(:wallabidi, Wallabidi.Integration.LiveApp.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4321],
  server: true,
  check_origin: false,
  secret_key_base: String.duplicate("x", 64),
  live_view: [signing_salt: "integration_test"],
  render_errors: [formats: [html: Wallabidi.Integration.LiveApp.ErrorHTML], layout: false]
)

{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Wallabidi.Integration.PubSub)

{:ok, _} = Wallabidi.Integration.LiveApp.Endpoint.start_link()

# LiveView driver needs an endpoint configured
Application.put_env(:wallabidi, :endpoint, Wallabidi.Integration.LiveApp.Endpoint)

# --- Start static test server (forms.html, page_1.html, etc.) ---
{:ok, server} = Wallabidi.Integration.TestServer.start()
Application.put_env(:wallabidi, :base_url, server.base_url)

Application.put_env(:wallabidi, :live_app_url, "http://localhost:4321")
