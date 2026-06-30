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
#   :headless           — needs a real headless browser (Lightpanda or Chrome);
#                          excludes the in-process LV driver
#   :browser            — needs Chrome specifically (screenshots, CDP network
#                          throttle, layout metrics, XPath, localStorage)
#   :lightpanda_only    — tests a Lightpanda-specific behaviour or quirk;
#                          only runs on the :lightpanda driver
#   :chrome_only        — tests a Chrome-specific behaviour or quirk;
#                          only runs on the :chrome / :chrome_cdp drivers
#   :lightpanda_ni      — known LP bug or unimplemented feature (temporary;
#                          should track to a fix, not a permanent capability gate)
#   :cdp_only           — driver-internal CDP wire test (unit-level, not LP/Chrome)
#   :live_view_only     — exercises the in-process LV driver itself

# --- Configure primary driver ---
driver =
  case System.get_env("WALLABIDI_DRIVER") do
    "chrome" -> :chrome
    "live_view" -> :live_view
    "lightpanda" -> :lightpanda
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
      # The LV-driver now supports native form submit (render_submit on
      # button[type=submit] inside phx-submit forms) and cross-LV
      # navigation (visits the destination after push_navigate /
      # redirect / cross-live_session <a href>). With those in place
      # the only thing we exclude is the genuinely browser-only set.
      excludes ++
        [
          browser: true,
          headless: true,
          cdp_only: true,
          lightpanda_only: true,
          chrome_only: true,
          # In-process LV driver makes no real HTTP request, so it carries
          # no User-Agent — the sandbox-metadata-in-UA test is N/A here.
          sandbox_metadata: true
        ]

    # LP has a full JS implementation and a WebSocket client and runs
    # LiveView fine via the smoke suite (live_view_smoke/). The legacy
    # cases/live_view/feature_test.exs is :live_view_only because it
    # exercises the in-process LV-driver's Feature dispatch — not a
    # generic LV scenario. Keep :live_view_only excluded on LP.
    driver == :lightpanda ->
      excludes ++
        [
          browser: true,
          lightpanda_ni: true,
          live_view_only: true,
          cdp_only: true,
          chrome_only: true
        ]

    # Chrome BiDi has known stability issues on GHA Linux runners
    # (chromium-bidi Mapper subscribe stalls + cascading session crashes
    # under contention). Tests tagged :bidi_unstable are skipped on BiDi
    # only; they still run on Chrome CDP for coverage.
    driver == :chrome ->
      excludes ++
        [live_view_only: true, cdp_only: true, bidi_unstable: true, lightpanda_only: true]

    driver == :chrome_cdp ->
      excludes ++ [live_view_only: true, cdp_only: true, lightpanda_only: true]

    true ->
      excludes ++ [live_view_only: true, cdp_only: true, lightpanda_only: true]
  end

ex_unit_opts = [exclude: excludes]

# Cap per-driver parallelism when WALLABIDI_MAX_CASES is not set.
#
# chromium-bidi's session.subscribe handler stalls under high
# concurrency — cap at 8 for reliable BiDi V2 runs.
#
# Chrome CDP and Lightpanda: default max_cases (System.schedulers_online()
# = typically 36) overwhelms Chrome with too many concurrent targets /
# Lightpanda with too many simultaneous WS connects. 16 is the observed
# safe ceiling locally.
ex_unit_opts =
  cond do
    driver == :chrome and is_nil(System.get_env("WALLABIDI_MAX_CASES")) ->
      Keyword.put(ex_unit_opts, :max_cases, 8)

    driver in [:chrome_cdp, :chrome, :lightpanda] and
        is_nil(System.get_env("WALLABIDI_MAX_CASES")) ->
      Keyword.put(ex_unit_opts, :max_cases, 16)

    true ->
      ex_unit_opts
  end

ExUnit.configure(ex_unit_opts)

# AwaitMonitor detects event-driven-await regressions directly: if an
# interaction wallabidi classified as patch/navigate silently falls back
# to its timeout (the event mechanism broke), the test is failed in
# Wallabidi.Feature's on_exit — regardless of wall-clock time. This
# replaces the old wall-clock SlowTestGuard, whose per-test budget was
# polluted by one-time costs (Chrome cold start, connection acquisition)
# and runner load, producing flaky failures unrelated to event-driven-ness.
#
# WALLABIDI_AWAIT_MODE=warn records + reports without failing (validation).
Wallabidi.Test.AwaitMonitor.setup()

ExUnit.start(formatters: [ExUnit.CLIFormatter])
Testcontainers.start_link()

# --- Start PostgreSQL container ---
{:ok, pg_container} =
  Testcontainers.start_container(
    Testcontainers.PostgresContainer.new()
    |> Testcontainers.PostgresContainer.with_image("postgres:18-alpine")
    |> Testcontainers.PostgresContainer.with_user("wallabidi")
    |> Testcontainers.PostgresContainer.with_password("wallabidi")
    |> Testcontainers.PostgresContainer.with_database("wallabidi_test")
  )

# Apply container config to the repo (overrides config/test.exs)
Application.put_env(
  :wallabidi,
  Wallabidi.Integration.LiveApp.Repo,
  Testcontainers.PostgresContainer.connection_parameters(pg_container) ++
    [pool: Ecto.Adapters.SQL.Sandbox, pool_size: 10]
)

# --- Start Repo, run migrations, start Cachex, setup sandboxes (integration tests) ---
# Mox.defmock must be called before SandboxCase.Sandbox.setup()
Mox.defmock(Wallabidi.Integration.LiveApp.MockWeather,
  for: Wallabidi.Integration.LiveApp.WeatherBehaviour
)

Application.put_env(:wallabidi, :weather_module, Wallabidi.Integration.LiveApp.MockWeather)

{:ok, _} = Wallabidi.Integration.LiveApp.Repo.start_link()
Ecto.Migrator.up(Wallabidi.Integration.LiveApp.Repo, 1, Wallabidi.Integration.LiveApp.Migration)
{:ok, _} = Cachex.start_link(:test_app_cache)
SandboxCase.Sandbox.setup()

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

Application.put_env(:wallabidi, :base_url, "http://localhost:4321")

Application.put_env(:wallabidi, :live_app_url, "http://localhost:4321")

System.at_exit(fn _ ->
  # Stop the wallabidi app so supervisors don't restart browser children
  # during BEAM shutdown. The run_command.sh wrapper kills browser OS
  # processes when their stdin pipe closes (which happens as part of
  # normal shutdown and on BEAM kill -9).
  Application.stop(:wallabidi)
end)
