import Config

config :logger, level: :warning

config :wallabidi,
  tmp_dir_prefix: "wallabidi_test",
  otp_app: :wallabidi

# Chrome/chromedriver discovery handled by Wallabidi.BrowserPaths.
# Override with env vars for Docker/CI:
#   WALLABIDI_CHROME_URL=ws://...        (remote CDP connection)
#   WALLABIDI_CHROMEDRIVER_URL=http://... (remote chromedriver)
#   WALLABIDI_CHROME_PATH=/path/to/chrome
#   WALLABIDI_CHROMEDRIVER_PATH=/path/to/chromedriver
#
# For legacy compat, WALLABIDI_CHROMEDRIVER_REMOTE_URL still works:
if remote_url = System.get_env("WALLABIDI_CHROMEDRIVER_REMOTE_URL") do
  config :wallabidi, chromedriver: [remote_url: remote_url]
end

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
