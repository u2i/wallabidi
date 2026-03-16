ExUnit.configure(exclude: [pending: true])
EventEmitter.start_link([])

# Start the test app (Repo, Endpoint, Cachex, Mimic)
{:ok, _} = Wallabidi.TestApp.Repo.start_link()

# Run migrations
Ecto.Migrator.up(Wallabidi.TestApp.Repo, 1, Wallabidi.TestApp.Migration)

# Start endpoint
{:ok, _} = Wallabidi.TestApp.Endpoint.start_link()

# Start Cachex for cached tests
{:ok, _} = Cachex.start_link(:test_app_cache)

# Set base_url
Application.put_env(:wallabidi, :base_url, "http://localhost:4002")

# Configure sandbox mode
Ecto.Adapters.SQL.Sandbox.mode(Wallabidi.TestApp.Repo, :manual)

# Setup Mimic
Mimic.copy(Wallabidi.TestApp.ExternalService)

ExUnit.start()
