import Config

config :wallabidi,
  tmp_dir_prefix: "wallabidi_test",
  otp_app: :wallabidi,
  sandbox: true

if remote_url = System.get_env("WALLABIDI_CHROMEDRIVER_REMOTE_URL") do
  config :wallabidi,
    chromedriver: [
      remote_url: remote_url
    ]
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

config :wallabidi, :sandbox, Ecto.Adapters.SQL.Sandbox

config :wallabidi, ecto_repos: [Wallabidi.TestApp.Repo]
