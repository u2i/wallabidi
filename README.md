# Wallabidi

[![License](https://img.shields.io/hexpm/l/wallabidi.svg)](https://github.com/u2i/wallabidi/blob/main/LICENSE)

Concurrent browser testing for Elixir. Write your tests once — they run on the fastest driver that supports them.

Wallabidi is a fork of [Wallaby](https://github.com/elixir-wallaby/wallaby) with three test drivers, automatic LiveView-aware waiting, and a public API close to Wallaby's for easy migration.

## Three drivers

| Driver | Speed | What it does | When to use |
|--------|-------|-------------|-------------|
| **LiveView** | ~0ms/test | Renders pages in-process via Phoenix.ConnTest. No browser. | Default for local dev — instant feedback |
| **Lightpanda** | ~50ms/test | Headless browser via CDP. No CSS rendering. | CI fast path, JS-dependent tests |
| **Chrome** | ~200ms/test | Full browser via WebDriver BiDi. | Full fidelity, screenshots, visual testing |

Tests declare their minimum requirement with tags:

```elixir
# Runs on LiveView driver (fastest)
feature "create todo", %{session: session} do
  session |> visit("/todos") |> fill_in(text_field("Title"), with: "Buy milk") |> ...
end

# Needs a headless browser (JS execution, cookies)
@tag :headless
feature "stores preference in cookie", %{session: session} do
  session |> visit("/settings") |> execute_script("document.cookie = 'theme=dark'", [])
end

# Needs a full browser (screenshots, CSS visibility, mouse events)
@tag :browser
feature "uploads a file", %{session: session} do
  session |> visit("/upload") |> attach_file(file_field("Photo"), path: "test/fixtures/photo.jpg")
end
```

Each test runs on the **cheapest driver** that supports it. No env vars, no aliases — just `mix test`.

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

**Three drivers**: LiveView (in-process, no browser), Lightpanda (headless CDP), Chrome (full BiDi). Tests declare their minimum requirement with `@tag :headless` or `@tag :browser`.

**Removed**:
- Selenium driver — replaced with native BiDi + CDP
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

It's easiest to add Wallabidi to your test suite by using the `Wallabidi.Feature` module.

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

Because Wallabidi manages multiple browsers for you, it's possible to test several users interacting with a page simultaneously.

```elixir
@sessions 2
feature "users can chat", %{sessions: [user1, user2]} do
  user1
  |> visit("/chat")
  |> fill_in(text_field("Message"), with: "Hello!")
  |> click(button("Send"))

  user2
  |> visit("/chat")
  |> assert_has(css(".message", text: "Hello!"))
end
```

## API

### Queries and actions

Wallabidi's API is built around two concepts: Queries and Actions.

Queries allow us to declaratively describe the elements that we would like to interact with and Actions allow us to use those queries to interact with the DOM.

Let's say that our HTML looks like this:

```html
<ul class="users">
  <li class="user">
    <span class="user-name">Ada</span>
  </li>
  <li class="user">
    <span class="user-name">Grace</span>
  </li>
  <li class="user">
    <span class="user-name">Alan</span>
  </li>
</ul>
```

If we wanted to interact with all of the users then we could write a query like so `css(".user", count: 3)`.

If we only wanted to interact with a specific user then we could write a query like this `css(".user-name", count: 1, text: "Ada")`. Now we can use those queries with some actions:

```elixir
session
|> find(css(".user", count: 3))
|> List.first()
|> assert_has(css(".user-name", count: 1, text: "Ada"))
```

There are several queries for common HTML elements defined in the `Wallabidi.Query` module: `css`, `text_field`, `button`, `link`, `option`, `radio_button`, and more. All actions accept a query. Actions will block until the query is either satisfied or the action times out. Blocking reduces race conditions when elements are added or removed dynamically.

### Navigation

We can navigate directly to pages with `visit`:

```elixir
visit(session, "/page.html")
visit(session, user_path(Endpoint, :index, 17))
```

It's also possible to click links directly:

```elixir
click(session, link("Page 1"))
```

### Finding

We can find a specific element or list of elements with `find`:

```elixir
@user_form   css(".user-form")
@name_field  text_field("Name")
@email_field text_field("Email")
@save_button button("Save")

find(page, @user_form, fn(form) ->
  form
  |> fill_in(@name_field, with: "Chris")
  |> fill_in(@email_field, with: "c@keathley.io")
  |> click(@save_button)
end)
```

Passing a callback to `find` will return the parent which makes it easy to chain `find` with other actions:

```elixir
page
|> find(css(".users"), & assert has?(&1, css(".user", count: 3)))
|> click(link("Next Page"))
```

Without the callback `find` returns the element. This provides a way to scope all future actions within an element.

```elixir
page
|> find(css(".user-form"))
|> fill_in(text_field("Name"), with: "Chris")
|> fill_in(text_field("Email"), with: "c@keathley.io")
|> click(button("Save"))
```

### Interacting with forms

There are a few ways to interact with form elements on a page:

```elixir
fill_in(session, text_field("First Name"), with: "Chris")
clear(session, text_field("last_name"))
click(session, option("Some option"))
click(session, radio_button("My Fancy Radio Button"))
click(session, button("Some Button"))
```

If you need to send specific keys to an element, you can do that with `send_keys`:

```elixir
send_keys(session, ["Example", "Text", :enter])
```

### Assertions

Wallabidi provides custom assertions to make writing tests easier:

```elixir
assert_has(session, css(".signup-form"))
refute_has(session, css(".alert"))
has?(session, css(".user-edit-modal", visible: false))
```

`assert_has` and `refute_has` both take a parent element as their first argument. They return that parent, making it easy to chain them together with other actions.

```elixir
session
|> assert_has(css(".signup-form"))
|> fill_in(text_field("Email"), with: "c@keathley.io")
|> click(button("Sign up"))
|> refute_has(css(".error"))
|> assert_has(css(".alert", text: "Welcome!"))
```

### Window size

You can set the default window size by passing in the `window_size` option into `Wallabidi.start_session/1`.

```elixir
Wallabidi.start_session(window_size: [width: 1280, height: 720])
```

You can also resize the window and get the current window size during the test.

```elixir
resize_window(session, 100, 100)
window_size(session)
```

### Screenshots

It's possible to take screenshots:

```elixir
take_screenshot(session)
```

All screenshots are saved to a `screenshots` directory in the directory that the tests were run in. You can customize this with configuration (see below).

To automatically take screenshots on failure when using the `Wallabidi.Feature.feature/3` macro:

```elixir
# config/test.exs
config :wallabidi, screenshot_on_failure: true
```

### JavaScript logging and errors

Wallabidi captures both JavaScript logs and errors. Any uncaught exceptions in JavaScript will be re-thrown in Elixir. This can be disabled by specifying `js_errors: false` in your Wallabidi config.

JavaScript logs are written to `:stdio` by default. This can be changed to any IO device by setting the `:js_logger` option in your Wallabidi config. For instance if you want to write all JavaScript console logs to a file you could do something like this:

```elixir
{:ok, file} = File.open("browser_logs.log", [:write])
Application.put_env(:wallabidi, :js_logger, file)
```

Logging can be disabled by setting `:js_logger` to `nil`.

### Interacting with dialogs

Wallabidi provides several ways to interact with JavaScript dialogs such as `window.alert`, `window.confirm` and `window.prompt`.

- For `window.alert` use `accept_alert/2`
- For `window.confirm` use `accept_confirm/2` or `dismiss_confirm/2`
- For `window.prompt` use `accept_prompt/2-3` or `dismiss_prompt/2`

All of these take a function as last parameter, which must include the necessary interactions to trigger the dialog. For example:

```elixir
alert_message = accept_alert session, fn(session) ->
  click(session, link("Trigger alert"))
end
```

To emulate user input for a prompt, `accept_prompt` takes an optional parameter:

```elixir
prompt_message = accept_prompt session, [with: "User input"], fn(session) ->
  click(session, link("Trigger prompt"))
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
mix test                    # unit tests
mix test.live_view          # LiveView driver integration tests
mix test.lightpanda         # Lightpanda CDP integration tests
mix test.chrome             # Chrome BiDi integration tests
mix test.chrome.lifecycle   # chromedriver startup tests (subprocess)
mix test.all                # all of the above
mix test.browsers --browsers chrome   # run ALL tests on a specific browser
```

The LiveView and Lightpanda tests require no external dependencies — Lightpanda's binary is installed automatically via `mix lightpanda.install`. Chrome tests need Docker (auto-detected) or a local ChromeDriver.
