# Wallabidi

[![License](https://img.shields.io/hexpm/l/wallabidi.svg)](https://github.com/u2i/wallabidi/blob/main/LICENSE)

Concurrent browser testing for Elixir, powered by [WebDriver BiDi](https://w3c.github.io/webdriver-bidi/).

Wallabidi is a fork of [Wallaby](https://github.com/elixir-wallaby/wallaby) that replaces the legacy HTTP/JSON Wire Protocol with WebDriver BiDi over WebSocket. The public API is intentionally kept close to Wallaby's to make migration straightforward.

## Why fork?

Wallaby is excellent. We forked because the changes we wanted were too invasive to contribute upstream — replacing the entire transport layer, removing Selenium, dropping four HTTP dependencies, and changing the default click mechanism. These aren't bug fixes; they're architectural decisions that would break backward compatibility for Wallaby's existing users.

We also wanted features that only make sense with BiDi: automatic LiveView-aware waiting on every interaction, request interception, event-driven log capture. Building these on top of Wallaby's HTTP polling model would have been the wrong abstraction.

If you're starting a new project or are willing to do a find-and-replace, Wallabidi gives you a simpler dependency tree, automatic LiveView-aware waiting on every interaction, and access to modern browser APIs. If you need Selenium (the Java server) support, stay with Wallaby. Firefox support via GeckoDriver is architecturally possible (it also speaks BiDi) but not yet implemented.

## What's different from Wallaby?

**Protocol**: All browser communication uses WebDriver BiDi over WebSocket instead of HTTP polling. This means event-driven log capture, lower latency, and access to features impossible with request-response HTTP.

**LiveView-aware by default**: Every interaction automatically waits for the right thing — no manual sleeps or retry loops needed:

- `visit/2` waits for the LiveSocket to connect before returning.
- `click/2` inspects the target element's bindings (`phx-click`, `data-phx-link`, plain `href`) and classifies the interaction as patch, navigate, or full-page. It then awaits the corresponding DOM patch, page load, or LiveView reconnection automatically.
- `fill_in/3` on `phx-change` inputs drains all pending patches (one per keystroke) before returning.
- `assert_has/2` uses an event-driven `await_selector` that hooks into LiveView's `onPatchEnd` callback — it waits for the next DOM patch before polling, avoiding both false negatives and busy-waiting.

All of this is installed via injected JavaScript — no changes to your `app.js` or LiveSocket config are needed.

**New features**:
- `settle/2` — Wait for the page to become idle (no pending HTTP requests, no `phx-*-loading` classes). Useful after PubSub broadcasts, timers, or other non-interaction updates.
- `await_patch/2` — Wait for the next LiveView DOM patch. Useful for server-pushed updates that aren't triggered by a browser interaction.
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

Requires Elixir 1.18+, OTP 27+, and either Docker or a local ChromeDriver installation.

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

#### 1. Remote (explicit `remote_url`)

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

#### 2. Local ChromeDriver

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

#### 3. Automatic Docker (fallback)

If no `remote_url` is configured and no local ChromeDriver is found, Wallabidi will automatically start a Docker container with ChromeDriver and Chromium. No configuration needed — just have Docker running.

```
$ mix test  # Just works. Docker container starts and stops automatically.
```

The container (`erseco/alpine-chromedriver`) is multi-arch (ARM64 + AMD64) and is cleaned up when your test suite finishes. The image is ~750MB (Chromium is large — but this is half the size of the Selenium Grid image). URLs are automatically rewritten so Chrome in the container can reach your local test server.

This is the recommended mode for teams — no local dependencies to install beyond Docker.

### Phoenix

```elixir
# config/test.exs
config :your_app, YourAppWeb.Endpoint, server: true

# test/test_helper.exs
Application.put_env(:wallabidi, :base_url, YourAppWeb.Endpoint.url)
```

### Test isolation (Ecto, Mimic, Mox, Cachex, FunWithFlags)

Browser tests need sandbox access propagated to every server-side process the browser triggers (Plug requests, LiveView mounts, async tasks). Wallabidi integrates with [`sandbox_case`](https://github.com/pinetops/sandbox_case) and [`sandbox_shim`](https://github.com/pinetops/sandbox_shim) to handle this automatically.

`sandbox_case` manages checkout/checkin of all sandbox adapters (Ecto, Cachex, FunWithFlags, Mimic, Mox) from a single config. `sandbox_shim` provides compile-time macros that wire the sandbox plugs and hooks into your endpoint and LiveViews — emitting nothing in production.

```elixir
# mix.exs
{:sandbox_shim, "~> 0.1"},                                    # all envs (compile-time only)
{:sandbox_case, "~> 0.3", only: :test},                       # test only
{:wallabidi, "~> 0.1", only: :test, runtime: false},           # test only
```

```elixir
# config/test.exs
config :sandbox_case,
  otp_app: :your_app,
  sandbox: [
    ecto: true,
    cachex: [:my_cache],            # optional
    fun_with_flags: true,           # optional
    mimic: true,                    # auto-discovers Mimic.copy'd modules
    mox: [MyApp.MockWeather]        # optional
  ]
```

```elixir
# lib/your_app_web/endpoint.ex
import SandboxShim
sandbox_plugs()

sandbox_socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options]]
```

```elixir
# lib/your_app_web.ex
def live_view do
  quote do
    use Phoenix.LiveView
    import SandboxShim
    sandbox_on_mount()
    # auth hooks after
  end
end
```

```elixir
# test/test_helper.exs
SandboxCase.Sandbox.setup()
{:ok, _} = Application.ensure_all_started(:wallabidi)
```

With `use Wallabidi.Feature`, sandbox checkout/checkin is automatic — no manual `Ecto.Adapters.SQL.Sandbox.checkout` calls needed.

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
    |> assert_has(Query.css(".todo", text: "Write a test"))
  end
end
```

### settle

Wait for the page to become idle. Checks two signals: no pending HTTP requests for the idle period, and no LiveView `phx-*-loading` classes present.

You don't need `settle` after `click`, `fill_in`, or `visit` — those already wait automatically. Use `settle` for updates triggered by something other than a direct interaction:

```elixir
# PubSub broadcast — no browser interaction triggered it
Phoenix.PubSub.broadcast(MyApp.PubSub, "updates", :refresh)
session
|> settle()
|> assert_has(Query.css(".updated"))
```

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
WALLABIDI_DRIVER=chrome mix test  # integration tests
mix test.all          # both
```
