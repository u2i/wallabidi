ExUnit.configure(exclude: [pending: true])

# --- Configure primary driver from env var ---
driver =
  case System.get_env("WALLABIDI_DRIVER") do
    "chrome" -> :chrome
    "live_view" -> :live_view
    _ -> :chrome_cdp
  end

Application.put_env(:wallabidi, :driver, driver)

# --- Start the wallabidi app (starts the primary driver's supervisor) ---
{:ok, _} = Application.ensure_all_started(:wallabidi)

# --- Start additional driver backends so all three are available ---
# CDP: needs ChromeCDP supervisor (Chrome.Server + SharedConnection)
# BiDi: needs Chrome supervisor (Chromedriver)
# LiveView: needs TestApp.Endpoint (+ Repo for sandbox)

# Start the other browser backend if not already started
case driver do
  :chrome_cdp ->
    # CDP is primary — also start BiDi's chromedriver
    try do
      Wallabidi.Chrome.validate()
      Wallabidi.Chrome.start_link(name: Wallabidi.Chrome.Supervisor)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

  :chrome ->
    # BiDi is primary — also start CDP's Chrome server
    try do
      Wallabidi.ChromeCDP.validate()
      Wallabidi.ChromeCDP.start_link(name: Wallabidi.ChromeCDP.Supervisor)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

  _ ->
    :ok
end

# LiveView driver needs TestApp infrastructure
Application.put_env(:wallabidi, :endpoint, Wallabidi.Integration.LiveApp.Endpoint)

ExUnit.start()

# Load support files
Code.require_file("../support/test_server.ex", __DIR__)
Code.require_file("../support/pages/index_page.ex", __DIR__)
Code.require_file("../support/pages/page_1.ex", __DIR__)
Code.require_file("../support/session_case.ex", __DIR__)
Code.require_file("../support/helpers.ex", __DIR__)
Code.require_file("../support/load_test_case.ex", __DIR__)

{:ok, server} = Wallabidi.Integration.TestServer.start()
Application.put_env(:wallabidi, :base_url, server.base_url)

# Start the LiveView test app for await_patch and perf tests
Application.put_env(:wallabidi, Wallabidi.Integration.LiveApp.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4321],
  server: true,
  check_origin: false,
  secret_key_base: String.duplicate("x", 64),
  live_view: [signing_salt: "integration_test"],
  render_errors: [formats: [html: Wallabidi.Integration.LiveApp.ErrorHTML], layout: false]
)

{:ok, _} = Wallabidi.Integration.LiveApp.Endpoint.start_link()

# Chrome in Docker can't reach localhost — use host.docker.internal
live_host =
  if driver != :chrome_cdp &&
       Application.get_env(:wallabidi, :chromedriver, []) |> Keyword.get(:remote_url),
     do: "host.docker.internal",
     else: "localhost"

Application.put_env(:wallabidi, :live_app_url, "http://#{live_host}:4321")
