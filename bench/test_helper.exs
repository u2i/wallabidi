Logger.configure(level: :warning)

# Bench test helper — starts all driver backends for load tests and benchmarks.

driver =
  case System.get_env("WALLABIDI_DRIVER") do
    "chrome" -> :chrome
    "lightpanda" -> :lightpanda
    "live_view" -> :live_view
    _ -> :chrome_cdp
  end

Application.put_env(:wallabidi, :driver, driver)
{:ok, _} = Application.ensure_all_started(:wallabidi)

# For benchmarks we want EVERY available driver stack running, so
# the "compare all drivers" test can ask Wallabidi.start_session/1
# for each one without bringing up its supervisor on the fly. Each
# secondary boots only if it's a different stack from the primary —
# starting the primary's stack twice errors with :already_started
# on the underlying ChromeServer/Lightpanda port.
primary_mod =
  case driver do
    :chrome -> Wallabidi.Chrome
    :chrome_cdp -> Wallabidi.ChromeCDP
    :lightpanda -> Wallabidi.Remote.Drivers.LightpandaCDP
    _ -> nil
  end

secondaries =
  [
    {Wallabidi.Chrome, Wallabidi.Chrome.Supervisor},
    {Wallabidi.ChromeCDP, Wallabidi.ChromeCDP.Supervisor},
    {Wallabidi.Remote.Drivers.LightpandaCDP, Wallabidi.Remote.Drivers.LightpandaCDP.Supervisor}
  ]
  |> Enum.reject(fn {mod, _name} -> mod == primary_mod end)

for {mod, name} <- secondaries do
  try do
    if function_exported?(mod, :validate, 0), do: mod.validate()
    mod.start_link(name: name)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end

# LiveApp endpoint
Application.put_env(:wallabidi, Wallabidi.Integration.LiveApp.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4321],
  server: true,
  check_origin: false,
  secret_key_base: String.duplicate("x", 64),
  live_view: [signing_salt: "integration_test"],
  render_errors: [formats: [html: Wallabidi.Integration.LiveApp.ErrorHTML], layout: false]
)

{:ok, _} = Wallabidi.Integration.LiveApp.Endpoint.start_link()
Application.put_env(:wallabidi, :endpoint, Wallabidi.Integration.LiveApp.Endpoint)

Application.put_env(:wallabidi, :base_url, "http://localhost:4321")

Application.put_env(:wallabidi, :live_app_url, "http://localhost:4321")

# --- Start Testcontainers GenServer ---
Testcontainers.start_link()

# --- Start PostgreSQL container ---
{:ok, pg_container} =
  Testcontainers.start_container(
    Testcontainers.PostgresContainer.new()
    |> Testcontainers.PostgresContainer.with_image("postgres:18-alpine")
    |> Testcontainers.PostgresContainer.with_user("wallabidi")
    |> Testcontainers.PostgresContainer.with_password("wallabidi")
    |> Testcontainers.PostgresContainer.with_database("wallabidi_test")
  )

Application.put_env(:wallabidi, Wallabidi.Integration.LiveApp.Repo,
  Testcontainers.PostgresContainer.connection_parameters(pg_container) ++
    [pool: Ecto.Adapters.SQL.Sandbox, pool_size: 10]
)

{:ok, _} = Wallabidi.Integration.LiveApp.Repo.start_link()
Ecto.Migrator.up(Wallabidi.Integration.LiveApp.Repo, 1, Wallabidi.Integration.LiveApp.Migration)

ExUnit.start()

System.at_exit(fn _ ->
  Application.stop(:wallabidi)
end)
