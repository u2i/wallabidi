ExUnit.configure(exclude: [pending: true])
EventEmitter.start_link([])

# Start the test app (Repo, Endpoint, Cachex, Mimic)
{:ok, _} = Wallabidi.TestApp.Repo.start_link()

# Run migrations
Ecto.Migrator.up(Wallabidi.TestApp.Repo, 1, Wallabidi.TestApp.Migration)

# Start endpoint
{:ok, _} = Wallabidi.TestApp.Endpoint.start_link()

# Start Cachex + sandbox pool
{:ok, _} = Cachex.start_link(:test_app_cache)
{:ok, _} = Cachex.Sandbox.start([:test_app_cache])

# Set base_url
Application.put_env(:wallabidi, :base_url, "http://localhost:4002")

# Configure sandbox mode
Ecto.Adapters.SQL.Sandbox.mode(Wallabidi.TestApp.Repo, :manual)

# Setup Mimic
Mimic.copy(Wallabidi.TestApp.ExternalService)
Mimic.copy(Wallabidi.TestApp.PriceService)

# Setup Mox
Mox.defmock(Wallabidi.TestApp.MockWeather, for: Wallabidi.TestApp.WeatherBehaviour)
Application.put_env(:wallabidi, :weather_module, Wallabidi.TestApp.MockWeather)
Application.put_env(:wallabidi, :mox_mocks, [Wallabidi.TestApp.MockWeather])

ExUnit.start()
