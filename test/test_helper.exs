ExUnit.configure(exclude: [pending: true])
EventEmitter.start_link([])

# Start the test app
{:ok, _} = Wallabidi.TestApp.Repo.start_link()
Ecto.Migrator.up(Wallabidi.TestApp.Repo, 1, Wallabidi.TestApp.Migration)
{:ok, _} = Wallabidi.TestApp.Endpoint.start_link()
{:ok, _} = Cachex.start_link(:test_app_cache)

# Set base_url
Application.put_env(:wallabidi, :base_url, "http://localhost:4002")

# Mox.defmock must be called before SandboxCase.Sandbox.setup()
Mox.defmock(Wallabidi.TestApp.MockWeather, for: Wallabidi.TestApp.WeatherBehaviour)
Application.put_env(:wallabidi, :weather_module, Wallabidi.TestApp.MockWeather)

# One-line sandbox setup — handles Ecto mode, Cachex pool,
# FunWithFlags pool, Mimic.copy, logger
SandboxCase.Sandbox.setup()

ExUnit.start()
