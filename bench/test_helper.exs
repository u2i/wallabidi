Logger.configure(level: :warning)

# Bench test helper — starts all driver backends for load tests and benchmarks.

driver =
  case System.get_env("WALLABIDI_DRIVER") do
    "chrome" -> :chrome
    "live_view" -> :live_view
    _ -> :chrome_cdp
  end

Application.put_env(:wallabidi, :driver, driver)
{:ok, _} = Application.ensure_all_started(:wallabidi)

# Best-effort start secondary browser backend
secondary =
  case driver do
    :chrome_cdp -> {Wallabidi.Chrome, Wallabidi.Chrome.Supervisor}
    :chrome -> {Wallabidi.ChromeCDP, Wallabidi.ChromeCDP.Supervisor}
    _ -> nil
  end

if secondary do
  {mod, name} = secondary

  try do
    mod.validate()
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

{:ok, server} = Wallabidi.Integration.TestServer.start()
Application.put_env(:wallabidi, :base_url, server.base_url)

live_host =
  if driver not in [:chrome_cdp, :live_view] &&
       Application.get_env(:wallabidi, :chromedriver, []) |> Keyword.get(:remote_url),
     do: "host.docker.internal",
     else: "localhost"

Application.put_env(:wallabidi, :live_app_url, "http://#{live_host}:4321")

ExUnit.start()
