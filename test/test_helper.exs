# Unit tests run without a real browser; :browser-tagged tests live in
# integration_test/ and run via the per-driver test.* aliases. Excluding
# :browser keeps BiDi/CDP end-to-end tests from being pulled in by the
# default `mix test` command.
ExUnit.configure(exclude: [pending: true, browser: true])
EventEmitter.start_link([])

# --- Start PostgreSQL container (testcontainers) ---
Testcontainers.start_link()

{:ok, pg_container} =
  Testcontainers.start_container(
    Testcontainers.PostgresContainer.new()
    |> Testcontainers.PostgresContainer.with_image("postgres:18-alpine")
    |> Testcontainers.PostgresContainer.with_user("wallabidi")
    |> Testcontainers.PostgresContainer.with_password("wallabidi")
    |> Testcontainers.PostgresContainer.with_database("wallabidi_test")
  )

# Apply container config to the repo (overrides config/test.exs)
Application.put_env(:wallabidi, Wallabidi.Integration.LiveApp.Repo,
  Testcontainers.PostgresContainer.connection_parameters(pg_container) ++
    [pool: Ecto.Adapters.SQL.Sandbox, pool_size: 10]
)

# --- Start Repo, run migrations, start endpoint, start Cachex ---
{:ok, _} = Wallabidi.Integration.LiveApp.Repo.start_link()
Ecto.Migrator.up(Wallabidi.Integration.LiveApp.Repo, 1, Wallabidi.Integration.LiveApp.Migration)
{:ok, _} = Wallabidi.Integration.LiveApp.Endpoint.start_link()
{:ok, _} = Cachex.start_link(:test_app_cache)

# Set base_url
Application.put_env(:wallabidi, :base_url, "http://localhost:4321")

# Mox.defmock must be called before SandboxCase.Sandbox.setup()
Mox.defmock(Wallabidi.Integration.LiveApp.MockWeather, for: Wallabidi.Integration.LiveApp.WeatherBehaviour)
Application.put_env(:wallabidi, :weather_module, Wallabidi.Integration.LiveApp.MockWeather)

# One-line sandbox setup — handles Ecto mode, Cachex pool,
# FunWithFlags pool, Mimic.copy, logger
SandboxCase.Sandbox.setup()

ExUnit.start()
