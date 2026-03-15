# ![Wallaby](https://i.imgur.com/eQ1tlI3.png)

[![Actions Status](https://github.com/elixir-wallaby/wallaby/workflows/CI/badge.svg)](https://github.com/elixir-wallaby/wallaby/actions)
[![Module Version](https://img.shields.io/hexpm/v/wallaby.svg)](https://hex.pm/packages/wallaby)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/wallaby/)
[![License](https://img.shields.io/hexpm/l/wallaby.svg)](https://github.com/elixir-wallaby/wallaby/blob/master/LICENSE)

Wallaby helps you test your web applications by simulating realistic user interactions.
By default it runs each test case concurrently and manages browsers for you.
Here's an example test for a simple Todo application:

```elixir
defmodule MyApp.Features.TodoTest do
  use ExUnit.Case, async: true
  use Wallaby.Feature

  import Wallaby.Query, only: [css: 2, text_field: 1, button: 1]

  feature "users can create todos", %{session: session} do
    session
    |> visit("/todos")
    |> fill_in(text_field("New Todo"), with: "Write my first Wallaby test")
    |> click(button("Save"))
    |> assert_has(css(".alert", text: "You created a todo"))
    |> assert_has(css(".todo-list > .todo", text: "Write my first Wallaby test"))
  end
end
```

Because Wallaby manages multiple browsers for you, its possible to test several users interacting with a page simultaneously.

```elixir
defmodule MyApp.Features.MultipleUsersTest do
  use ExUnit.Case, async: true
  use Wallaby.Feature

  import Wallaby.Query, only: [text_field: 1, button: 1, css: 2]

  @page message_path(Endpoint, :index)
  @message_field text_field("Share Message")
  @share_button button("Share")

  def message(msg), do: css(".messages > .message", text: msg)

  @sessions 2
  feature "That users can send messages to each other", %{sessions: [user1, user2]} do
    user1
    |> visit(@page)
    |> fill_in(@message_field, with: "Hello there!")
    |> click(@share_button)

    user2
    |> visit(@page)
    |> fill_in(@message_field, with: "Hello yourself")
    |> click(@share_button)

    user1
    |> assert_has(message("Hello yourself"))

    user2
    |> assert_has(message("Hello there!"))
  end
end
```

Read on to see what else Wallaby can do or check out the [Official Documentation](https://hexdocs.pm/wallaby).

## Setup

### Requirements

Wallaby requires Elixir 1.12+ and OTP 22+.

Wallaby also requires `bash` to be installed. Generally `bash` is widely available, but it does not come pre-installed on Alpine Linux.

### Installation

Add Wallaby to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:wallaby, "~> 0.30", runtime: false, only: :test}
  ]
end
```

You'll need to install [ChromeDriver](https://chromedriver.chromium.org/downloads) and [Google Chrome](https://www.google.com/chrome/).

Ensure that Wallaby is started in your `test_helper.exs`:

```elixir
{:ok, _} = Application.ensure_all_started(:wallaby)
```

When calling `use Wallaby.Feature` and using Ecto, please configure your `otp_app`.

```elixir
config :wallaby, otp_app: :your_app
```

### Remote ChromeDriver (Docker)

To connect to a ChromeDriver running in a separate container:

```elixir
# config/test.exs
config :wallaby,
  chromedriver: [
    remote_url: "http://chrome:4444/"
  ]
```

When `remote_url` is set, Wallaby will not start a local ChromeDriver process and will instead connect to the remote instance.

### Phoenix

Enable Phoenix to serve endpoints in tests:

```elixir
# config/test.exs

config :your_app, YourAppWeb.Endpoint,
  server: true
```

In your `test_helper.exs` you can provide some configuration to Wallaby.
At a minimum, you need to specify a `:base_url`, so Wallaby knows how to resolve relative paths.

```elixir
# test/test_helper.exs

Application.put_env(:wallaby, :base_url, YourAppWeb.Endpoint.url)
```

#### Ecto

If you're testing a Phoenix application with Ecto and a database that [supports sandbox mode](https://hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.Sandbox.html), you can enable concurrent testing by adding the `Phoenix.Ecto.SQL.Sandbox` plug to your `Endpoint`.
It's important that this is at the top of `endpoint.ex` before any other plugs.

```elixir
# lib/your_app_web/endpoint.ex

defmodule YourAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :your_app

  if Application.compile_env(:your_app, :sandbox, false) do
    plug Phoenix.Ecto.SQL.Sandbox
  end

  # ...

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:user_agent, session: @session_options]]
  )
```

It's also important to make sure the `user_agent` is passed in the `connect_info` in order to allow the database and browser session to be wired up correctly.

Then make sure sandbox is enabled:

```elixir
# config/test.exs

config :your_app, :sandbox, Ecto.Adapters.SQL.Sandbox
```

#### LiveView

In order to test Phoenix LiveView with Wallaby you'll need to add the sandbox hook to your LiveViews:

```elixir
defmodule MyApp.Hooks.AllowEctoSandbox do
  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, _session, socket) do
    allow_ecto_sandbox(socket)
    {:cont, socket}
  end

  defp allow_ecto_sandbox(socket) do
    %{assigns: %{phoenix_ecto_sandbox: metadata}} =
      assign_new(socket, :phoenix_ecto_sandbox, fn ->
        if connected?(socket), do: get_connect_info(socket, :user_agent)
      end)

    Phoenix.Ecto.SQL.Sandbox.allow(metadata, Application.get_env(:your_app, :sandbox))
  end
end
```

Then include it in the router:

```elixir
live_session :default, on_mount: MyApp.Hooks.AllowEctoSandbox do
  # ...
end
```

### Writing tests

It's easiest to add Wallaby to your test suite by using the `Wallaby.Feature` module.

```elixir
defmodule YourApp.UserListTest do
  use ExUnit.Case, async: true
  use Wallaby.Feature

  feature "users have names", %{session: session} do
    session
    |> visit("/users")
    |> find(Query.css(".user", count: 3))
    |> List.first()
    |> assert_has(Query.css(".user-name", text: "Chris"))
  end
end
```

## API

The full documentation for the DSL is in the [official documentation](https://hexdocs.pm/wallaby).

### Queries and Actions

Wallaby's API is broken into 2 concepts: Queries and Actions.

Queries allow us to declaratively describe the elements that we would like to interact with and Actions allow us to use those queries to interact with the DOM.

```elixir
session
|> find(css(".user", count: 3))
|> List.first
|> assert_has(css(".user-name", count: 1, text: "Ada"))
```

There are several queries for common html elements defined in the [Query module](https://hexdocs.pm/wallaby/Wallaby.Query.html#content).
All actions accept a query.
Actions will block until the query is either satisfied or the action times out.

### Navigation

```elixir
visit(session, "/page.html")
click(session, link("Page 1"))
```

### Interacting with forms

```elixir
fill_in(session, text_field("First Name"), with: "Chris")
clear(session, text_field("last_name"))
click(session, option("Some option"))
click(session, button("Some Button"))
send_keys(session, ["Example", "Text", :enter])
```

### Assertions

```elixir
session
|> assert_has(css(".signup-form"))
|> fill_in(text_field("Email", with: "c@keathley.io"))
|> click(button("Sign up"))
|> refute_has(css(".error"))
|> assert_has(css(".alert", text: "Welcome!"))
```

### Waiting for async operations

Use `settle/2` to wait for the page to settle after actions that trigger async behavior (AJAX, LiveView events, etc.):

```elixir
session
|> click(button("Save"))
|> settle()
|> assert_has(css(".flash-info", text: "Saved!"))
```

`settle` watches for new network requests and LiveView loading states. When no new requests have started and no `phx-*-loading` classes are present for the idle period, the page is considered settled.

### Console output

Register a callback for browser console messages:

```elixir
session
|> on_console(fn level, message ->
  IO.puts("[console.#{level}] #{message}")
end)
|> visit("/page")
```

### Request interception

Mock HTTP responses directly in the browser without a test server:

```elixir
session
|> intercept_request("/api/users", %{
  status: 200,
  headers: [%{name: "content-type", value: "application/json"}],
  body: ~s({"users": []})
})
|> visit("/page")
```

Dynamic responses:

```elixir
session
|> intercept_request("/api/*", fn _request ->
  %{status: 200, headers: [], body: "mocked"}
end)
```

### Window Size

```elixir
Wallaby.start_session(window_size: [width: 1280, height: 720])

resize_window(session, 100, 100)
window_size(session)
```

### Screenshots

```elixir
take_screenshot(session)
```

Configure the screenshot directory:

```elixir
config :wallaby, screenshot_dir: "/file/path"
```

Automatically take screenshots on failure:

```elixir
config :wallaby, screenshot_on_failure: true
```

## JavaScript

### Asynchronous code

Wallaby helps solve timing issues by blocking.
Instead of manually setting timeouts, use `assert_has` and `settle` to wait for the DOM to be ready:

```elixir
session
|> click(button("Some Async Button"))
|> settle()
|> assert_has(css(".async-result"))
```

### Interacting with dialogs

```elixir
alert_message = accept_alert session, fn(session) ->
  click(session, link("Trigger alert"))
end

prompt_message = accept_prompt session, [with: "User input"], fn(session) ->
  click(session, link("Trigger prompt"))
end
```

### JavaScript logging and errors

Wallaby captures both JavaScript logs and errors.
Any uncaught exceptions in JavaScript will be re-thrown in Elixir.
This can be disabled by specifying `js_errors: false` in your Wallaby config.

JavaScript logs are written to :stdio by default.
This can be changed to any IO device by setting the `:js_logger` option in your Wallaby config.
Logging can be disabled by setting `:js_logger` to `nil`.

## Configuration

### ChromeDriver options

```elixir
config :wallaby,
  chromedriver: [
    headless: false,                          # run with visible browser
    path: "path/to/chromedriver",             # custom chromedriver path
    binary: "path/to/chrome",                 # custom Chrome path
    remote_url: "http://chrome:4444/",        # remote ChromeDriver (Docker)
    capabilities: %{                          # custom capabilities
      "goog:chromeOptions": %{
        args: ["--headless", "--no-sandbox"]
      }
    }
  ]
```

## Contributing

Wallaby is a community project. Pull Requests (PRs) and reporting issues are greatly welcome.

### Development Dependencies

- ChromeDriver
- Google Chrome

```shell
# Unit tests
$ mix test

# Integration tests
$ WALLABY_DRIVER=chrome mix test

# All tests
$ mix test.all
```

### Helpful Links

- [ChromeDriver Issue Tracker](https://issues.chromium.org/issues?q=status:open%20componentid:1608258&s=created_time:desc)
