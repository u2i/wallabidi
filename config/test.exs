import Config

config :logger, level: :warning

config :wallabidi,
  tmp_dir_prefix: "wallabidi_test",
  otp_app: :wallabidi

if remote_url = System.get_env("WALLABIDI_CHROMEDRIVER_REMOTE_URL") do
  config :wallabidi,
    chromedriver: [
      remote_url: remote_url
    ]
else
  # Use local Chrome for Testing + chromedriver if available
  chrome_binary = Path.wildcard("chrome/*/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing") |> List.first()
  chromedriver = Path.wildcard("chromedriver/*/chromedriver-mac-arm64/chromedriver") |> List.first()

  chromedriver_opts = []
  chromedriver_opts = if chrome_binary, do: Keyword.put(chromedriver_opts, :binary, chrome_binary), else: chromedriver_opts
  chromedriver_opts = if chromedriver, do: Keyword.put(chromedriver_opts, :path, chromedriver), else: chromedriver_opts

  if chromedriver_opts != [] do
    config :wallabidi, chromedriver: chromedriver_opts
  end
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
