ExUnit.configure(exclude: [pending: true, browser: true])
EventEmitter.start_link([])

# Start the test app
{:ok, _} = Wallabidi.TestApp.Repo.start_link()
Ecto.Migrator.up(Wallabidi.TestApp.Repo, 1, Wallabidi.TestApp.Migration)
{:ok, _} = Wallabidi.TestApp.Endpoint.start_link()
{:ok, _} = Cachex.start_link(:test_app_cache)

# Configure LiveView driver as default
Application.put_env(:wallabidi, :driver, :live_view)
Application.put_env(:wallabidi, :endpoint, Wallabidi.TestApp.Endpoint)
Application.put_env(:wallabidi, :base_url, Wallabidi.TestApp.Endpoint.url())

# Mox
Mox.defmock(Wallabidi.TestApp.MockWeather, for: Wallabidi.TestApp.WeatherBehaviour)
Application.put_env(:wallabidi, :weather_module, Wallabidi.TestApp.MockWeather)

# Sandbox setup
SandboxCase.Sandbox.setup()

ExUnit.start()
