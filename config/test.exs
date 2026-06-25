import Config

config :logger, level: :warning

# Lightpanda binary source. The `:lightpanda` hex package downloads the
# u2i fork build (carries the WS-cookie-on-upgrade patch needed for
# Phoenix LiveView channel joins).
#
# We resolve to a concrete `config :lightpanda, :path` here, highest
# priority first:
#   1. WALLABIDI_LIGHTPANDA_PATH env override (Docker/CI), symmetric
#      with WALLABIDI_CHROME_PATH.
#   2. A locally-built sibling checkout (dev) — picked up without
#      re-running an install so rebuilds take effect immediately.
#   3. The `LIGHTPANDA=` line in `.browsers/PATHS`, written by
#      `mix wallabidi.install` (the absolute binary path, exactly like
#      Chrome's `CHROME=` line).
# If none match we set nothing, and the `lightpanda` package falls back
# to its own `_build/` default.
#
# This reads `.browsers/PATHS` as a plain file rather than calling
# Wallabidi.BrowserPaths — config is evaluated before wallabidi's (and
# even the lightpanda dep's) modules are loadable, so no module calls
# are possible here.
lp_from_paths_file =
  case File.read(".browsers/PATHS") do
    {:ok, content} ->
      content
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case String.split(line, "=", parts: 2) do
          ["LIGHTPANDA", path] -> String.trim(path)
          _ -> nil
        end
      end)

    {:error, _} ->
      nil
  end

local_lp = Path.expand("../../lightpanda-browser/zig-out/bin/lightpanda", __DIR__)

cond do
  lp_override = System.get_env("WALLABIDI_LIGHTPANDA_PATH") ->
    config :lightpanda, :path, lp_override

  File.exists?(local_lp) ->
    config :lightpanda, :path, local_lp

  lp_from_paths_file && File.exists?(lp_from_paths_file) ->
    config :lightpanda, :path, lp_from_paths_file

  true ->
    :ok
end

config :wallabidi,
  tmp_dir_prefix: "wallabidi_test",
  otp_app: :wallabidi,
  # Slightly tighter than the default 5000ms — negative-path tests
  # (`assert_raise Wallabidi.QueryError`) burn the full budget per
  # missing element. 3500ms still covers the stale_nodes_test 3s
  # mutation timer with margin.
  max_wait_time: 3_500

# Browser discovery handled by Wallabidi.BrowserPaths.
# Override with env vars for Docker/CI:
#   WALLABIDI_CHROME_URL=ws://...            (remote CDP connection)
#   WALLABIDI_CHROME_PATH=/path/to/chrome
#   WALLABIDI_LIGHTPANDA_PATH=/path/to/lightpanda

# Test app configuration (now merged with Integration LiveApp)
config :wallabidi, Wallabidi.Integration.LiveApp.Repo,
  database: System.get_env("DB_DATABASE") || "wallabidi_test",
  username: System.get_env("DB_USERNAME") || "wallabidi",
  password: System.get_env("DB_PASSWORD") || "wallabidi",
  hostname: System.get_env("DB_HOSTNAME") || "localhost",
  port: String.to_integer(System.get_env("DB_PORT") || "5432"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :wallabidi, Wallabidi.Integration.LiveApp.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4321],
  server: true,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "test_salt"],
  check_origin: false

config :wallabidi, ecto_repos: [Wallabidi.Integration.LiveApp.Repo]

# FunWithFlags: sandbox_case 0.4+ isolates flags via a persistence adapter
# (no bytecode patching). Route persistence through it and disable the
# cache so lookups reach the sandbox-aware store.
config :fun_with_flags, :persistence,
  adapter: SandboxCase.Sandbox.FwfAdapter,
  sandbox_real_adapter: FunWithFlags.Store.Persistent.Ecto,
  repo: Wallabidi.Integration.LiveApp.Repo

config :fun_with_flags, :cache, enabled: false

# Sandbox case — batteries-included test isolation
config :sandbox_case,
  otp_app: :wallabidi,
  mox_mocks: [Wallabidi.Integration.LiveApp.MockWeather],
  sandbox: [
    ecto: true,
    cachex: [:test_app_cache],
    fun_with_flags: true,
    mimic: [
      Wallabidi.Integration.LiveApp.ExternalService,
      Wallabidi.Integration.LiveApp.PriceService
    ],
    logger: [fail_on: false]
  ]
