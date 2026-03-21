ExUnit.configure(exclude: [pending: true])
ExUnit.start()

# Load support files
Code.require_file("../support/test_server.ex", __DIR__)
Code.require_file("../support/pages/index_page.ex", __DIR__)
Code.require_file("../support/pages/page_1.ex", __DIR__)
Code.require_file("../support/session_case.ex", __DIR__)
Code.require_file("../support/helpers.ex", __DIR__)

{:ok, server} = Wallabidi.Integration.TestServer.start()
Application.put_env(:wallabidi, :base_url, server.base_url)

# Start the LiveView test app for await_patch tests
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
  if Application.get_env(:wallabidi, :chromedriver, []) |> Keyword.get(:remote_url),
    do: "host.docker.internal",
    else: "localhost"

Application.put_env(:wallabidi, :live_app_url, "http://#{live_host}:4321")
