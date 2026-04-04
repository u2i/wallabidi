ExUnit.configure(exclude: [pending: true, headless: true, browser: true])
EventEmitter.start_link([])

# Start the test app
{:ok, _} = Wallabidi.TestApp.Repo.start_link()
Ecto.Migrator.up(Wallabidi.TestApp.Repo, 1, Wallabidi.TestApp.Migration)
{:ok, _} = Wallabidi.TestApp.Endpoint.start_link()
{:ok, _} = Cachex.start_link(:test_app_cache)

# Configure LiveView driver as default
Application.put_env(:wallabidi, :driver, :live_view)
Application.put_env(:wallabidi, :endpoint, Wallabidi.TestApp.Endpoint)

# Start the static test server (for pages like forms.html, page_1.html)
Code.require_file("../support/test_server.ex", __DIR__)
Code.require_file("../support/pages/index_page.ex", __DIR__)
Code.require_file("../support/pages/page_1.ex", __DIR__)
Code.require_file("../support/session_case.ex", __DIR__)
Code.require_file("../support/helpers.ex", __DIR__)

{:ok, server} = Wallabidi.Integration.TestServer.start()
Application.put_env(:wallabidi, :base_url, server.base_url)

# Mox
Mox.defmock(Wallabidi.TestApp.MockWeather, for: Wallabidi.TestApp.WeatherBehaviour)
Application.put_env(:wallabidi, :weather_module, Wallabidi.TestApp.MockWeather)

# Sandbox setup
SandboxCase.Sandbox.setup()

ExUnit.start()
