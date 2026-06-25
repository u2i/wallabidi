# Unit tests run without a real browser; :browser-tagged tests live in
# integration_test/ and run via the per-driver test.* aliases. Excluding
# :browser keeps BiDi/CDP end-to-end tests from being pulled in by the
# default `mix test` command.
ExUnit.configure(exclude: [pending: true, browser: true, sandbox: true])
EventEmitter.start_link([])

# Start the merged LiveApp (Ecto repo + migrations + endpoint + Cachex)
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
