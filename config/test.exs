import Config

config :logger, level: :warning

# Lightpanda binary source. The `:lightpanda` hex package (>= 0.2.10-rc.2)
# already defaults its download URL to the u2i fork release, which carries
# the WS-cookie-on-upgrade patch needed for Phoenix LiveView channel
# joins. Here we only override `:path` when a locally-built sibling
# checkout exists, so dev rebuilds get picked up automatically.
local_lp = Path.expand("../../lightpanda-browser/zig-out/bin/lightpanda", __DIR__)

if File.exists?(local_lp) do
  config :lightpanda, :path, local_lp
  # Local build reports its own dev version (1.0.0-dev+sha) which won't
  # match the fork-YYYY-MM-DD release tag — suppress the warning.
  config :lightpanda, :version_check, false
end

config :wallabidi,
  tmp_dir_prefix: "wallabidi_test",
  otp_app: :wallabidi,
  # Slightly tighter than the default 5000ms — negative-path tests
  # (`assert_raise Wallabidi.QueryError`) burn the full budget per
  # missing element. 3500ms still covers the stale_nodes_test 3s
  # mutation timer with margin.
  max_wait_time: 3_500

# Chrome discovery handled by Wallabidi.BrowserPaths.
# Override with env vars for Docker/CI:
#   WALLABIDI_CHROME_URL=ws://...        (remote CDP connection)
#   WALLABIDI_CHROME_PATH=/path/to/chrome

# Test app configuration
config :wallabidi, Wallabidi.TestApp.Repo,
  database: "test/support/test_app/test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :wallabidi, Wallabidi.TestApp.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4002],
  server: true,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "test_salt"],
  check_origin: false

config :wallabidi, ecto_repos: [Wallabidi.TestApp.Repo]

# Sandbox case — batteries-included test isolation
config :sandbox_case,
  otp_app: :wallabidi,
  mox_mocks: [Wallabidi.TestApp.MockWeather],
  sandbox: [
    ecto: true,
    cachex: [:test_app_cache],
    fun_with_flags: true,
    mimic: [
      Wallabidi.TestApp.ExternalService,
      Wallabidi.TestApp.PriceService
    ],
    logger: [fail_on: false]
  ]
