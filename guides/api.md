# API

Wallabidi's API is built around two concepts: Queries and Actions. For per-module
reference, see the [`Wallabidi.Browser`](Wallabidi.Browser.html),
[`Wallabidi.Query`](Wallabidi.Query.html), and [`Wallabidi.Element`](Wallabidi.Element.html)
docs.

## Queries and actions

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

## Navigation

We can navigate directly to pages with `visit`:

```elixir
visit(session, "/page.html")
visit(session, user_path(Endpoint, :index, 17))
```

It's also possible to click links directly:

```elixir
click(session, link("Page 1"))
```

## Finding

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

## Interacting with forms

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

## Assertions

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

## Window size

You can set the default window size by passing in the `window_size` option into `Wallabidi.start_session/1`.

```elixir
Wallabidi.start_session(window_size: [width: 1280, height: 720])
```

You can also resize the window and get the current window size during the test.

```elixir
resize_window(session, 100, 100)
window_size(session)
```

## Screenshots

It's possible to take screenshots:

```elixir
take_screenshot(session)
```

All screenshots are saved to a `screenshots` directory in the directory that the tests were run in. You can customize this with configuration (see [Configuration](readme.html#configuration)).

To automatically take screenshots on failure when using the `Wallabidi.Feature.feature/3` macro:

```elixir
# config/test.exs
config :wallabidi, screenshot_on_failure: true
```

## JavaScript logging and errors

Wallabidi captures both JavaScript logs and errors. Any uncaught exceptions in JavaScript will be re-thrown in Elixir. This can be disabled by specifying `js_errors: false` in your Wallabidi config.

JavaScript logs are written to `:stdio` by default. This can be changed to any IO device by setting the `:js_logger` option in your Wallabidi config. For instance if you want to write all JavaScript console logs to a file you could do something like this:

```elixir
{:ok, file} = File.open("browser_logs.log", [:write])
Application.put_env(:wallabidi, :js_logger, file)
```

Logging can be disabled by setting `:js_logger` to `nil`.

## Interacting with dialogs

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

## settle

Wait for the page to become idle. Checks two signals: no pending HTTP requests for the idle period, and no LiveView `phx-*-loading` classes present.

You don't need `settle` after `click`, `fill_in`, or `visit` — those already wait automatically. Use `settle` for updates triggered by something other than a direct interaction:

```elixir
# PubSub broadcast — no browser interaction triggered it
Phoenix.PubSub.broadcast(MyApp.PubSub, "updates", :refresh)
session
|> settle()
|> assert_has(Query.css(".updated"))
```

## intercept_request

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

## on_console

Stream browser console output:

```elixir
session
|> on_console(fn level, message ->
  IO.puts("[#{level}] #{message}")
end)
```
