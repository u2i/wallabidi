Logger.configure(level: :warning)

# Legacy path test helper — deliberately does NOT call SandboxCase.Sandbox.setup().
# This exercises the fallback branch in Wallabidi.Feature.Utils.checkout_sandbox/1
# where sandbox_case is absent and we fall through to maybe_checkout_repos/1, which
# calls repo_started?/1 to decide which repos to checkout.

Application.stop(:wallabidi)
Application.put_env(:wallabidi, :driver, :chrome_cdp)
Application.put_env(:wallabidi, :otp_app, :wallabidi)
{:ok, _} = Application.ensure_all_started(:wallabidi)

ExUnit.start()

Testcontainers.start_link()

{:ok, pg_container} =
  Testcontainers.start_container(
    Testcontainers.PostgresContainer.new()
    |> Testcontainers.PostgresContainer.with_image("postgres:18-alpine")
    |> Testcontainers.PostgresContainer.with_user("wallabidi")
    |> Testcontainers.PostgresContainer.with_password("wallabidi")
    |> Testcontainers.PostgresContainer.with_database("wallabidi_test")
  )

Application.put_env(
  :wallabidi,
  Wallabidi.Integration.LiveApp.Repo,
  Testcontainers.PostgresContainer.connection_parameters(pg_container) ++
    [pool: Ecto.Adapters.SQL.Sandbox, pool_size: 10]
)

{:ok, _} = Wallabidi.Integration.LiveApp.Repo.start_link()
Ecto.Migrator.up(Wallabidi.Integration.LiveApp.Repo, 1, Wallabidi.Integration.LiveApp.Migration)

Application.put_env(:wallabidi, Wallabidi.Integration.LiveApp.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4322],
  adapter: Bandit.PhoenixAdapter,
  server: true,
  check_origin: false,
  secret_key_base: String.duplicate("x", 64),
  live_view: [signing_salt: "legacy_test"],
  render_errors: [formats: [html: Wallabidi.Integration.LiveApp.ErrorHTML], layout: false]
)

{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Wallabidi.Integration.Legacy.PubSub)
{:ok, _} = Wallabidi.Integration.LiveApp.Endpoint.start_link()

Application.put_env(:wallabidi, :base_url, "http://localhost:4322")

System.at_exit(fn _ ->
  Application.stop(:wallabidi)

  try do
    Supervisor.stop(Wallabidi.Integration.LiveApp.Endpoint)
  catch
    :exit, _ -> :ok
  end
end)
