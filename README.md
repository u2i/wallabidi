# Wallabidi

[![License](https://img.shields.io/hexpm/l/wallabidi.svg)](https://github.com/u2i/wallabidi/blob/main/LICENSE)

Concurrent browser testing for Elixir, powered by [WebDriver BiDi](https://w3c.github.io/webdriver-bidi/).

Wallabidi is a fork of [Wallaby](https://github.com/elixir-wallaby/wallaby) that replaces the legacy HTTP/JSON Wire Protocol with WebDriver BiDi over WebSocket. The public API is intentionally kept close to Wallaby's to make migration straightforward.

## Why fork?

Wallaby is excellent. We forked because the changes we wanted were too invasive to contribute upstream — replacing the entire transport layer, removing Selenium, dropping four HTTP dependencies, and changing the default click mechanism. These aren't bug fixes; they're architectural decisions that would break backward compatibility for Wallaby's existing users.

We also wanted features that only make sense with BiDi: `settle()` for LiveView, request interception, event-driven log capture. Building these on top of Wallaby's HTTP polling model would have been the wrong abstraction.

If you're starting a new project or are willing to do a find-and-replace, Wallabidi gives you a simpler dependency tree, better LiveView support, and access to modern browser APIs. If you need Selenium (the Java server) support, stay with Wallaby. Firefox support via GeckoDriver is architecturally possible (it also speaks BiDi) but not yet implemented.

## What's different from Wallaby?

**Protocol**: All browser communication uses WebDriver BiDi over WebSocket instead of HTTP polling. This means event-driven log capture, lower latency, and access to features impossible with request-response HTTP.

**New features**:
- `settle/2` — Wait for the page to settle after an action. LiveView-aware: watches both network activity and `phx-*-loading` states.
- `on_console/2` — Register a callback for real-time browser console output.
- `intercept_request/3` — Mock HTTP responses directly in the browser without Bypass or a test server.

**Removed**:
- Selenium driver — Chrome only (via ChromeDriver)
- HTTPoison / Hackney dependencies — replaced with Mint
- `create_session_fn` / `end_session_fn` options

**Simplified**:
- Single ChromeDriver process shared by all test sessions
- Event-driven JS error detection (no HTTP polling per command)
- W3C capabilities format (`goog:chromeOptions`)

## Migrating from Wallaby

1. Replace the dependency:

```elixir
# mix.exs
{:wallabidi, "~> 0.1", runtime: false, only: :test}
```

2. Find and replace in your project:

| Wallaby | Wallabidi |
|---------|-----------|
| `Wallaby.` | `Wallabidi.` |
| `:wallaby` | `:wallabidi` |
| `config :wallaby,` | `config :wallabidi,` |

3. Remove if present:

```elixir
# No longer needed
config :wallaby, driver: Wallaby.Chrome
config :wallaby, hackney_options: [...]
```

4. That's it. The `Browser`, `Query`, `Element`, `Feature`, and `DSL` APIs are the same.

## Setup

Requires Elixir 1.12+, OTP 22+, and either Docker or a local ChromeDriver installation.

### Installation

```elixir
def deps do
  [{:wallabidi, "~> 0.1", runtime: false, only: :test}]
end
```

```elixir
# test/test_helper.exs
{:ok, _} = Application.ensure_all_started(:wallabidi)
```

### How Chrome is managed

Wallabidi needs ChromeDriver + Chrome to run tests. There are three modes, tried in this order:

#### 1. Automatic Docker (zero config)

If no local ChromeDriver is installed, Wallabidi will automatically start a Docker container with ChromeDriver and Chromium. No configuration needed — just have Docker running.

```
$ mix test  # Just works. Docker container starts and stops automatically.
```

The container (`erseco/alpine-chromedriver`) is multi-arch (ARM64 + AMD64) and is cleaned up when your test suite finishes. The image is ~750MB (Chromium is large — but this is half the size of the Selenium Grid image). URLs are automatically rewritten so Chrome in the container can reach your local test server.

This is the recommended mode for teams — no local dependencies to install beyond Docker.

#### 2. Docker Compose (explicit remote)

When Chrome runs as a service in your Docker Compose stack (e.g. in a devcontainer), point Wallabidi at it:

```elixir
# config/test.exs
config :wallabidi,
  chromedriver: [remote_url: "http://chrome:9515/"]
```

Example `compose.yml`:

```yaml
services:
  app:
    # your Elixir app
    depends_on: [chrome]

  chrome:
    image: erseco/alpine-chromedriver:latest
    shm_size: 512m
```

No automatic container management — you control the lifecycle via Compose. Wallabidi polls the `/status` endpoint until the service is ready.

#### 3. Local ChromeDriver

If ChromeDriver and Chrome are installed locally, Wallabidi uses them directly. This is the fastest mode (no Docker overhead) and how CI typically works (GitHub Actions has Chrome pre-installed).

```
$ brew install chromedriver  # macOS
$ mix test                   # Uses local chromedriver
```

Configure the binary paths if they're not in your PATH:

```elixir
config :wallabidi,
  chromedriver: [
    path: "/path/to/chromedriver",
    binary: "/path/to/chrome"
  ]
```

### Phoenix

```elixir
# config/test.exs
config :your_app, YourAppWeb.Endpoint, server: true

# test/test_helper.exs
Application.put_env(:wallabidi, :base_url, YourAppWeb.Endpoint.url)
```

When using Ecto:

```elixir
config :wallabidi, otp_app: :your_app
```

### LiveView

Add the Ecto sandbox hook as described in the [Wallaby docs](https://hexdocs.pm/wallaby/readme.html#liveview) — the setup is identical, just replace `:wallaby` with `:wallabidi`.

## Usage

```elixir
defmodule MyApp.Features.TodoTest do
  use ExUnit.Case, async: true
  use Wallabidi.Feature

  feature "users can create todos", %{session: session} do
    session
    |> visit("/todos")
    |> fill_in(Query.text_field("New Todo"), with: "Write a test")
    |> click(Query.button("Save"))
    |> settle()
    |> assert_has(Query.css(".todo", text: "Write a test"))
  end
end
```

### settle

Wait for the page to settle after an action. Works with both traditional AJAX and LiveView:

```elixir
session
|> click(Query.button("Save"))
|> settle()
|> assert_has(Query.css(".saved"))
```

Checks two signals: no new HTTP requests for the idle period, and no LiveView `phx-*-loading` classes present.

### intercept_request

Mock HTTP responses in the browser:

```elixir
session
|> intercept_request("/api/users", %{
  status: 200,
  headers: [%{name: "content-type", value: "application/json"}],
  body: ~s({"users": []})
})
|> visit("/page")
```

### on_console

Stream browser console output:

```elixir
session
|> on_console(fn level, message ->
  IO.puts("[#{level}] #{message}")
end)
```

## Configuration

```elixir
config :wallabidi,
  max_wait_time: 5_000,
  js_errors: true,
  js_logger: :stdio,
  screenshot_on_failure: false,
  screenshot_dir: "screenshots",
  chromedriver: [
    headless: true,
    path: "chromedriver",
    binary: "/path/to/chrome",
    remote_url: "http://chrome:4444/"
  ]
```

## Credits

Wallabidi is built on the foundation of [Wallaby](https://github.com/elixir-wallaby/wallaby), created by [Mitchell Hanberg](https://github.com/mhanberg) and [contributors](https://github.com/elixir-wallaby/wallaby/graphs/contributors). The Browser, Query, Element, Feature, and DSL APIs are theirs. Wallabidi adds the BiDi transport layer, new DX features, and removes the Selenium/HTTP legacy code.

Licensed under MIT, same as Wallaby.

## Contributing

```shell
mix test              # unit tests
WALLABY_DRIVER=chrome mix test   # integration tests
mix test.all          # both
```
