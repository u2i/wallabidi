# Lightpanda's thread pool (default 16, we set 64) can still be overwhelmed
# on constrained CI runners. Limit concurrency if CI env is detected.
max_cases = if System.get_env("CI"), do: 8, else: System.schedulers_online()
ExUnit.configure(exclude: [pending: true, browser: true], max_cases: max_cases)

# Configure driver BEFORE starting wallabidi
Application.put_env(:wallabidi, :driver, :lightpanda)
{:ok, _} = Application.ensure_all_started(:wallabidi)

# Load support files
Code.require_file("../support/test_server.ex", __DIR__)
Code.require_file("../support/pages/index_page.ex", __DIR__)
Code.require_file("../support/pages/page_1.ex", __DIR__)
Code.require_file("../support/session_case.ex", __DIR__)
Code.require_file("../support/helpers.ex", __DIR__)

{:ok, server} = Wallabidi.Integration.TestServer.start()
Application.put_env(:wallabidi, :base_url, server.base_url)

ExUnit.start()
