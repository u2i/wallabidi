# Unified integration test helper.
#
# Starts all driver backends so any test can create sessions on any driver.
# The primary driver is set via WALLABIDI_DRIVER env var (default: chrome_cdp).
# Tags control which tests run:
#   @moduletag :browser   — needs Chrome (excluded on LiveView, Lightpanda)
#   @moduletag :headless  — needs headless browser (excluded on LiveView)

# --- Configure primary driver ---
driver =
  case System.get_env("WALLABIDI_DRIVER") do
    "chrome" -> :chrome
    "live_view" -> :live_view
    "lightpanda" -> :lightpanda
    _ -> :chrome_cdp
  end

Application.put_env(:wallabidi, :driver, driver)

# --- Start wallabidi app (primary driver's supervisor) ---
{:ok, _} = Application.ensure_all_started(:wallabidi)

# --- Best-effort start secondary browser backend ---
# CDP and BiDi use different supervisors. Start the one that isn't primary.
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

# --- ExUnit config: exclude tags unsupported by this driver ---
excludes = [pending: true]

excludes =
  case driver do
    :live_view -> excludes ++ [browser: true, headless: true]
    :lightpanda -> excludes ++ [browser: true, lightpanda_ni: true, live_view_only: true]
    _ -> excludes ++ [live_view_only: true]
  end

ExUnit.configure(exclude: excludes)
ExUnit.start()

# --- Start LiveApp endpoint (LiveView integration tests) ---
Application.put_env(:wallabidi, Wallabidi.Integration.LiveApp.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4321],
  server: true,
  check_origin: false,
  secret_key_base: String.duplicate("x", 64),
  live_view: [signing_salt: "integration_test"],
  render_errors: [formats: [html: Wallabidi.Integration.LiveApp.ErrorHTML], layout: false]
)

{:ok, _} = Wallabidi.Integration.LiveApp.Endpoint.start_link()

# LiveView driver needs an endpoint configured
Application.put_env(:wallabidi, :endpoint, Wallabidi.Integration.LiveApp.Endpoint)

# --- Start static test server (forms.html, page_1.html, etc.) ---
{:ok, server} = Wallabidi.Integration.TestServer.start()
Application.put_env(:wallabidi, :base_url, server.base_url)

# Chrome in Docker can't reach localhost
live_host =
  if driver not in [:chrome_cdp, :live_view] &&
       Application.get_env(:wallabidi, :chromedriver, []) |> Keyword.get(:remote_url),
     do: "host.docker.internal",
     else: "localhost"

Application.put_env(:wallabidi, :live_app_url, "http://#{live_host}:4321")
